# GenericAgent → Go 重写实施方案

> **文档编号**：GA-GO-001
> **版本**：v1.0
> **日期**：2026-05-02
> **定位**：将 Python 版 GenericAgent（~3K 核心 + ~11.6K 总代码）完整重写为 Go 语言实现，同时针对原版的设计短板做重点改进。
> **阅读前置**：建议先读 `GenericAgent_代码级调研报告.md`

---

## 0. 执行摘要（TL;DR）

| 维度 | 决策 |
|---|---|
| **项目名** | `genericagent-go`（模块名 `github.com/<owner>/ga`） |
| **目标版本** | v0.1 = 核心 9 工具 + 3 协议 LLM + 分层记忆 |
| **语言版本** | Go 1.22+（为了 slog、range-func、iter 包） |
| **核心替换** | Python generator → Go `iter.Seq`（或 channel-based） |
| **动态派发** | `do_<tool>` 反射 → `map[string]ToolHandler` 注册表 |
| **热重载** | `mykey.py importlib.reload` → 文件 watcher + `viper` |
| **前端** | Streamlit 去掉，改为 **内置 HTTP/WS server** + 轻量 Web UI（或纯终端） |
| **Bot 适配** | 全部用官方 Go SDK（tg、feishu、dingtalk、discord）；个人微信走**HTTP 侧车** |
| **浏览器** | 复用原 MV3 扩展 + 重写 TMWebDriver 为 Go WebSocket server |
| **码量预期** | Go 核心 ~5K 行（比 Python 3K 略多，因为显式错误处理和类型声明） |
| **里程碑** | 6 个阶段，12 周可达生产可用 |

**核心价值定位**：

1. **单文件静态二进制部署**：`go build → ga` 一个 10–20 MB 的文件塞进任何 Linux/macOS/Windows，告别 `pip install` 地狱
2. **并发原生**：每个 subagent / bot / LLM 请求是 goroutine，`GOMAXPROCS` 自动利用多核；Python 的 GIL + 线程 + asyncio 混用不再是问题
3. **记忆层工程化**：把 Python 版"靠模型自觉维护记忆"的隐患，改为**代码层强制执行的监控 + 自动降级机制**
4. **可测试性**：Go 静态类型 + `testing` + `interface` 模拟，比 Python 的运行时 patch 好写测试 10 倍

---

## 1. Python 版核心架构回顾（重写视角）

> 只重述与重写决策相关的部分，完整细节见代码级调研报告。

### 1.1 必须保留的设计精髓（"这些是 GA 之所以是 GA 的原因"）

| 设计 | 价值 | Go 版方案 |
|---|---|---|
| **9 个原子工具**（code_run / file_read / file_write / file_patch / web_scan / web_execute_js / ask_user / update_working_checkpoint / start_long_term_update） | 最小完备集，不多不少 | 1:1 保留，接口名不变 |
| **Agent Loop ~100 行**（turn → LLM → tool calls → next_prompt → loop） | 主循环极度克制，所有复杂度外置 | 用 Go channel 实现，本体目标 ≤200 行 |
| **分层记忆 L0–L4** + Markdown 存储 | 能力可通过写文件扩展，不改代码 | 完整保留，但增加**容量守护进程** |
| **StepOutcome(data, next_prompt, should_exit)** 协议 | 极简三元返回驱动整个循环 | Go struct 1:1 映射 |
| **文件级 IPC**（`_stop` / `_keyinfo` / `_intervene` / `output.txt`） | subagent 协议零依赖，可脚本化 | 保留，但加 fsnotify 替代轮询 |
| **L1 ≤30 行硬约束** + ROI 公式 | 省 token 的核心 | 代码层做 linter 强制 |
| **工具 Schema 每 10 轮重注入** | 防止长任务遗忘工具 | 保留 |
| **Mixin 多 LLM 故障转移 + spring-back** | 实测非常有用 | 用 Go interface 实现 |
| **真实浏览器接管**（Chrome MV3 扩展 + CDP Bridge） | 保留登录态的唯一可靠方案 | 复用扩展，Go 重写 WebSocket server |
| **生成器流式输出** | 前端能实时看到 Agent 在干什么 | Go `iter.Seq` / channel |

### 1.2 必须重点改造的部分（调研报告中识别的短板）

| Python 版短板 | 证据 | Go 版改进 |
|---|---|---|
| **L1 压缩靠模型自觉** | `memory_cleanup_sop.md` 是 markdown 建议，无代码强制 | **编译期 linter** `ga check` + 运行期 **Memory Guardian** 定时告警 |
| **`file_access_stats.json` 被采集但无人消费** | `ga.py:log_memory_access` 写但没人读 | **自动冷热分层**：6 个月没访问的 L3 自动归档 |
| **history 硬裁剪阈值过于乐观**（`context_win × 3`） | `llmcore.py:94` 门槛 ~84K 字符，到那一步 cache 已废 | **分级压缩**：60% / 75% / 90% 三档渐进压缩 |
| **SOP 本身会膨胀**（plan_sop.md 已 262 行） | 没机制阻止 SOP 长度 | SOP Schema 约束 + CI 检查 |
| **单文件巨型代码**（ga.py 561, llmcore.py 983, simphtml.py 870） | 可读性差 | 按职责拆成独立 package |
| **前端写法高度重复**（10 个 bot 文件，每个 120–2000 行） | chatapp_common 只能抽共享逻辑的 30% | **统一 `Frontend` 接口**，bot 实现 ≤ 150 行 |
| **端口硬编码冲突**（wechatapp=19531, wecomapp=19531） | 两者不能同跑 | 动态端口分配 + 服务注册中心 |
| **subagent IPC 纯文件轮询** | 低效，有竞态 | fsnotify + 文件保持兼容（双写机制） |
| **没有可观测性** | 只有 stdout log | 内置 Prometheus metrics + OpenTelemetry traces |
| **没有 CI/release** | 只有 pyproject.toml | GitHub Actions + goreleaser |
| **安全性**（`code_run inline_eval=True` 主进程 eval） | plan_sop 里就在用 | 改为显式 opt-in + 沙箱 |

### 1.3 可以舍弃的部分

| 舍弃项 | 理由 |
|---|---|
| `ClaudeSession` / `LLMSession`（文本协议）| 已被代码标注 `deprecated`，只服务弱模型，Go 版只做 Native |
| Streamlit / pywebview UI | 替换为内置 HTTP server + 单页 SPA（嵌入 binary） |
| `hub.pyw` tkinter 管理器 | Go 版用 systemd/launchd-style 子进程管理，或终端 TUI |
| 桌面宠物 | 纯好玩，v0.1 先不要 |
| Python 的 10 个 bot 文件，每个单独 main | 统一用 `ga bot <platform>` 子命令 |

