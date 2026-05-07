# GenericAgent → Go 重写实施方案 v2

> **文档编号**：GA-GO-002
> **版本**：v2.0
> **日期**：2026-05-02
> **变更说明**：在吸收项目作者自分析文档 `ga_architecture_analysis(2).md` 后的深度修订版
> **前置阅读**：v1 方案 `docs/GO_REWRITE_PLAN.md`、作者自分析 `ga_architecture_analysis(2).md`

---

## 0. v2 修订摘要

本版的本质变化不是"加功能"，而是**重新理解了要做什么**。

v1 把 Go 重写当作一次"从动态语言到静态语言的翻译工程"，列了 9 项"短板改进"，其中 5 项是在用工程思维修复**看起来像问题、实则是架构特征**的东西。吸收作者自分析后，v2 做以下修订：

### 0.1 撤销的 v1 改进（共 5 项）

| v1 编号 | v1 改进项 | 撤销理由（作者哲学） |
|---|---|---|
| 5.4 | SOP Schema + Linter（front-matter） | **SOP 是"运行在 LLM 上的程序"，用自然语言写成**。给 SOP 强加 YAML 结构 = 回退到"用代码校验自然语言"的老路，违背 LLM-native 设计 |
| 5.1 AutoFix | Memory Guardian 自动归档冷 SOP | **"神圣不可删改性"是 L0 核心公理**（memory_management_sop.md §0.2）。自动删改是架构红线 |
| 5.9 | 删除 `code_run.inline_eval` | plan_sop 依赖它触发 `handler.enter_plan_mode`。它不是"提示注入漏洞"，而是**LLM 调用内核能力的 hook**。要做的是"标记为高权限"，不是删除 |
| 10.2 | 性能指标（启动 ≤500ms、内存 ≤30MB） | **瓶颈 100% 在 LLM 响应**（秒级），Go runtime 的百毫秒级优化对用户无感。错把"语言对决"当目标 |
| 5.2（部分） | History 更激进压缩（60/75/90 三档） | 作者明确："遗忘同时是弱点和优势，丢失信息是代价，丢弃偏见是收益。working_checkpoint + summary 本质上是**选择性遗忘机制**"。激进压缩会破坏这个特性 |

### 0.2 保留的 v1 改进（共 4 项，纯工程收益）

| v1 编号 | 改进项 | 保留理由 |
|---|---|---|
| 5.5 | 前端接口统一（BaseBot） | 不触及 LLM-SOP-Memory 三层，纯代码复用 |
| 5.6 | 服务注册中心 + 动态端口 | 不改 Agent 行为，只解决部署冲突 |
| 5.7 | fsnotify 替代轮询 | 接口不变的内部优化 |
| 5.8 | 原生可观测性（metrics/traces） | 只**观测**不干预，为弱点分析提供数据 |

### 0.3 新增的 v2 核心改进（共 4 项，围绕两个真弱点）

| 编号 | 名称 | 针对的弱点 |
|---|---|---|
| **6.1** | **SOP 遵从性追踪器（Compliance Tracer）** | 概率性遵从 |
| **6.2** | **任务完成闸门（Done Gate）** | 缺乏主动验证 |
| **6.3** | **工具使用频谱分析（Tool Spectrum）** | 缺乏主动验证 |
| **6.4** | **动态 RULES 注入（Context-aware Anchor）** | 概率性遵从 |

**关键原则**：这四项改进**都是观察 + 温和引导**，绝不做**强制拦截 / 自动修改记忆 / 代替 LLM 决策**。原因见 §1.3。

---

## 1. 根本性重新定位

### 1.1 Go 重写的真正目标（修订版）

作者一句话总结：
> GA 是一个 LLM-native 架构：代码做管道，SOP 做程序，LLM 做 CPU，记忆做硬盘。

把这个类比跑通，Go 重写的目标应该是：**做一个更可靠的 runtime，给非确定性的 LLM-CPU 用**。

这意味着：

| 方面 | v1 想法（错） | v2 想法（对） |
|---|---|---|
| 角色 | Python 版的替代品 | "LLM-CPU 的操作系统" |
| 价值主张 | 更快、更小、并发强 | 更稳、更透明、更好观察 |
| "代码短就是美"的看法 | Go 版 ~7K 行可接受 | **坚守 ~3K 核心**的数量级，新增代码只能在"观测层"，不能在"控制层" |
| 性能指标 | Go 基准跑分 | 7×24 小时不崩、LLM 故障优雅降级、指标可 export |
| 与 Python 版的关系 | 取代 | **长期共存**（Python 作 L3 工具脚本宿主，Go 作核心 runtime） |

### 1.2 架构分层清晰化（作者原图 + Go 版映射）

```
┌──────────────────────────────────────────┐
│ 记忆层（硬盘）                             │ ← 纯文件，Go 只读不自动改
│  L1 ≤30 行索引 / L2 事实 / L3 SOP / L4 归档 │
├──────────────────────────────────────────┤
│ SOP 层（软代码，运行在 LLM 上）             │ ← 只作为输入，不当作配置解析
│  ~53 个 .md + ~15 个 .py                  │
├──────────────────────────────────────────┤
│ 代码层（硬代码，Go 实现）                  │ ← 全部重写范围
│  Agent Loop / 9 Tools / LLM / Browser ... │
├──────────────────────────────────────────┤
│ 观测层【v2 新增】                          │ ← 不改行为，只记录
│  Tracer / Metrics / Spectrum / Gate      │
└──────────────────────────────────────────┘
```