---

## 2. 语言翻译的核心难点与方案

### 2.1 难点 1：Python Generator → Go 并发原语

**Python 原版**（`agent_loop.py`）:

```python
def agent_runner_loop(client, ...):
    while turn < max_turns:
        response = yield from client.chat(messages, tools_schema)  # 流式
        for tc in tool_calls:
            outcome = yield from handler.dispatch(tool_name, args, response)
            ...
```

`yield from` 同时做三件事：**流式产出文本** + **产出工具结果** + **驱动主循环**。这是 Python 协程的强项，Go 没有等价物。

**Go 方案**：用 **channel + context** 拆分成两个流。

```go
type StreamEvent interface { isStreamEvent() }

type (
    TextDelta struct{ Content string }
    ToolCall  struct{ Name string; Args map[string]any; ID string }
    TurnDone  struct{ Response *LLMResponse }
    Error     struct{ Err error }
)

// LLMClient.Chat 返回事件流
type LLMClient interface {
    Chat(ctx context.Context, msgs []Message, tools []ToolSchema) <-chan StreamEvent
}

// Tool 的流式产出用同样机制
type Tool interface {
    Name() string
    Schema() ToolSchema
    Invoke(ctx context.Context, args json.RawMessage, out chan<- StreamEvent) StepOutcome
}

// Agent Loop 的主循环
func (a *Agent) Run(ctx context.Context, prompt string, out chan<- StreamEvent) error {
    defer close(out)
    for turn := 1; turn <= a.maxTurns; turn++ {
        // 1. LLM chat（消费流到 out，同时收集 tool_calls）
        resp, toolCalls := a.streamLLM(ctx, out)

        // 2. 派发每个工具调用
        results := []ToolResult{}
        for _, tc := range toolCalls {
            outcome := a.dispatchTool(ctx, tc, resp, out)
            if outcome.ShouldExit { return nil }
            if outcome.NextPrompt == "" { return nil }  // CURRENT_TASK_DONE
            results = append(results, ToolResult{ID: tc.ID, Content: outcome.Data})
        }
        // 3. 构造下一轮 prompt
        a.messages = a.buildNextMessages(results, outcome.NextPrompt)
    }
    return ErrMaxTurnsExceeded
}
```

**如果用 Go 1.23+ 的 `iter.Seq`**，可以写得更优雅（但本质还是 channel 底层），v0.1 不强制。

### 2.2 难点 2：Python 反射动态派发 → Go 注册表

**Python 原版**（`ga.py:18-29`）:

```python
def dispatch(self, tool_name, args, response, index=0):
    method_name = f"do_{tool_name}"
    if hasattr(self, method_name):
        ret = yield from try_call_generator(getattr(self, method_name), args, response)
        return ret
```

**Go 方案**：显式注册表 + `ToolRegistry` 接口。

```go
type ToolRegistry struct {
    tools map[string]Tool
    mu    sync.RWMutex
}

func (r *ToolRegistry) Register(t Tool) {
    r.mu.Lock(); defer r.mu.Unlock()
    r.tools[t.Name()] = t
}

func (r *ToolRegistry) Dispatch(ctx context.Context, name string, args json.RawMessage, ...) StepOutcome {
    r.mu.RLock(); tool, ok := r.tools[name]; r.mu.RUnlock()
    if !ok { return StepOutcome{NextPrompt: fmt.Sprintf("未知工具 %s", name)} }
    return tool.Invoke(ctx, args, ...)
}

// 初始化
func NewDefaultRegistry(cfg *Config) *ToolRegistry {
    r := &ToolRegistry{tools: map[string]Tool{}}
    r.Register(&CodeRunTool{timeout: cfg.DefaultTimeout})
    r.Register(&FileReadTool{})
    r.Register(&FilePatchTool{})
    // ... 共 9 个
    return r
}
```

**收益**：编译期类型检查、IDE 跳转可用、单元测试可 mock 单个工具。

### 2.3 难点 3：SSE 解析 —— 保留但模块化

Python 版 `_parse_claude_sse` / `_parse_openai_sse` 各自 ~100 行，逻辑复杂但清晰。

**Go 方案**：直接用 `github.com/tmaxmax/go-sse` 做底层解析，上层只管业务事件类型。

```go
// internal/llm/claude/stream.go
func parseClaudeSSE(body io.Reader, out chan<- StreamEvent) error {
    sse := sse.NewParser(body)
    for {
        evt, err := sse.Next()
        if err == io.EOF { return nil }
        if err != nil { return err }
        // 按事件类型分发到 out
        switch evt.Type {
        case "message_start": handleStart(evt, out)
        case "content_block_delta": handleDelta(evt, out)
        case "tool_use": handleToolUse(evt, out)
        ...
        }
    }
}
```

**错误处理增强**：Python 版用"拼接 `!!!Error:` 到文本"作为哨兵（`_stream_with_retry`），Go 直接用 `StreamEvent.Error` 强类型，上层 switch 即可。

### 2.4 难点 4：`mykey.py` 动态热加载 → 配置中心

**Python 原版**：`importlib.reload(mykey)` + mtime 检查。

**Go 方案**：`spf13/viper` + `fsnotify`，支持多种格式（`mykey.yaml` / `mykey.toml` / `mykey.json`）。

```yaml
# mykey.yaml
llm_sessions:
  - name: gpt-native
    protocol: native_oai
    apikey: sk-xxx
    apibase: https://api.openai.com/v1
    model: gpt-5.4
  - name: claude-direct
    protocol: native_claude
    apikey: sk-ant-xxx
    apibase: https://api.anthropic.com
    model: claude-opus-4-7[1m]

mixin:
  llm_nos: [gpt-native, claude-direct]
  max_retries: 10
  spring_back: 300

frontends:
  telegram:
    bot_token: 123:ABC
    allowed_users: [12345]
  feishu:
    app_id: cli_xxx
    app_secret: xxx
    allowed_users: ['*']

observability:
  langfuse:
    public_key: pk-lf-xxx
    secret_key: sk-lf-xxx
```

**兼容旧 `mykey.py`**：v0.1 提供 `ga migrate-mykey` 命令，把 Python 字典变量扫出来生成 yaml。

### 2.5 难点 5：Python `file_patch` 的 "唯一匹配" 语义

Python 版用 `full_text.count(old_content)` 判断匹配数。Go 用 `strings.Count`，但要注意**文件可能是二进制或含 BOM**：

```go
func FilePatch(path, oldContent, newContent string) error {
    data, err := os.ReadFile(path)
    if err != nil { return err }
    // 去 BOM
    text := strings.TrimPrefix(string(data), "\ufeff")
    cnt := strings.Count(text, oldContent)
    switch {
    case cnt == 0: return ErrPatchNotFound
    case cnt > 1:  return fmt.Errorf("patch ambiguous: %d matches", cnt)
    }
    // 原子写（tmpfile + rename）
    return atomicWrite(path, strings.Replace(text, oldContent, newContent, 1))
}
```

---

## 3. 模块与目录设计

```
ga/
├── cmd/
│   └── ga/                          # 主 CLI 入口
│       ├── main.go
│       ├── run.go                   # ga run   REPL
│       ├── task.go                  # ga task  一次性任务
│       ├── reflect.go               # ga reflect  反射模式
│       ├── bot.go                   # ga bot <platform>  IM Bot
│       ├── serve.go                 # ga serve  HTTP UI
│       ├── check.go                 # ga check  记忆/SOP 检查器
│       └── migrate.go               # ga migrate-mykey
│
├── internal/
│   ├── agent/                       # 核心循环
│   │   ├── loop.go                  # Agent Loop (≤200 行)
│   │   ├── handler.go               # Handler / StepOutcome
│   │   ├── anchor.go                # working memory anchor 拼接
│   │   └── session.go               # Session 状态管理
│   │
│   ├── llm/                         # LLM 抽象层
│   │   ├── client.go                # LLMClient 接口
│   │   ├── session.go               # BaseSession
│   │   ├── claude/                  # Claude 协议
│   │   │   ├── session.go
│   │   │   ├── native.go            # NativeClaudeSession
│   │   │   └── stream.go            # SSE 解析
│   │   ├── openai/                  # OpenAI 协议
│   │   │   ├── session.go
│   │   │   ├── native.go
│   │   │   └── stream.go
│   │   ├── mixin/                   # 故障转移
│   │   │   └── mixin.go
│   │   └── cache/                   # 历史压缩 + prompt cache 标记
│   │       ├── compress.go
│   │       └── trim.go
│   │
│   ├── tools/                       # 9 个原子工具
│   │   ├── tool.go                  # Tool 接口
│   │   ├── registry.go              # ToolRegistry
│   │   ├── code_run.go
│   │   ├── file_read.go
│   │   ├── file_write.go
│   │   ├── file_patch.go
│   │   ├── web_scan.go
│   │   ├── web_execute_js.go
│   │   ├── ask_user.go
│   │   ├── working_checkpoint.go
│   │   └── long_term_update.go
│   │
│   ├── memory/                      # 分层记忆
│   │   ├── layers.go                # L0-L4 定义
│   │   ├── loader.go                # 注入系统提示
│   │   ├── guardian.go              # 【新增】容量守护进程
│   │   ├── cleanup.go               # 【新增】冷热分层归档
│   │   └── linter.go                # 【新增】L1/SOP 格式校验
│   │
│   ├── browser/                     # TMWebDriver 等价
│   │   ├── driver.go
│   │   ├── ws_server.go             # WebSocket server (port 18765)
│   │   ├── http_server.go           # bottle 等价 (18766)
│   │   ├── cdp.go                   # CDP Bridge 命令
│   │   ├── session.go               # Tab session
│   │   └── simphtml.go              # DOM 瘦身（JS 源码嵌入 embed.FS）
│   │
│   ├── frontend/                    # 前端接口
│   │   ├── frontend.go              # Frontend interface
│   │   ├── repl/                    # 终端 REPL
│   │   ├── web/                     # 内置 Web UI (嵌入 SPA)
│   │   │   ├── server.go
│   │   │   └── static/              # embed.FS
│   │   ├── telegram/
│   │   ├── feishu/
│   │   ├── dingtalk/
│   │   ├── wecom/
│   │   ├── wechat/                  # 个人微信 (HTTP 侧车)
│   │   ├── qq/
│   │   └── discord/
│   │
│   ├── subagent/                    # subagent 文件 IO 协议
│   │   ├── spawner.go
│   │   ├── watcher.go               # fsnotify
│   │   └── ipc.go                   # _stop/_keyinfo/_intervene
│   │
│   ├── reflect/                     # 反射模式
│   │   ├── runner.go
│   │   ├── autonomous.go            # 空闲触发
│   │   └── scheduler.go             # cron
│   │
│   ├── config/                      # 配置
│   │   ├── config.go                # viper 装载
│   │   ├── hotreload.go             # fsnotify 热重载
│   │   └── migrate.go               # Python mykey.py → yaml
│   │
│   ├── observability/               # 可观测性【新增】
│   │   ├── metrics.go               # Prometheus
│   │   ├── tracing.go               # OTel
│   │   └── langfuse.go              # 兼容 Python 版
│   │
│   └── util/
│       ├── log.go                   # slog 封装
│       ├── atomic_file.go
│       └── smart_format.go          # smart_format 等价
│
├── pkg/                             # 对外可复用
│   ├── toolapi/                     # 第三方写工具用的 API
│   └── sop/                         # SOP 读写辅助
│
├── assets/
│   ├── tools_schema.json            # 保留兼容
│   ├── sys_prompt.txt
│   ├── global_mem_insight_template.txt
│   ├── insight_fixed_structure.txt
│   ├── code_run_header.py           # 保留，用于沙箱
│   └── tmwd_cdp_bridge/             # MV3 扩展原封不动
│
├── memory/                          # 与 Python 版同路径兼容
│   └── (L0-L4 全部保留)
│
├── reflect/
│   └── (scheduler.py / autonomous.py 兼容模式或改 Go)
│
├── web/                             # Web UI 源码（不进 binary，前端独立构建）
│   └── src/
│
├── docs/
│   ├── ARCHITECTURE.md
│   ├── MIGRATION.md                 # Python → Go 迁移指南
│   ├── TOOL_DEVELOPMENT.md          # 如何写新工具
│   └── SOP_STYLE.md                 # SOP 写作规范
│
├── scripts/
│   ├── build.sh
│   └── release.sh
│
├── .github/workflows/               # CI
│   ├── test.yml
│   └── release.yml
│
├── go.mod
├── go.sum
├── Makefile
├── README.md
└── LICENSE
```

**代码量估计**（参考 `wc -l` Python 基线）：