**v1 犯的错**：把"SOP 层"当"配置层"来处理（想给它加 schema、linter）。这违反了 SOP 的本质——SOP 是写给 LLM 读的自然语言程序，不是写给解析器读的结构化数据。

**v2 的处理**：**SOP 层对 Go 代码完全透明**。Go 只负责"按约定路径读文件、按约定方式喂给 LLM"，不解析、不校验、不改写 SOP 内容。

### 1.3 为什么新增改进只能"观察 + 引导"，不能"强制"

作者自分析已经给出哲学答案，这里工程化表述一遍。

**第一条原则：不能用代码强制概率性主体**。

如果用 Go 代码做"LLM 必须读 SOP 才能调 X 工具"这种硬拦截：
- 当 LLM 实际上已经知道答案（靠世界知识）却被强制读 SOP → 浪费 token、降质量
- 当 LLM 应该读但它判断不读 → 拦截只会导致它瞎猜一个 SOP 名去"糊弄"

**第二条原则：代码层的任务不是让 LLM 做对，而是让错能被发现**。

所以 v2 的 4 项新改进都是"事后可追溯、实时可观察、不阻塞主流程"。

**第三条原则**（从作者"SOP 遵从是概率性的"推论）：**代码层的每次拦截，都是对 LLM 智能的质疑**。应极度克制，且必须保留 LLM "说服代码放行"的通道（ask_user 升级路径）。

---

## 2. 架构决策的重新审视

### 2.1 原 v1 §1.2 "短板清单" 的重新分类

| v1 认定的短板 | 作者视角 | v2 处理 |
|---|---|---|
| L1 压缩靠模型自觉 | 这是**自演化的必要条件**（模型判断 ROI），非 bug | **观察**：统计 L1 增长趋势，超阈值**提醒用户**（不自动改） |
| file_access_stats.json 无人消费 | 它本来就只是"埋点数据"，等人类运维时手动用 | **提升**：暴露为 `/metrics` 指标 + `ga stats memory` CLI |
| history 硬裁剪阈值乐观 | 遗忘是选择性特征，不是 bug | **保留**原策略；仅**暴露指标**让用户看到 trim 发生 |
| SOP 本身会膨胀 | 这是个**真问题**，但不能用 schema linter 解 | **温和**：提供 `ga inspect sop` 显示各 SOP 行数 + 最近访问时间，让人工决策 |
| 单文件巨型代码（ga.py 561 行） | **是我的锅**，作者没这么写是因为 Python 惯例 | 保留改进（Go 拆 package） |
| 前端写法高度重复 | 真问题 | 保留改进 |
| 端口硬编码冲突 | 真问题 | 保留改进 |
| subagent IPC 纯轮询 | 真问题 | 保留改进 |
| 没有可观测性 | 真问题 | 保留改进，且**升级为 v2 核心** |
| 没有 CI/release | 真问题 | 保留改进 |
| inline_eval 是安全漏洞 | **误判**：这是 LLM 调用内核的 hook | 重新设计为"高权限工具"，见 §3.5 |

**结论**：v1 列的 11 个短板里，5 个是误判，6 个是真问题。Go 版只需做 6 项纯工程改进 + 4 项针对真弱点的观测设计。

### 2.2 两个真弱点的工程对应物

作者指出的真弱点：

> **弱点一**：SOP 遵从是概率性的——LLM 读了 ≠ 遵从
> **弱点二**：LLM 缺乏主动验证意识——有工具但不主动用

这两个弱点**不能被消灭**（它们是 LLM 作为 CPU 的固有属性），但可以被：
- **测量**（知道它多频繁发生）
- **减缓**（在最关键时机提高 LLM 注意力）
- **事后追溯**（当任务失败时，能知道是哪条 RULE 被忽略了）

Go 版的使命就是给这两个弱点配备**可量化的观测 + 温和的干预**。下文 §6 详细展开。

---

## 3. 模块与目录设计（v2 修订）

相比 v1 §3，主要变化：

- 新增 `internal/compliance/` 专门承载 §6 的 4 项新机制
- `internal/memory/` 移除 v1 里的 `cleanup.go`（自动归档逻辑）和 `linter.go`（front-matter 校验）
- `internal/tools/` 下 `code_run.go` 保留 `inline_eval` 能力但改名 `privileged_eval`，见 §3.5
- 其他结构不变

```
ga/
├── cmd/ga/                    # CLI 入口（同 v1）
├── internal/
│   ├── agent/                 # Agent Loop
│   ├── llm/                   # LLM 抽象（同 v1）
│   ├── tools/                 # 9 工具（同 v1，但 code_run 重新设计）
│   ├── memory/                # 记忆层——【纯读】
│   │   ├── layers.go
│   │   ├── loader.go
│   │   └── stats.go           # 只读统计
│   │                          # 【删除】guardian.go（原自动修复）
│   │                          # 【删除】cleanup.go（原冷 SOP 归档）
│   │                          # 【删除】linter.go（原 SOP front-matter）
│   ├── browser/               # 同 v1
│   ├── frontend/              # 同 v1
│   ├── subagent/              # 同 v1
│   ├── reflect/               # 同 v1
│   ├── config/                # 同 v1
│   ├── observability/         # 同 v1
│   │
│   ├── compliance/            # 【v2 新增】遵从性观测
│   │   ├── tracer.go          # §6.1 SOP 遵从性追踪
│   │   ├── gate.go            # §6.2 任务完成闸门
│   │   ├── spectrum.go        # §6.3 工具使用频谱
│   │   └── anchor_rules.go    # §6.4 动态 RULES 注入
│   │
│   └── util/
├── pkg/                       # 同 v1
├── assets/                    # 同 v1
├── memory/                    # 与 Python 版兼容
├── docs/
└── ...
```