| 模块 | Python 行数 | Go 估计 | 说明 |
|---|---|---|---|
| agent loop | 125 | 250 | 显式 context 传递 |
| tools (9 个) | 561 | 1100 | 每个工具独立文件 + 接口 |
| llm (3 协议) | 983 | 1500 | 更严格类型 + 更多 test |
| browser | 1156 | 1200 | 基本 1:1 |
| memory | 88 (sop 不算) | 300 | 加了 guardian/linter |
| frontend (7 个 bot) | 6035 | 1500 | 统一接口，每个 bot ≤200 行 |
| config | ~50 | 200 | viper + migrate |
| observability | 37 (langfuse) | 300 | metrics/traces |
| subagent/reflect | ~200 | 300 | |
| CLI | 50 (agentmain) | 250 | cobra 命令树 |
| **合计** | **~11.6K** | **~7K** | 更少代码，更多能力 |

---

## 4. 接口设计要点

### 4.1 `Tool` 接口

```go
package tools

type Tool interface {
    Name() string
    Schema() ToolSchema
    // Invoke：业务主体。流式事件写入 events chan。返回 StepOutcome 控制循环。
    Invoke(ctx context.Context, req InvokeRequest) (StepOutcome, error)
}

type InvokeRequest struct {
    Args     json.RawMessage
    Response *LLMResponse       // 用于 file_write / web_execute_js 从回复中提取代码块
    Index    int                // 多工具并发时的序号
    Events   chan<- StreamEvent
    Session  *Session
}

type StepOutcome struct {
    Data       any         // 返回给 LLM 的 tool_result
    NextPrompt string      // 下一轮 prompt，空字符串 = 任务完成
    ShouldExit bool        // 立即退出（ask_user）
}
```

### 4.2 `LLMClient` 接口

```go
package llm

type LLMClient interface {
    Name() string
    Chat(ctx context.Context, req ChatRequest) (*ChatResponse, <-chan StreamEvent, error)
    SetSystem(s string)
    SetTools(tools []ToolSchema)
    // 历史由 Client 自己维护（对应 Python 的 backend.history）
    History() *History
}

type ChatRequest struct {
    Messages []Message
    Tools    []ToolSchema
}

type ChatResponse struct {
    Content    string
    Thinking   string
    ToolCalls  []ToolCall
    StopReason string
    Usage      Usage
}
```

### 4.3 `Frontend` 接口（对应 Python 的 10 个 `*app.py`）

```go
package frontend

type Frontend interface {
    Name() string                          // "telegram" / "feishu" / ...
    Start(ctx context.Context, agent AgentAPI) error
    Stop() error
}

type AgentAPI interface {
    Submit(ctx context.Context, task Task) (<-chan AgentEvent, error)
    Abort()
    ListLLMs() []LLMInfo
    SwitchLLM(idx int) error
}

type AgentEvent struct {
    Type    EventType   // "progress" | "done" | "need_input"
    Content string
    Files   []string
    Err     error
}
```

统一接口后，**每个 bot 实现 ≤ 150 行**（只管协议转换 + 调用 `agent.Submit`）。

### 4.4 `Memory` 接口

```go
package memory

type Memory interface {
    // L0/L1/L2/L3/L4 的统一访问
    ReadLayer(layer Layer) (string, error)
    ReadSOP(name string) (string, error)
    ListL3() ([]SOPInfo, error)

    // 写入（带 guardian 检查）
    UpdateL1(patch PatchOp) error  // 强制 patch 不准 overwrite
    UpsertL3(name string, content string) error

    // 【新增】守护
    Stats() MemoryStats
    SuggestCleanup() []CleanupAction
}

type MemoryStats struct {
    L1Lines         int       // 预警阈值 30
    L1Bytes         int
    L3SOPCount      int
    L3LargestSOP    SOPInfo   // 超过 200 行预警
    ColdSOPs        []SOPInfo // 6+ 月未访问
    TotalMemoryKB   int
}
```

---

## 5. 【重点】针对 Python 版短板的改进方案

### 5.1 改进一：Memory Guardian —— 把"靠模型自觉"改为"代码强制"

**Python 版痛点**（调研报告 §5.5.5）：L1 长度、SOP 膨胀、冷条目归档完全靠模型执行 `memory_cleanup_sop`，用半年后会慢慢漂移。

**Go 版方案**：

```go
// internal/memory/guardian.go
type Guardian struct {
    mem      Memory
    rules    []Rule
    logger   *slog.Logger
    interval time.Duration
}

type Rule struct {
    Name      string
    Severity  Severity
    Check     func(stats MemoryStats) (violated bool, msg string)
    AutoFix   func(mem Memory) error   // 可选，nil 则只告警
}

var DefaultRules = []Rule{
    {
        Name: "L1_too_long",
        Severity: Warning,
        Check: func(s MemoryStats) (bool, string) {
            if s.L1Lines > 30 { return true, fmt.Sprintf("L1 %d 行（硬上限 30）", s.L1Lines) }
            return false, ""
        },
        // 不自动修，只告警——记忆修改是敏感操作
    },
    {
        Name: "SOP_too_long",
        Check: func(s MemoryStats) (bool, string) {
            if s.L3LargestSOP.Lines > 200 {
                return true, fmt.Sprintf("%s 已 %d 行，建议拆分", s.L3LargestSOP.Name, s.L3LargestSOP.Lines)
            }
            return false, ""
        },
    },
    {
        Name: "cold_sop_archive",
        Severity: Info,
        Check: func(s MemoryStats) (bool, string) {
            if len(s.ColdSOPs) > 0 { return true, fmt.Sprintf("%d 个冷 SOP 可归档", len(s.ColdSOPs)) }
            return false, ""
        },
        AutoFix: archiveColdSOPs,  // 自动移到 memory/archive/
    },
}

// 每小时跑一次
func (g *Guardian) Run(ctx context.Context) {
    ticker := time.NewTicker(g.interval)
    for {
        select {
        case <-ctx.Done(): return
        case <-ticker.C:
            stats := g.mem.Stats()
            for _, r := range g.rules {
                if violated, msg := r.Check(stats); violated {
                    g.logger.Log(ctx, r.Severity.SlogLevel(), msg, "rule", r.Name)
                    metrics.MemoryRuleViolation.WithLabelValues(r.Name).Inc()
                }
            }
        }
    }
}
```

暴露 CLI 手动触发：

```bash
ga check memory              # 一次性扫描，输出报告
ga check memory --fix        # 自动执行所有 AutoFix
```

### 5.2 改进二：History 分级压缩 —— 替换 84K 硬阈值

**Python 版**：只有 1 个阈值（`context_win × 3`），到了才硬裁剪 pop 消息。

**Go 版**：3 档渐进策略。

```go
// internal/llm/cache/trim.go
type CompressPolicy struct {
    SoftThreshold  float64  // 0.6：压缩 tag body 到 800 字符
    MediumThreshold float64 // 0.75：压缩所有非最近 5 条的 tool_result
    HardThreshold   float64 // 0.9：按 FIFO 裁剪老消息
}

func (c *Compressor) Compress(h *History, ctxWin int) CompressAction {
    ratio := float64(h.Size()) / float64(ctxWin)
    switch {
    case ratio < c.Soft:
        return NoOp
    case ratio < c.Medium:
        return CompressTagBodies(h, 800)
    case ratio < c.Hard:
        return CompressToolResults(h, 400, keepRecent=5)
    default:
        return TrimOldest(h, targetRatio=0.5)
    }
}
```

**关键**：不等到触底才压缩。60% 就开始压 tag body（对用户无感，因为是老消息的 `<thinking>`），75% 压 tool_result，90% 才裁剪——到那一步也不会让 cache 完全失效，而是保留最近 5 条不动，老消息 FIFO。

### 5.3 改进三：file_access_stats 真正被消费

**Python 版**：`ga.py:log_memory_access` 写 JSON，但**没有任何代码读它**。

**Go 版**：

```go
// internal/memory/cleanup.go
type AccessStats struct {
    file string  // memory/file_access_stats.json
}

func (s *AccessStats) ColdSOPs(threshold time.Duration) []SOPInfo {
    all := s.loadAll()
    now := time.Now()
    cold := []SOPInfo{}
    for name, info := range all {
        if now.Sub(info.LastAccess) > threshold {
            cold = append(cold, SOPInfo{Name: name, LastAccess: info.LastAccess, Count: info.Count})
        }
    }
    return cold
}

// 默认 6 个月没读过 → 提示归档
// ga check memory --fix 会执行：mv memory/<name>.md → memory/archive/<name>.md
//                              同步从 L1 删对应触发词
```

**L1 同步删除是关键**：归档但不改 L1 = L1 变成"指向废文件的僵尸指针"，反而更坏。所以 AutoFix 要同时改两处。

### 5.4 改进四：SOP Schema + Linter

**Python 版**：SOP 是纯 markdown，无任何格式约束。

**Go 版**：用 front-matter 定义元信息。

```markdown
<!-- ga-sop: v1 -->
---
name: plan_sop
triggers: [plan, 规划, 计划模式, 多步骤任务]
max_lines: 200
related_tools: [code_run, file_read, file_patch]
verify_required: true
---

# Plan Mode SOP
...
```

`ga check sop` 会：
- 检查 `max_lines` 是否超
- 检查 `triggers` 是否在 L1 里有对应触发词
- 检查 `related_tools` 是否都存在
- 输出 JSON 报告供 CI 用

### 5.5 改进五：前端接口统一 —— 从 6035 行压到 1500 行

**Python 版**：每个 bot 独立实现协议转换、消息分段、文件处理、日志、单实例锁 —— 10 个文件大量重复。

**Go 版**：抽象为 `BaseBot` + 平台适配层。

```go
// internal/frontend/bot.go
type BaseBot struct {
    name      string
    agent     AgentAPI
    allowed   AllowedUsers
    splitSize int
    formatter MessageFormatter  // markdown 清洗
    logger    *slog.Logger
}

func (b *BaseBot) HandleMessage(ctx context.Context, from string, text string, files []string) {
    if !b.allowed.Check(from) { return }
    task := Task{Prompt: text, Files: files, Source: b.name}
    events, _ := b.agent.Submit(ctx, task)
    for ev := range events {
        segments := b.formatter.Format(ev.Content, b.splitSize)
        for _, s := range segments { b.send(from, s) }
    }
}

// 每个平台只需实现 send() 和 接收逻辑
type TelegramBot struct { BaseBot; api *tgbotapi.BotAPI }
func (t *TelegramBot) send(uid, msg string) error { /* 20 行 */ }
func (t *TelegramBot) Start(ctx context.Context, agent AgentAPI) error {
    updates := t.api.GetUpdatesChan(...)
    for u := range updates {
        go t.BaseBot.HandleMessage(ctx, u.From(), u.Text(), u.Files())
    }
    return nil
}
```

实测 Python 版 tgapp.py 的 917 行，80% 是 markdown 清洗、消息分段、流式更新这些可共享的逻辑。Go 版每个 bot 的平台特定代码 ≤ 150 行。

### 5.6 改进六：端口冲突 —— 服务注册中心

**Python 版**：端口硬编码（wechatapp=19531, wecomapp=19531 撞车）。

**Go 版**：

```go
// internal/frontend/registry.go
type ServiceRegistry struct {
    services map[string]*ServiceMeta
    portFrom int  // 从 19500 开始扫
    portTo   int
}

func (r *ServiceRegistry) Register(name string) (port int, err error) {
    for p := r.portFrom; p <= r.portTo; p++ {
        if l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", p)); err == nil {
            l.Close()
            r.services[name] = &ServiceMeta{Port: p, Started: time.Now()}
            r.persist()  // 写 ~/.ga/services.json
            return p, nil
        }
    }
    return 0, ErrNoPortAvailable
}
```

`ga status` 全局查看：

```
$ ga status
┌────────────┬───────┬──────────────┬──────────┐
│ SERVICE    │ PORT  │ STARTED      │ STATUS   │
├────────────┼───────┼──────────────┼──────────┤
│ wechat-bot │ 19501 │ 2h ago       │ running  │
│ wecom-bot  │ 19502 │ 5m ago       │ running  │   ← 不再冲突
│ tg-bot     │ 19503 │ 2h ago       │ running  │
│ scheduler  │ 19504 │ 2h ago       │ running  │
└────────────┴───────┴──────────────┴──────────┘
```

### 5.7 改进七：subagent IPC —— fsnotify 替代轮询

**Python 版**（`agentmain.py` 轮询 reply.txt 等）：每 2 秒扫一次，10 分钟超时。

**Go 版**：

```go
// internal/subagent/watcher.go
func (w *Watcher) WaitFor(ctx context.Context, file string, timeout time.Duration) ([]byte, error) {
    fw, err := fsnotify.NewWatcher()
    if err != nil { return nil, err }
    defer fw.Close()
    fw.Add(filepath.Dir(file))

    deadline := time.After(timeout)
    for {
        // 文件可能已存在
        if data, err := os.ReadFile(file); err == nil {
            os.Remove(file)  // 消费
            return data, nil
        }
        select {
        case ev := <-fw.Events:
            if ev.Name == file && ev.Op.Has(fsnotify.Create|fsnotify.Write) {
                continue  // 下次循环读
            }
        case <-deadline:
            return nil, ErrSubagentTimeout
        case <-ctx.Done():
            return nil, ctx.Err()
        }
    }
}
```