### 3.1 `code_run` 工具的 v2 重新设计

v1 说要删 `inline_eval` 是错的。它的真正作用是什么？

查 `plan_sop.md` 第 5 行：
```
单独使用一个 code_run({'inline_eval':True, 'script':'handler.enter_plan_mode("./plan_XXX/plan.md")'}) 进入 plan 模式
```

所以它是**LLM 调用 Go 内核函数的机制**——类似于操作系统给用户态进程的 syscall 入口。删除 = 砍掉 SOP 操作内核的唯一通道。

v2 方案：**保留能力，标记高权限，加审计**。

```go
// internal/tools/code_run.go
type CodeRunTool struct {
    // 普通 code_run（subprocess 隔离）
    subprocessRunner *SubprocessRunner
    // 特权通道（主进程内 eval，对应 inline_eval）
    privilegedRunner *PrivilegedRunner
    tracer           compliance.Tracer
}

type PrivilegedRunner struct {
    // 白名单：只允许这些函数被 inline 调用
    allowedFuncs map[string]func(args map[string]any) (any, error)
}

func NewPrivilegedRunner(handler *agent.Handler) *PrivilegedRunner {
    return &PrivilegedRunner{
        allowedFuncs: map[string]func(map[string]any) (any, error){
            "enter_plan_mode":  wrapEnterPlanMode(handler),
            "exit_plan_mode":   wrapExitPlanMode(handler),
            "append_done_hook": wrapAppendDoneHook(handler),
            "set_max_turns":    wrapSetMaxTurns(handler),
            // 其他明确暴露给 SOP 的内核能力
        },
    }
}

func (t *CodeRunTool) Invoke(ctx context.Context, req InvokeRequest) (StepOutcome, error) {
    args := parseArgs(req.Args)
    if args.InlineEval {
        // 记录审计日志
        t.tracer.RecordPrivilegedCall(ctx, args.Script)
        // 只允许白名单函数，禁止任意 Python eval
        return t.privilegedRunner.Invoke(ctx, args)
    }
    return t.subprocessRunner.Invoke(ctx, args)
}
```

**关键差异 vs v1**：
- v1 说"删除 inline_eval" → 错，会废掉 plan 模式
- v1 说"改成沙箱" → 过度，普通 code_run 是子进程已经天然隔离
- v2 方案：**普通 code_run 保持子进程隔离（已天然安全）；特权通道改为白名单函数调用**（不再是任意代码 eval）

这样 plan_sop 的调用方式变化极小：

```python
# v1 方式（任意 Python eval，不安全）
code_run({'inline_eval': True, 'script': 'handler.enter_plan_mode("./plan_XXX/plan.md")'})

# v2 方式（白名单调用，安全）
code_run({'inline_eval': True, 'script': 'enter_plan_mode("./plan_XXX/plan.md")'})
# 只是去掉了 handler. 前缀，且不再能写任意表达式
```

### 3.2 memory 包的 v2 变化：只读化

v1 里 `Memory` 接口包含 `UpdateL1(patch)` / `UpsertL3(name, content)`。这违反 L0 "神圣不可删改性"。

v2 的 `Memory` 接口**完全只读**：

```go
type Memory interface {
    ReadLayer(layer Layer) (string, error)
    ReadSOP(name string) (string, error)
    ListL3() ([]SOPInfo, error)
    Stats() MemoryStats     // 只读统计
    // 没有任何 Write/Update/Delete 方法
}
```

**那 LLM 怎么改记忆？** → 通过 **`file_patch` 工具**，和它写任何文件一样。这是故意的：

1. 保持对称性——LLM 改记忆和改普通代码走同一条路径
2. `file_patch` 本身有"唯一匹配"保护
3. 所有记忆修改自然落入 `temp/model_responses/` 日志，可追溯
4. 不给 Go 代码任何"绕过 LLM 自动改记忆"的机会

### 3.3 SOP 层的处理：透明化

v1 想让 Go 解析 SOP front-matter。v2 否决：

```go
// v2 只做这一件事
type SOPLoader struct {
    baseDir string
}

func (l *SOPLoader) Read(name string) (string, error) {
    // 纯文件读取，不解析，不校验
    path := filepath.Join(l.baseDir, name+".md")
    data, err := os.ReadFile(path)
    if err == nil {
        // 只记录访问，不解析内容
        l.recordAccess(name)
    }
    return string(data), err
}
```

LLM 看到的 SOP 是原文，不经任何处理。

---

## 4. Agent Loop 的 v2 关键细节

Agent Loop 本身相比 v1 只加 **hook 机制**，让 compliance 模块能挂上观测钩子：