**兼容性**：接口不变（还是 `reply.txt` / `_stop` / `_keyinfo`），老的 bash 脚本照样能写这些文件触发。纯粹内部优化。

### 5.8 改进八：可观测性原生化

**Python 版**：只有 `plugins/langfuse_tracing.py`，而且是 monkey-patch 挂钩。

**Go 版**：OTel + Prometheus 原生，Langfuse 作为 exporter 之一。

```go
// internal/observability/tracing.go
var (
    MetricTurnsTotal    = promauto.NewCounterVec(...)
    MetricToolLatency   = promauto.NewHistogramVec(...)
    MetricLLMTokens     = promauto.NewCounterVec(...) // input/output/cached
    MetricMemoryL1Lines = promauto.NewGauge(...)      // 实时指标
)

// Agent Loop 每轮都生成 span
func (a *Agent) Run(ctx context.Context, ...) error {
    ctx, span := tracer.Start(ctx, "agent.turn")
    defer span.End()
    span.SetAttributes(
        attribute.Int("turn", a.turn),
        attribute.String("llm", a.llm.Name()),
    )
    // ...
}
```

暴露：
- `/metrics` (Prometheus)
- `/debug/pprof/*` (Go 原生 pprof)
- Langfuse Exporter 可选配置

### 5.9 改进九：code_run 沙箱 —— 关闭 `inline_eval` 注入面

**Python 版**：`do_code_run` 里 `args.inline_eval=True` 时直接 `eval(code, ns)` 在主进程——plan_sop 里靠这个调 `handler.enter_plan_mode`。这是**提示注入的大洞**：LLM 被恶意 prompt 骗到调 `inline_eval` 就能跑任意代码。

**Go 版**：

1. **彻底删除 `inline_eval`**：plan 模式的入口改用新工具 `enter_plan_mode`（独立注册，参数是 plan.md 路径）
2. **code_run 默认沙箱**：Linux 用 `gVisor` / `bubblewrap`，macOS 用 `sandbox-exec` profile，Windows 用 AppContainer
3. **允许用户显式关闭沙箱**：`--unsafe-code-run` flag（生产环境警告）

```go
// internal/tools/code_run.go
type CodeRunTool struct {
    sandbox Sandbox  // interface: Linux/macOS/Windows 各一个实现
    unsafe  bool
}

func (t *CodeRunTool) Invoke(ctx context.Context, req InvokeRequest) (StepOutcome, error) {
    args := parseArgs(req.Args)
    var cmd *exec.Cmd
    if t.unsafe {
        cmd = exec.CommandContext(ctx, "python3", "-X", "utf8", "-u", tmpFile)
    } else {
        cmd = t.sandbox.Wrap(ctx, "python3", []string{"-X", "utf8", "-u", tmpFile})
    }
    // ...
}
```

---

## 6. 分阶段实施路线（12 周）

### 阶段 0：POC（1 周）

**目标**：证明核心 Agent Loop 能跑通，LLM → 1 个工具 → 回答。

**交付**：
- [ ] `go.mod` + 目录骨架
- [ ] `LLMClient` 接口 + OpenAI `chat/completions` 实现
- [ ] `Tool` 接口 + `file_read` 工具
- [ ] Agent Loop 最小版本（50 行）
- [ ] 单元测试：把 mock LLM 灌进去能调 `file_read`

**验收脚本**：

```bash
go test ./internal/agent/... -v
./ga run --input "读一下 README.md 前 20 行"
```

### 阶段 1：核心完整（3 周）

**目标**：9 个工具全部实现，3 种 LLM 协议（Claude/OpenAI Native/Mixin），分层记忆读取。

**交付**：
- [ ] 9 个工具（file_write/patch 最复杂，其余中等）
- [ ] Claude SSE 解析
- [ ] OpenAI Chat Completions + Responses
- [ ] MixinSession（3 个测试 session 故障转移）
- [ ] 历史压缩 3 档
- [ ] L0–L4 记忆读取（兼容 Python 版目录结构）
- [ ] sys_prompt + L1 注入
- [ ] REPL 前端（最基础的 stdin/stdout）

**验收**：跑完 Python 版 `memory/` 下 14 个 SOP 对应的所有场景，行为 1:1 对齐。

### 阶段 2：浏览器与 Subagent（2 周）

**目标**：TMWebDriver 等价功能 + subagent 模式。

**交付**：
- [ ] WebSocket server (18765)
- [ ] HTTP server (18766) + /link 远程模式
- [ ] MV3 扩展兼容测试（扩展不动，server 对上）
- [ ] simphtml（JS 源码用 `embed.FS` 塞 binary）
- [ ] CDP Bridge 命令分发
- [ ] subagent spawner + fsnotify IPC
- [ ] `ga task --name xxx --input "..."` 子命令

**验收**：README 里的"Google 图搜"、"B 站历史视频"、"淘宝搜 iPhone"demo 跑通。

### 阶段 3：Bot 前端（2 周）

**目标**：7 个 Bot 适配器全部实现。

**交付**：
- [ ] `BaseBot` + `Frontend` 接口
- [ ] Telegram（`gotgbot/v2`）
- [ ] 飞书（官方 Go SDK `larksuite/oapi-sdk-go`）
- [ ] 钉钉（官方 Go SDK）
- [ ] Discord（`bwmarrin/discordgo`）
- [ ] 企业微信（自实现 WebSocket 连接）
- [ ] **个人微信**（HTTP 侧车：Go 核心 + Python 侧车保留原 `WxBotClient`）
  - 理由：iLink 协议逆向成本高，侧车方案最快
- [ ] QQ（自实现 `qq-botpy` 的 WebSocket 协议）
- [ ] Web UI（Vue3 + embed.FS）

**个人微信侧车架构**：

```
ga (Go 主进程) ◄──── HTTP ──── ga-wx-bridge (Python, 15 行)
                                    │
                                    └─ frontends/wechatapp.py 的 WxBotClient
```

`ga-wx-bridge` 是 10-20 行的 Flask server，只做 `login_qr` / `send_text` / `get_updates` 的 HTTP 代理。Go 侧像调用 REST API 一样用。好处：**个人微信协议变化时只改 Python 侧车**，核心不动。

### 阶段 4：改进项（2 周）

**目标**：实现 §5 的 9 项改进。