```go
// internal/agent/loop.go
type Loop struct {
    llm       llm.Client
    tools     *tools.Registry
    memory    memory.Memory
    hooks     []LoopHook
}

type LoopHook interface {
    OnTurnStart(ctx context.Context, turn int, messages []llm.Message)
    OnLLMResponse(ctx context.Context, turn int, resp *llm.Response)
    OnToolCall(ctx context.Context, turn int, call llm.ToolCall)
    OnToolResult(ctx context.Context, turn int, outcome StepOutcome)
    OnTurnEnd(ctx context.Context, turn int, summary string)
    OnLoopExit(ctx context.Context, exitReason string)
}

func (l *Loop) Run(ctx context.Context, prompt string, events chan<- StreamEvent) error {
    for turn := 1; turn <= l.maxTurns; turn++ {
        for _, h := range l.hooks { h.OnTurnStart(ctx, turn, l.messages) }
        // ...
    }
}
```

这个 hook 机制是 §6 所有观测能力的基础。它：
- **完全不拦截主流程**（hook 都是 void 返回，不能改参数/不能打断）
- **只读上下文**（只传 messages/response 的副本）
- **异步执行**（hook 逻辑用 goroutine，不阻塞 loop）

这是 Go 版相比 Python 版的关键优势——Python 版没有这种结构化 hook 机制，想加观测只能 monkey-patch（`plugins/langfuse_tracing.py` 就是这么干的，丑陋且脆弱）。

---

## 5. 被保留的 v1 改进（简述）

这 4 项保留改进已在 v1 方案详细讨论，这里只记要点和与 v2 的关系。

### 5.1 前端接口统一（v1 §5.5）✅ 保留

`BaseBot` + 7 平台适配器，每个 ≤ 150 行。v2 额外要求：每个前端都要实现 `HookSource` 接口，把用户命令（`/stop` `/new`）也上报给 compliance tracer（用于分析"用户什么时候介入最多"，反推 SOP 质量）。

### 5.2 服务注册中心（v1 §5.6）✅ 保留

动态端口分配，`ga status` 查询。v2 额外：注册中心数据导出到 `/metrics`。

### 5.3 fsnotify IPC（v1 §5.7）✅ 保留

事件驱动替代 2 秒轮询。对外文件协议不变。

### 5.4 原生可观测性（v1 §5.8）✅ 保留 + 升级

v1 只想做"LLM 调用延迟"等 metrics，v2 升级为承载 §6 全部观测数据的载体。

---

## 6. 【v2 核心】两个真弱点的观测与引导设计

这是 v2 最重要的章节。所有设计遵循 §1.3 三原则：
- 不强制 LLM 行为
- 代码层只观察、不修正
- 所有干预都有 "LLM 说服代码放行" 的 escape hatch

### 6.1 SOP 遵从性追踪器（Compliance Tracer）

**目标问题**（弱点一）：LLM 读过 SOP 但没按它做，事后无法定位。

**核心思路**：记录每轮 LLM 的**工具调用序列**，与 SOP 里声明的"关键步骤序列"做**软匹配**，输出遵从度分数。**不拦截**，仅记录。

**数据流**：

```
SOP 文件
  ↓ (运行期一次性解析，只看"步骤序列"这种明显模式)
SOP Fingerprint (step -> required_tools/forbidden_tools)
  ↓
Loop Hook.OnToolCall
  ↓ (匹配当前 context 相关的 SOP fingerprint)
Tracer 累积每轮的工具调用
  ↓
TurnEnd: 计算遵从度
  ↓
写入 trace 日志 + 暴露指标
```

**实现骨架**：

```go
// internal/compliance/tracer.go
type Tracer struct {
    memory      memory.Memory
    fingerprints map[string]*SOPFingerprint
    traces      *TraceStore
}

type SOPFingerprint struct {
    Name      string
    Steps     []StepPattern
    // 从 markdown 里用启发式规则抽：
    //   - 带序号的段落（1. 2. 3.）
    //   - "必须调用 X"、"禁止调用 Y" 这类指令句
    //   - ⛔ / ⚠️ / ✅ 标记的条目
}

type StepPattern struct {
    Index         int
    Description   string
    RequiredTool  string  // 比如 "code_run"、"file_read"
    ForbiddenTool string  // 比如 "禁止 file_write"
    IsMandatory   bool    // 是否是"硬性规则"
}

// 只在 LLM 主动 file_read(某个 SOP) 时，激活该 SOP 的追踪
func (t *Tracer) OnToolCall(ctx context.Context, turn int, call llm.ToolCall) {
    if call.Name == "file_read" {
        path := call.Args["path"].(string)
        if strings.Contains(path, "_sop.md") {
            sopName := extractSOPName(path)
            if fp, ok := t.fingerprints[sopName]; ok {
                t.traces.ActivateSOP(ctx, sopName, fp, turn)
            }
        }
    }
    // 记录每次工具调用，给活跃的 SOP 打分
    t.traces.RecordToolCall(ctx, turn, call)
}

func (t *Tracer) OnLoopExit(ctx context.Context, exitReason string) {
    // 输出遵从度报告
    for sop, trace := range t.traces.ActiveSOPs(ctx) {
        compliance := t.scoreCompliance(trace)
        // 写入 temp/compliance/<session_id>/<sop>.json
        // 同时暴露 Prometheus 指标
        metrics.SOPCompliance.WithLabelValues(sop).Observe(compliance.Score)
    }
}
```

**关键设计点**：

1. **指纹提取是启发式的，不是严格解析**：作者反对给 SOP 加 schema。Tracer 用 `regexp` 抓"带序号的句子"、"必须/禁止"关键词，抓不到就算了，不报错。
2. **激活条件是 LLM 主动读 SOP**：只有 LLM 自己调 `file_read("xxx_sop.md")`，Tracer 才开始追踪这个 SOP。没读的 SOP 完全忽略（否则噪音太多）。
3. **遵从度分数不影响运行**：只写日志 + 指标。用户看 Grafana 面板能发现"plan_sop 的遵从度从 90% 跌到 60%"，但 Agent 本身不会被干预。
4. **累积分析而非实时干预**：一周的 trace 数据才能发现"LLM 读了 verify_sop 但 5 次里有 3 次跳过了[VERIFY]步骤"这种模式。

**输出示例**：

```json
// temp/compliance/sess-abc123/plan_sop.json
{
  "sop": "plan_sop",
  "activated_at_turn": 3,
  "steps_detected": [
    {"step": 1, "desc": "创建目录", "required_tool": "code_run", "hit": true, "turn": 3},
    {"step": 2, "desc": "启动探索subagent", "required_tool": "code_run", "hit": true, "turn": 5},
    {"step": 8, "desc": "[VERIFY] 启动验证subagent", "required_tool": "code_run", "hit": false, "turn": null}
  ],
  "compliance_score": 0.67,
  "exit_reason": "CURRENT_TASK_DONE",
  "issue": "declared_done_without_verify"
}
```

这个数据可以：
- 让用户知道"Agent 在说任务完成前没做 VERIFY 验证"
- 给 SOP 作者迭代提供依据（"是不是 VERIFY 步骤写得太靠后 LLM 忘了？"）
- 长期分析不同模型的遵从度差异（Claude 可能比 GPT 更严格）

### 6.2 任务完成闸门（Done Gate）

**目标问题**（弱点二）：LLM 声称"任务完成"但实际未验证。

**现状**：Python 版只有 plan 模式有"声称完成但没走 VERIFY 就拦截"（`ga.py:456-459`）。其他模式没有。

**v2 扩展**：给所有模式加"完成闸门"，但**只在明显可验证的情况下**激活。

```go
// internal/compliance/gate.go
type DoneGate struct {
    detectors []DoneDetector
}

type DoneDetector interface {
    // 检查 LLM 本轮是否在"声称完成"
    IsDone(resp *llm.Response) bool
    // 检查本轮是否做了验证
    HasVerification(turnHistory []TurnRecord) bool
    // 生成诱导回退的 prompt
    BounceBackPrompt(resp *llm.Response) string
}

// 检测器 1：任务目标是"写文件" → 是否 file_read 回读过？
type FileWriteGoalDetector struct{}

func (d *FileWriteGoalDetector) IsDone(resp *llm.Response) bool {
    return hasPhrases(resp.Content, []string{
        "文件已创建", "写入完成", "保存到", "已生成",
    })
}

func (d *FileWriteGoalDetector) HasVerification(history []TurnRecord) bool {
    // 查最近 3 轮：是否有 file_read 对同一路径？
    writePaths := collectWritePaths(history)
    readPaths := collectReadPaths(history[len(history)-3:])
    return len(intersect(writePaths, readPaths)) > 0
}

// 检测器 2：任务目标是"跑代码" → 是否看过 exit_code？
// 检测器 3：任务目标是"修复 bug" → 是否复现了原 bug？
// 检测器 4：plan 模式声称完成 → 是否 [VERIFY] 步骤标 [✓]？（继承 Python 版）
```

**关键克制**：

- 只有"明显可检测"的类型才做闸门。无法自动判断的（如"帮我分析一下这个文档"）不管。
- 闸门触发时**不硬拦截**，而是在 `next_prompt` 追加一条**提示**：
  ```
  [System Nudge] 你声称完成了 X，但观察到 Y 验证步骤尚未执行。
  若确认已完成，请显式说明验证方式；若确需补做，请继续调用工具。
  ```
- LLM 有两种回应：
  - 补做验证 → 闸门下一轮自动判为通过
  - 回应 "已通过其他方式验证（例如 ...）" → Tracer 记录一下，放行

这是"温和引导"的典型——**不假设 LLM 错，只提醒它注意**。作者自分析里指出弱点是"意识问题，不是能力问题"，这个 Nudge 就是注入意识的机制。

**对比 v1**：v1 §5.9 是"删除 inline_eval 防注入"，搞错了方向。真正值得代码层介入的是"声称完成时查证"，这才是 LLM 最常犯错的地方。

### 6.3 工具使用频谱（Tool Spectrum）

**目标问题**（弱点二）：LLM 倾向于"断言先于证据"——少调工具，多写文字。

**度量方式**：每个任务session，统计：

```
tool_call_ratio  = 工具调用数 / 总轮数
explore_ratio    = (file_read + web_scan + code_run 探测类) / 总工具数
action_ratio     = (file_write + file_patch + web_execute_js 改动类) / 总工具数
think_density    = 平均每轮 <thinking> 字符数
verify_ratio     = 改动前的 file_read 次数 / 改动次数
```

这些指标本身没"对错"，但偏离人类专家基线太远就是信号：

```
[Healthy baseline, from manual review of 20 successful sessions]
  tool_call_ratio:  0.8 ± 0.3
  explore_ratio:    0.5 ± 0.2
  verify_ratio:     0.7 ± 0.2
  think_density:    200 ± 100 chars/turn

[Session sess-abc123]
  tool_call_ratio:  0.3   ← 异常低！LLM 多数轮次都在"说"不在"做"
  verify_ratio:     0.1   ← 异常低！大量 write 前没 read
  → 标记为 "low_evidence_session"，加入 weekly report
```