**交付**：
- [ ] Memory Guardian 定时扫描
- [ ] `ga check memory` CLI + AutoFix
- [ ] cold SOP 归档逻辑
- [ ] SOP front-matter 解析 + linter
- [ ] 服务注册中心 + `ga status`
- [ ] sandbox 包装（3 个平台）
- [ ] Prometheus /metrics
- [ ] OTel tracing
- [ ] Langfuse exporter

### 阶段 5：可观测性 + CI/CD（1 周）

**目标**：生产就绪。

**交付**：
- [ ] GitHub Actions：test + lint + golangci-lint
- [ ] goreleaser：macOS intel/arm, Linux x64/arm64, Windows x64
- [ ] Docker 镜像（轻量 + 完整两版）
- [ ] Grafana dashboard JSON（记忆指标、LLM 调用、token 消耗）
- [ ] 迁移文档 `docs/MIGRATION.md`
- [ ] `ga migrate-mykey` 命令

### 阶段 6：兼容性 + 文档（1 周）

**目标**：Python 用户无痛迁移。

**交付**：
- [ ] 读取 Python 版 `temp/model_responses/` 的历史能恢复会话
- [ ] `memory/` 目录格式完全兼容（新旧版可互相读）
- [ ] `assets/tools_schema.json` 格式不变
- [ ] README、ARCHITECTURE.md、TOOL_DEVELOPMENT.md
- [ ] 迁移演示视频

**里程碑总结**：

| 阶段 | 周数 | 累计 | 里程碑 |
|---|---|---|---|
| 0 POC | 1 | 1 | Agent Loop 跑通 |
| 1 核心 | 3 | 4 | 9 工具 + 3 协议 + 记忆 |
| 2 浏览器 | 2 | 6 | 完整功能对齐 Python v1.0 |
| 3 Bot | 2 | 8 | 7 个 IM 平台全部支持 |
| 4 改进 | 2 | 10 | §5 所有短板修复 |
| 5 发布 | 1 | 11 | v0.1.0 Release |
| 6 兼容 | 1 | 12 | Python 用户可平滑迁移 |

---

## 7. 依赖清单（Go 生态选型）

| 用途 | 库 | 理由 |
|---|---|---|
| CLI 框架 | `spf13/cobra` | 生态最成熟 |
| 配置 | `spf13/viper` | yaml/toml/json/env 统一 |
| 日志 | `log/slog` (stdlib) | Go 1.21+ 标准 |
| SSE 解析 | `tmaxmax/go-sse` | 比手写稳健 |
| HTTP 客户端 | `net/http` + `hashicorp/go-retryablehttp` | 带重试和退避 |
| HTML 解析 | `PuerkitoBio/goquery` | jQuery 风格，对应 Python bs4 |
| WebSocket | `coder/websocket` | 比 gorilla/websocket 更现代 |
| 文件监视 | `fsnotify/fsnotify` | 跨平台事实标准 |
| Telegram | `PaulSonOfLars/gotgbot` v2 | 异步友好 |
| 飞书 | `larksuite/oapi-sdk-go` | 官方 |
| 钉钉 | `open-dingtalk/dingtalk-stream-sdk-go` | 官方 |
| Discord | `bwmarrin/discordgo` | 社区事实标准 |
| OTel | `go.opentelemetry.io/otel` | 原生 |
| Prometheus | `prometheus/client_golang` | 原生 |
| 进程沙箱 (Linux) | 调用 `bubblewrap` 二进制 | 比 container runtime 轻 |
| 测试 | `testing` + `stretchr/testify` | |

**避免使用**（评估后放弃）：
- `langchain-go`：过度抽象，与 GenericAgent "极简" 理念冲突
- `go-openai`（sashabaranov）：没法兼容 Claude，自己写更灵活
- `docker/cli`：沙箱太重，改用 bubblewrap/sandbox-exec

---

## 8. 风险与应对

### 8.1 高风险项

| 风险 | 概率 | 影响 | 应对 |
|---|---|---|---|
| **Chrome 扩展 MV3 协议变化** | 中 | 高 | 扩展 version pin，WebSocket server 做协议版本协商 |
| **个人微信 iLink 协议变动** | 高 | 中 | 侧车架构隔离，只需改 Python 10 行 |
| **LLM 供应商 API 变更** | 中 | 中 | 接口层抽象充分，每个供应商独立 package |
| **Python 记忆文件被 Go 版误改** | 低 | 高 | 所有写操作原子 + 备份到 `memory/.backup/` |
| **迁移时数据丢失** | 中 | 高 | `ga migrate` 只读不写，输出新目录 |

### 8.2 中风险项

| 风险 | 应对 |
|---|---|
| Go 1.22+ 要求过新 | 最低 1.21，特性降级 |
| 沙箱在不同发行版兼容性差 | 只保证 3 个主流（Ubuntu/Debian/Alpine + macOS + Windows 10+） |
| CGo 依赖（CV/OCR） | 用 pure Go 方案，或调外部 `rapidocr` CLI（沿用 Python 版思路） |

### 8.3 不打算解决的问题

- **Windows 自动化 API 完整性**：`ljqCtrl.py` 用的 `win32api` 生态 Go 没对等物。方案：保留 `memory/ljqCtrl.py`，让 Go 通过 `code_run` 调 Python 脚本（GenericAgent 的本意就是如此）
- **视觉/OCR 模型**：不在 Go 核心里做，走 `code_run` 调外部 rapidocr
- **桌面宠物**：纯娱乐，v1 不做

---

## 9. 兼容性策略

### 9.1 文件层兼容（零改动迁移）

| 资源 | 兼容性 |
|---|---|
| `memory/*.md` | 完全兼容（Go 版直接读） |
| `memory/global_mem_insight.txt` | 完全兼容 |
| `memory/global_mem.txt` | 完全兼容 |
| `memory/*.py`（L3 Python 工具脚本） | 完全兼容（Agent 用 code_run 调） |
| `sche_tasks/*.json` | 完全兼容 |
| `temp/model_responses/` | 完全兼容（可互相恢复会话） |
| `assets/tmwd_cdp_bridge/` | 完全兼容（扩展不改） |
| `mykey.py` | 需要 `ga migrate-mykey` 转成 `mykey.yaml` |

### 9.2 行为层兼容

- 工具 schema 1:1（LLM 端零感知切换）
- slash 命令兼容（`/new`、`/continue`、`/llm`、`/session.xxx=y`）
- subagent IPC 文件协议 1:1
- scheduler 定时任务 JSON 格式 1:1