**实现轻量级**：

```go
// internal/compliance/spectrum.go
type Spectrum struct {
    sessions map[string]*SessionMetrics
}

func (s *Spectrum) OnToolCall(ctx, turn, call) {
    m := s.sessions[sessionID(ctx)]
    m.TotalCalls++
    switch call.Name {
    case "file_read", "web_scan":   m.ExploreCalls++
    case "file_write", "file_patch": m.ActionCalls++
        m.LastActionPath = call.Args["path"]
        if m.recentReadPath(m.LastActionPath, lookback=5) {
            m.VerifiedActions++
        }
    }
}

func (s *Spectrum) Report(sessionID string) *SpectrumReport {
    m := s.sessions[sessionID]
    return &SpectrumReport{
        ToolCallRatio: float64(m.TotalCalls) / float64(m.TotalTurns),
        VerifyRatio:   float64(m.VerifiedActions) / float64(m.ActionCalls),
        Anomalies:     m.compareToBaseline(s.baseline),
    }
}
```

**使用场景**：

1. **Grafana Dashboard**：一眼看到过去一天所有 session 的频谱分布，离群点自动标红
2. **`ga explain <session>` CLI**：对具体 session 打印频谱报告，用户能看到"Agent 这次跑偏了在哪"
3. **SOP 质量信号**：如果某个 SOP 相关任务的 `verify_ratio` 普遍低，可能是 SOP 里"验证"要求写得不够醒目

### 6.4 动态 RULES 注入（Context-aware Anchor）

**目标问题**（弱点一）：L1 里的 `[RULES]` 只在系统提示（常驻）里出现一次，长任务会被稀释。

**现状**（Python `ga.py:537`）：只有第 10 轮整数倍才会重注入 `get_global_memory()`（含 RULES）。简单粗暴。

**v2 改进**：按**当前工具调用场景**动态挑选最相关的 RULE 插入下一轮 prompt。

```go
// internal/compliance/anchor_rules.go
type AnchorRules struct {
    rules []Rule
}

type Rule struct {
    Text      string
    Triggers  []TriggerMatch   // 哪些情况下注入
}

type TriggerMatch struct {
    ToolName    string   // 匹配工具名（如 "web_execute_js"）
    TurnMod     int      // 每 N 轮（如 3）
    AfterFails  int      // 连续失败 N 次后
    ContextKey  string   // working_memory 含特定 key
}

var DefaultRules = []Rule{
    {
        Text: "[RULE] web JS 输入用原生 setter+事件链，点击前检 disabled",
        Triggers: []TriggerMatch{{ToolName: "web_execute_js", TurnMod: 3}},
    },
    {
        Text: "[RULE] 改前必读，file_patch 失败 3 次请求用户干预",
        Triggers: []TriggerMatch{{ToolName: "file_patch", AfterFails: 2}},
    },
    {
        Text: "[RULE] 禁无条件 kill python，会杀自己，必须精确 PID",
        Triggers: []TriggerMatch{{ContextKey: "managing_python_process"}},
    },
}

// 在构造 next_prompt 时调用
func (r *AnchorRules) ApplicableRules(ctx AnchorContext) []string {
    applicable := []string{}
    for _, rule := range r.rules {
        for _, t := range rule.Triggers {
            if t.matches(ctx) {
                applicable = append(applicable, rule.Text)
                break
            }
        }
    }
    return applicable
}
```

**效果**：比 Python 版"每 10 轮整数倍注入整个 L1"更精准：
- LLM 刚调了 `web_execute_js` → 下一轮看到的 prompt 里**显眼位置**有"原生 setter + 事件链" RULE
- `file_patch` 连续 2 次失败 → 下一轮被提醒"改前必读 + 3 次后问用户"
- Python 管理任务 → 被提醒"禁无条件 kill python"

**成本**：每条 RULE ~30 tokens，一次最多 2-3 条，总 overhead < 100 tokens/轮。相比精准度提升可忽略。

**实现关键**：规则数据来源还是 `global_mem_insight.txt` 的 `[RULES]` 段（保持"代码不写业务规则"原则）。Go 只是提供"按情境挑选"的机制，规则本身是记忆层数据。

---

## 7. 修订后的 12 周路线

相比 v1，调整如下：

| 阶段 | 原 v1 时间 | v2 调整 | 说明 |
|---|---|---|---|
| 0 POC | 1 周 | 1 周（不变） | Agent Loop + 1 工具 |
| 1 核心 | 3 周 | 3 周（不变） | 9 工具 + 3 协议 + 记忆读 |
| 2 浏览器 | 2 周 | 2 周（不变） | |
| 3 Bot | 2 周 | 2 周（不变） | |
| **4 改进** | **2 周** | **变 v2 §6 观测体系** | 4 项 compliance 机制 |
| 5 发布 | 1 周 | 1 周（不变） | |
| 6 兼容 | 1 周 | 1 周（不变） | |

总时长 12 周不变，只是第 4 阶段内容从"工程短板修复"转为"compliance 观测实现"。

**第 4 阶段的新验收条件**：

- [ ] `temp/compliance/` 下可看到每个 session 的遵从度 JSON
- [ ] Prometheus `/metrics` 有 `ga_sop_compliance_score` 等指标
- [ ] `ga explain <session_id>` 可输出频谱报告
- [ ] Done Gate 在 `file_write_without_read` 场景能注入 Nudge，且 LLM 补做 `file_read` 后通过
- [ ] 动态 RULES 在 `web_execute_js` 连续调用时可观察到 `[RULE]` 出现在下一轮 prompt

---

## 8. 【v2 核心】为什么观测 > 修复

这是 v2 最重要的哲学变化，单独成节。

### 8.1 观测层的杠杆效应

作者自分析附录讲得很深刻：
> 我在写报告时明确读过 subagent.md（里面写着"测试模式 - 行为验证"），读过 start_long_term_update 的代码（我自己就是调用者），甚至亲手用 subagent 做了 recall 测试——但在总结弱点时，依然把这些已知信息"遗忘"了，写出了与事实相反的结论。
> 这恰恰是弱点#1 的完美证明。

这说明：**即便 LLM 拥有所有需要的信息、也有工具、也有示范，它仍会概率性出错**。

想用代码"修好"这个问题是不可能的（把 LLM 换成确定性程序就不是 GenericAgent 了）。但如果有**完整的观测数据**，人类运维者可以：
- 发现这次出错的模式
- 给 SOP 迭代补一条更醒目的提醒
- 用 RULES 动态注入在下次出现类似情况时提权

**观测 → 迭代 SOP → 行为改善** 是一个**收敛**的循环。Python 版缺的就是第一步的数据。

### 8.2 为什么不能"自动迭代 SOP"

有人会问：既然有观测数据，让 LLM 自己根据数据改 SOP 不行吗？

**不行**，三个理由：

1. **L0 核心公理 #2 "神圣不可删改性"**：记忆修改极度敏感，哪怕是 LLM 自己改。
2. **闭环放大偏差**：LLM 根据观测数据改 SOP → 下次受改后的 SOP 影响 → 生成更偏的观测 → 再改 SOP。没有外部校准，会漂移。
3. **遗忘既是弱点也是优势**：如果让代码强制"SOP 被严格遵守"，就等于给 LLM 戴脚镣，剥夺它在新情境下灵活应变的能力。

**人类保持 loop-in 是 GenericAgent 架构的特性，不是 bug**。v2 观测层的设计完全尊重这一点：自动采集 + 定期报告 + 人工决策。

### 8.3 Go 版相对 Python 版的**真正**优势在哪

回到 §1.1 的表格。v1 错答"更快更小并发强"。v2 的正确答案：

| 优势 | 说明 |
|---|---|
| **结构化 hook** | Python 版靠 monkey-patch，Go 版的 LoopHook 接口让观测数据采集零侵入 |
| **类型安全的事件流** | 每个 StreamEvent、ToolCall、StepOutcome 都是强类型 struct，不用担心 KeyError |
| **可观测性原生** | Prometheus/OTel 是 Go 生态一等公民，Python 版接 Langfuse 都是外挂 |
| **并发观测 goroutine** | §6 所有 compliance 逻辑都是异步 hook，不阻塞主循环 |
| **编译期捕获错误** | 新增工具 / hook / 前端时，接口不匹配编译就报，Python 要跑到运行时 |
| **单二进制分发** | 运维只需一个文件，适合装到各种边缘机器 |

**缺的优势是这些**（v1 列的都不算数）：
- ❌ "比 Python 快" — 瓶颈在 LLM 响应，快几毫秒无感
- ❌ "内存少" — Python ~80MB vs Go ~30MB，对桌面用户无意义
- ❌ "并发强" — 实际用户就一个，并发到哪去

---

## 9. 风险与应对的 v2 修订

相比 v1 §8，主要更新：

| 原风险 | v2 认定 | 应对 |
|---|---|---|
| inline_eval 提示注入 | 误判 | 改为 §3.1 白名单特权调用 |
| 个人微信协议变动 | 正确 | 侧车方案不变 |
| Chrome 扩展 MV3 变动 | 正确 | 版本协商不变 |
| Python 记忆文件被 Go 误改 | **升级为核心风险** | §3.2 Memory 接口只读化 |
| 迁移时数据丢失 | 正确 | 所有迁移只读 |

**v2 新增风险**：

| 新风险 | 应对 |
|---|---|
| **Compliance Tracer 自身成瓶颈** | 所有 hook 异步执行，失败就丢（采集不影响主业务） |
| **Nudge 过多让 LLM 困惑** | Done Gate 只在强信号下触发，单任务最多 2 次 Nudge |
| **动态 RULES 选择错误** | 保留 fallback：10 轮整数倍仍注入完整 L1（Python 版行为） |

---

## 10. 验收标准修订

v1 §10 的性能指标大部分撤销。v2 新标准：

### 10.1 功能等价性（不变）

所有 Python 版场景行为 1:1。

### 10.2 可靠性指标（新）

| 指标 | 目标 |
|---|---|
| 连续运行 7×24 无崩溃 | MTBF ≥ 30 天 |
| LLM 故障优雅降级 | 单个 session 失败，mixin 自动切换，不传染其他 session |
| 记忆文件并发安全 | 10 个 subagent 并发写 `temp/` 无数据损坏 |
| 异常恢复 | kill -9 后重启，`temp/model_responses/*.txt` 能完整恢复会话 |

### 10.3 可观测性指标（新，v2 核心）