### 9.3 非兼容的改动（需文档说明）

| 改动 | 原因 | 迁移办法 |
|---|---|---|
| 删除 `inline_eval=True` | 安全 | plan 模式改用独立工具 `enter_plan_mode` |
| 端口动态分配 | 解决冲突 | 用 `ga status` 查询实际端口 |
| `pyproject.toml` 消失 | Go 项目不需要 | `go install` 替代 pip install |

---

## 10. 验收标准

### 10.1 功能等价性

- [ ] Python 版 `memory/` 下 14 个 SOP 对应的用户场景，Go 版全部能跑通
- [ ] 7 个 IM 平台的典型对话（发文本 / 发图 / 发文件 / 命令）行为与 Python 版一致
- [ ] `temp/model_responses/*.txt` 能在两个版本间互相恢复会话

### 10.2 性能指标

| 指标 | Python 基线 | Go 目标 |
|---|---|---|
| 启动时间（到"监听中"） | ~3s | ≤500ms |
| 内存占用（空闲） | ~80MB | ≤30MB |
| 单次 LLM 调用 overhead（除网络） | ~50ms | ≤5ms |
| 并发 subagent 数 | ≤3（CPython GIL 限制） | ≥20 |

### 10.3 质量指标

- [ ] 单元测试覆盖率 ≥ 70%（核心 package ≥ 85%）
- [ ] `golangci-lint` 零警告
- [ ] `ga check memory` 零告警（默认配置）
- [ ] README 里的所有示例命令可直接 copy 运行

---

## 11. 开源协作路径

1. **阶段 0-2 单人开发**：核心架构期，快速决策、避免协作开销
2. **阶段 3 开放 PR**：Bot 适配器每个平台一个 PR，社区可认领
3. **阶段 4+ 完全开源**：改进项通过 issue/RFC 讨论

命名建议：仓库 `github.com/<owner>/ga` 或 `generic-agent-go`；不要用 `ga-go`（搜索噪声）。

---

## 12. 附录 A：关键代码映射速查表

| Python 文件:行 | Go 位置 | 关键函数 |
|---|---|---|
| `agent_loop.py:42-99` | `internal/agent/loop.go` | `(*Agent).Run` |
| `ga.py:261-561` | `internal/tools/*.go` | 9 个 Tool 实现 |
| `ga.py:509-519` | `internal/agent/anchor.go` | `(*Session).BuildAnchor` |
| `ga.py:521-548` | `internal/agent/loop.go` | `turnEndCallback` |
| `llmcore.py:509-567` | `internal/llm/session.go` | `BaseSession` |
| `llmcore.py:587-603` | `internal/llm/claude/session.go` | `ClaudeSession` |
| `llmcore.py:637-695` | `internal/llm/claude/native.go` | `NativeClaudeSession` |
| `llmcore.py:729-828` | 删除（Go 版只做 Native） | - |
| `llmcore.py:871-930` | `internal/llm/mixin/mixin.go` | `MixinSession` |
| `llmcore.py:33-63` | `internal/llm/cache/compress.go` | `Compressor.Compress` |
| `TMWebDriver.py:*` | `internal/browser/*.go` | `Driver` |
| `simphtml.py:*` | `internal/browser/simphtml.go` | `SimplifyHTML` |
| `agentmain.py:42-172` | `internal/agent/session.go` + `cmd/ga/run.go` | - |
| `agentmain.py:178-200` | `cmd/ga/main.go` | cobra 根命令 |
| `reflect/scheduler.py` | `internal/reflect/scheduler.go` | 保留 Python 作兼容 |
| `frontends/tgapp.py` | `internal/frontend/telegram/bot.go` | ≤150 行 |

---

## 13. 附录 B：决策记录（ADR）

### ADR-001：为什么不是 Rust？

Rust 更快更安全，但：
- Go 的并发模型（goroutine + channel）更贴合 Agent Loop 的"多轮流式"语义
- Go 的编译速度、二进制大小、交叉编译体验都足够好
- Go 生态里的 IM SDK 成熟度比 Rust 高一个数量级（飞书/钉钉官方 Go SDK 都有，Rust 基本没有）
- 团队学习成本：Go 2 周上手，Rust 2 个月

### ADR-002：为什么保留 Python 侧车而不是全 Go？

- **个人微信 iLink 协议**：Python 版的 `WxBotClient` 已经 400 行逆向工程成果，重写成 Go 需 1-2 周且不稳定
- **rapidocr / cv2**：Python 生态成熟，Go CGo 绑定质量参差
- **`memory/*.py` 工具脚本**：用户已经在用，迁移会破坏自我进化累积的技能
- **哲学**：GenericAgent 的设计就是"主体极简，能力通过调外部脚本扩展"——侧车契合这个理念

### ADR-003：为什么不直接用 `langchain-go`？

- langchain 的抽象粒度与 GenericAgent 的"9 原子工具"冲突
- langchain 推崇的 agent 模板（ReAct/Plan-Execute/...）GenericAgent 全部拒绝，它就是个裸循环
- 依赖 langchain = 继承它的所有设计债

### ADR-004：为什么记忆依然用文件而不是数据库？

- SQLite/BoltDB 会带来 schema migration 负担
- Markdown 可被人类直接编辑、git diff、用任何编辑器维护
- "LLM 自己读自己的记忆"这个哲学要求文本可读
- 文件 I/O 的延迟对 Agent Loop 完全够用（~100μs vs LLM ~2s）

---

## 14. 一页总结

**做什么**：用 Go 重写 Python 版 GenericAgent（~11.6K → ~7K 行）。

**为什么值得**：
1. 单二进制部署，脱离 pip 依赖地狱
2. 原生并发，subagent 并发数 10 倍提升
3. 把"靠模型自觉"的记忆维护改为代码层强制
4. 统一前端接口，10 个 bot 6K 行 → 1.5K 行

**核心 9 项改进**：
Memory Guardian / History 分级压缩 / 冷 SOP 归档 / SOP linter / 前端接口统一 / 服务注册中心 / fsnotify IPC / 原生可观测 / code_run 沙箱

**3 个大决策**：
- Only Native（删除文本协议 Client）
- 个人微信保留 Python 侧车
- 记忆依然是文件（不引入数据库）

**12 周里程碑**：
POC(1) → 核心(3) → 浏览器(2) → Bot(2) → 改进(2) → 发布(1) → 兼容(1)

**最大风险**：个人微信协议变动 / Chrome 扩展 MV3 协议变动 —— 用侧车架构和版本协商规避。

---

**文档版本历史**：
- v1.0 (2026-05-02)：首版