| 指标 | 目标 |
|---|---|
| SOP 遵从度采集覆盖率 | 所有 session 都有 compliance trace |
| Done Gate 召回率 | 手工标注 50 个"未验证就完成"案例，Gate 捕获 ≥ 70% |
| Spectrum 异常识别率 | 手工标注 30 个"低证据" session，Spectrum 命中 ≥ 80% |
| 动态 RULES 命中率 | 手工标注的 "RULE 应该注入但没注入" 漏报 ≤ 10% |

### 10.4 代码质量（不变）

- 单元测试 ≥ 70%
- `golangci-lint` 零警告

**撤销**：v1 的启动时间 / 内存占用 / 并发数等性能指标——不是核心价值。

---

## 11. v1 与 v2 的差异速查表

| 维度 | v1 | v2 |
|---|---|---|
| 定位 | Python 翻译成 Go | LLM-CPU 的可靠 runtime |
| 核心价值 | 快/小/并发 | 稳/透明/可观察 |
| 改进项数 | 9 项"短板修复" | 4 项保留工程项 + 4 项 compliance |
| 对 SOP 的处理 | 加 schema 和 linter | 透明化，不解析 |
| 对记忆的处理 | 加 Guardian + AutoFix | 只读，修改走 file_patch |
| 对 inline_eval | 删除 | 白名单特权调用 |
| 对 history 压缩 | 3 档激进 | 保持原策略 |
| 对"强制 LLM 守规" | 做 linter/schema | 拒绝，改为观测引导 |
| 性能目标 | 启动 ≤500ms 等 | 撤销，改可靠性和可观测性指标 |
| Go 的真正优势 | 更快 | 结构化 hook + 原生可观测 |

---

## 12. 一页总结（v2 版）

**做什么**：用 Go 重写 GenericAgent 核心，让它成为 "LLM-CPU 的可靠 runtime"。

**不做什么**：
- 不让 Go 代码解析 SOP 内容
- 不让 Go 代码自动改记忆
- 不让 Go 代码"强制 LLM 守规"

**真正的价值主张**：
1. **结构化观测**：compliance tracer / done gate / spectrum / dynamic rules 四件套，把 LLM 的"概率性行为"变成可量化的数据
2. **稳定 runtime**：7×24 不崩、优雅降级、单二进制
3. **透明分层**：代码层 / SOP 层 / 记忆层各司其职，Go 只管代码层

**核心领悟**（来自作者自分析）：
> LLM 读过 SOP ≠ LLM 会遵从 SOP。信息在上下文里 ≠ 信息会被正确使用。

Go 版不是要消除这个现象（不可能），而是要**让这个现象可见、可测、可迭代**。

**3 个不变的战略决策**（v1 延续）：
- Only Native LLM 协议
- 个人微信 Python 侧车
- 记忆文件化

**3 个 v2 新决策**：
- 代码层对 SOP 完全透明
- 所有干预机制保留"LLM 说服代码"的通道
- 观测 > 修复（记录问题比修复问题更有价值）

**12 周里程碑不变**，第 4 阶段内容从"短板修复"改为"compliance 观测"。

---

## 13. 附录：v1 到 v2 的思想变化

### 13.1 最大的认知升级

**v1 心态**：我是一个"老练 Go 工程师"，来给"不够专业的 Python 代码"做结构化重写。

**v2 心态**：我是一个"LLM-native 架构的学生"，Go 重写是为了给这个架构配更合适的 runtime，而不是修改架构本身。

这个转变来自作者自分析的两段话：

> 所有"智能"——规划、纠错、技能选择、并行决策——都编码在 SOP 里，由 LLM 解释执行。SOP 本质上是"运行在 LLM 上的程序"，用自然语言写成，LLM 是它的 runtime。
>
> 这意味着：新能力 = 新 SOP 文件，零代码改动；LLM 升级 = 所有 SOP 自动获得更好的 runtime；维护成本极低，bug 面极小。

v1 想"修"的很多东西（SOP 结构、记忆 schema、工具数量），其实都是这个架构故意保持开放的地方。修了 = 砍了 GA 的立身之本。

### 13.2 v1 错在哪的清单

| v1 错误 | 原因 |
|---|---|
| 想给 SOP 加 front-matter | 当成配置文件，没意识到它是"LLM 程序代码" |
| 想自动归档冷 SOP | 违反 L0 "神圣不可删改性" |
| 想删除 inline_eval | 把内核 syscall 当作注入漏洞 |
| 以性能指标对标 | 错把语言对决当作核心价值 |
| 把"9 工具"当短板 | 没看到"决策空间小=选择准确率高" |

### 13.3 v2 为什么对

**v2 的四项 compliance 机制有一个共同特点**：它们都是**给人类运维者用的工具**，不是给 LLM 自己用的工具。

- **SOP Tracer**：帮人类发现哪些 SOP 经常被 LLM 忽略
- **Done Gate**：帮 LLM 获得"第二次机会"，没强制
- **Spectrum**：帮人类识别需要干预的 session
- **Dynamic RULES**：帮 LLM 在关键时刻提高注意力

这种"LLM + Human + Observability" 的三元架构，是 GA 作者一直强调的"人机协作抽查比全自动监控更高效"的工程化落地。

---

**文档版本历史**：
- v1.0 (2026-05-02)：首版，工程师视角，9 项短板修复
- v2.0 (2026-05-02)：吸收作者自分析后的深度修订，定位从"翻译"转为"LLM-CPU runtime"，新增 4 项 compliance 观测机制，撤销 5 项与 LLM-native 理念冲突的"改进"
