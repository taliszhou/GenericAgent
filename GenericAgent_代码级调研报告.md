# GenericAgent 代码级深度调研报告

> **仓库**：`/Users/taliszhou/code/src/github.com/GenericAgent`（git: `main`，对应 `github.com/lsdefine/GenericAgent`）
> **调研时间**：2026-05-01
> **定位**：极简、自我进化的自主 LLM Agent 框架；核心 ~3K 行，通过 9 个原子工具 + ~100 行 Agent Loop 赋予任意 LLM 对本地计算机（浏览器/终端/文件系统/键鼠/视觉/ADB）的系统级控制能力。
> **License**：MIT

---

## 0. 一句话概述

GenericAgent 把 "Agent" 做成了一个**极瘦的调度内核**（`agent_loop.py` 125 行 + `ga.py` 561 行 + `llmcore.py` 983 行），其余所有"能力"都外置为**分层文本记忆（L0–L4）**与 **Agent 在运行时自己长出来的 Skill**。它没有预置 RAG、没有 MCP、没有插件市场，却能跨 Claude / GPT / Kimi / MiniMax / GLM 混合调度，能接管用户真实浏览器（保留登录态），能跑 ADB、键鼠、OCR、Vision——因为它把**可扩展性做在了记忆层**，而不是代码层。

---

## 1. 代码量与顶层结构

`wc -l` 实测：

| 模块 | 文件 | 行数 |
|---|---|---|
| **Agent Loop** | `agent_loop.py` | 125 |
| **工具实现** | `ga.py` | 561 |
| **LLM 抽象层** | `llmcore.py` | 983 |
| **入口/调度** | `agentmain.py` | 268 |
| **浏览器驱动** | `TMWebDriver.py` + `simphtml.py` | 286 + 870 |
| **反射/定时** | `reflect/*.py` | 136 |
| **记忆模块工具** | `memory/*.py` | 11 个文件 ≈ 712 行 |
| **前端** | `frontends/*.py` | 10 个适配器 ≈ 6035 行 |
| **合计（Python）** | — | **~11.6K 行**（含所有前端适配器） |

若只算"核心 runtime"（`agent_loop` + `ga` + `llmcore` + `agentmain` + `TMWebDriver` + `simphtml`）：**约 3.1K 行**，与 README 宣称的 "~3K lines" 吻合。

### 1.1 顶层目录

```
GenericAgent/
├── agent_loop.py          # 通用 Agent 运行循环（~100 行核心）
├── ga.py                  # 9 个原子工具 + GenericAgentHandler
├── llmcore.py             # 多协议 LLM Session 抽象 + 文本协议/Native 工具客户端
├── agentmain.py           # 主进程：任务队列、LLM 装配、task/reflect 模式
├── simphtml.py            # 页面 DOM 简化器（给 LLM 看的"瘦身 HTML"）
├── TMWebDriver.py         # 通过 Chrome 扩展反向接管真实浏览器（WS+HTTP long-poll）
├── launch.pyw             # pywebview + streamlit 桌面窗口启动器
├── hub.pyw                # tkinter 多服务管理器
├── ga.py / simphtml.py 等 # 原子能力
├── mykey_template.py      # 425 行注释极详细的密钥/模型配置模板
├── pyproject.toml         # 极简依赖：requests/bs4/bottle/simple-websocket-server
├── assets/
│   ├── tools_schema.json  # 9 个原子工具的 JSON Schema
│   ├── sys_prompt.txt     # 系统提示词（极短）
│   ├── insight_fixed_structure.txt  # L1 索引的固定骨架
│   ├── global_mem_insight_template.txt  # L1 初始内容
│   ├── code_run_header.py # 注入所有 code_run 子进程的通用 header
│   └── tmwd_cdp_bridge/   # MV3 Chrome 扩展（CDP Bridge）
├── memory/                # 分层记忆 L0 元规则 / L2 事实 / L3 SOP+工具 / L4 会话归档
│   ├── memory_management_sop.md  # L0 元 SOP（写记忆的宪法）
│   ├── global_mem_insight.txt    # L1 索引（≤30 行）
│   ├── global_mem.txt            # L2 全局事实库
│   ├── *_sop.md                  # L3 任务级 SOP（plan/verify/subagent/tmwebdriver/…）
│   ├── ljqCtrl.py/ocr_utils.py/adb_ui.py/vision_api.template.py  # L3 工具脚本
│   └── L4_raw_sessions/compress_session.py  # L4 会话压缩器
├── reflect/               # 外部触发：autonomous.py（空闲自动化）、scheduler.py（cron）
├── frontends/             # Streamlit/Qt/TG/QQ/飞书/企微/钉钉/微信/桌面宠物
└── plugins/langfuse_tracing.py  # 可选 Langfuse 观测（monkey-patch 挂钩）
```

---

## 2. Agent Loop —— 100 行闭环

**文件**：`agent_loop.py`，关键函数 `agent_runner_loop`（42–99 行）。

### 2.1 循环骨架

```python
def agent_runner_loop(client, system_prompt, user_input, handler, tools_schema, max_turns=40, ...):
    messages = [{"role": "system", ...}, {"role": "user", ...}]
    while turn < handler.max_turns:
        turn += 1
        if turn % 10 == 0: client.last_tools = ''      # 每 10 轮重注入一次 tool 描述
        response = yield from client.chat(messages, tools_schema)
        tool_calls = [...]                              # 解析模型工具调用
        for tc in tool_calls:
            outcome = yield from handler.dispatch(tc.name, tc.args, response)
            if outcome.should_exit: break
            if not outcome.next_prompt: break           # CURRENT_TASK_DONE
            tool_results.append(...)
        next_prompt = handler.turn_end_callback(...)    # 汇总进历史
        messages = [{"role":"user", "content": next_prompt, "tool_results": tool_results}]
```

**关键设计点**：

1. **单用户消息 + 历史外置**：每轮只发一条 user 消息给 `client.chat`，完整历史保存在 `client.backend.history` 中，由 `llmcore.BaseSession` 自己维护。这让外层 loop 无状态，任意时刻可热切换 LLM 后端。
2. **生成器协程**：`try_call_generator` + `yield from` 贯穿全链路。工具执行中产生的 live output 能直接流式回显给前端，又不打断返回值（`StopIteration.value`）。
3. **`StepOutcome` 协议**（`agent_loop.py:4-8`）：每个工具返回 `(data, next_prompt, should_exit)`。`next_prompt=None` 表示"任务完成可退出"；`should_exit=True` 表示立即中断（例如 `ask_user`）。
4. **每 10 轮重注入工具 Schema**：省 token 的同时防止模型"遗忘"工具存在（`agent_loop.py:53`）。
5. **`no_tool` 哨兵**：模型没调用任何工具时，合成一个虚拟 `no_tool` 调用，由 `GenericAgentHandler.do_no_tool`（`ga.py:442-490`）判定：
   - 空响应 → 重生成
   - `max_tokens` 截断 → 提示拆分
   - Plan 模式下自称完成但未跑 `[VERIFY]` → 拦截
   - 只有一个大代码块没自然语言 → 要求补充或显式调工具
   - 其余 → 视为最终回复，退出循环

### 2.2 `BaseHandler` 钩子体系（`agent_loop.py:14-29`）

- `tool_before_callback` / `tool_after_callback`：每次工具调用前后触发（可生成器）。`plugins/langfuse_tracing.py` 就通过 monkey-patch 这里上报 span。
- `turn_end_callback`：每轮结束汇总 summary 入 `history_info`，并注入 danger 提示（连续 7 轮无进展警告、65 轮强制 ask_user 等，见 `ga.py:521-548`）。
- `dispatch`：反射找 `do_<tool_name>` 方法，缺失返回 "未知工具" 并清空 `last_tools`（促使下轮重注入 Schema）。

---

## 3. 九个原子工具（`ga.py` 的 `GenericAgentHandler`）

`assets/tools_schema.json` 定义了 9 个工具；每个工具在 `GenericAgentHandler` 中有 `do_<name>` 实现。

| 工具 | 实现位置 | 机制摘要 |
|---|---|---|
| `code_run` | `ga.py:280-303` | 写到 `tempfile.NamedTemporaryFile(.ai.py)`，前置 `assets/code_run_header.py`（统一 `subprocess.run` 的 encoding/unbuffered、ImportError hint），用 `python -X utf8 -u` 子进程跑；stdout 实时流式转发；有 `stop_signal` 列表（外部 append 1 即可强杀）；支持 `inline_eval=True` 在主进程内 eval（给 SOP 内部触发 plan 模式用）。 |
| `file_read` | `ga.py:210-248` | 行级读取，支持 `start`/`keyword`/`count`，keyword 命中后回填 1/3 `count` 的前置上下文；超长行截断标记 `[TRUNCATED]`；找不到文件时用 `difflib.SequenceMatcher` 在最近读过的目录里 fuzzy 推荐"你是不是想读 X"。 |
| `file_write` | `ga.py:368-399` | 内容必须放在 reply 的 `<file_content>` 标签或代码块中（而非 args 里），由 `extract_robust_content` 提取；支持 `overwrite/append/prepend`；内容里可用 `{{file:path:start:end}}` 引用其他文件片段，由 `expand_file_refs` 展开。 |
| `file_patch` | `ga.py:354-366` + `ga.py:188-201` | 在文件中寻找**唯一**的 `old_content` 块并替换；匹配 0 次或 >1 次都直接报错（强制模型多给上下文），杜绝误改。 |
| `web_scan` | `ga.py:312-324` + `ga.py:113-142` | 通过 `TMWebDriver` 获取 tabs，调 `simphtml.get_html` 返回"LLM 友好 HTML"（最大 35K 字符，text_only 时 10K）。 |
| `web_execute_js` | `ga.py:326-352` + `ga.py:163-172` | 真实浏览器里跑 JS；JSON 返回值太大时可用 `save_to_file` 存盘只回传头尾摘要；识别 tmwd_cdp_bridge 的 JSON cmd（`{"cmd":"cdp",...}`）走 CDP 桥。 |
| `ask_user` | `ga.py:305-310` | 设置 `should_exit=True`，循环退出把 question/candidates 透给前端。 |
| `update_working_checkpoint` | `ga.py:430-440` | 写 `self.working['key_info']` / `related_sop`。下一轮 `_get_anchor_prompt` 自动把它注入进 user 消息（`<key_info>...</key_info>`）。纯工作记忆，不写盘。 |
| `start_long_term_update` | `ga.py:492-507` | 不做真正的写，只**喂**一段 prompt + 自动 `file_read` 当前 `memory_management_sop.md`，把"是否该沉淀到 L2/L3"的决策交还模型自己做。 |

> 此外 `no_tool` 是哨兵，不在 schema 中。

### 3.1 `_get_anchor_prompt`：工作记忆的注入点（`ga.py:509-519`）

每个工具返回的 `next_prompt` 都会拼上一段 Anchor：

```
### [WORKING MEMORY]
<history>
[最近 40 条 USER/Agent summary]
</history>
Current turn: N
<key_info>...</key_info>      # 如果设过 checkpoint
有不清晰的地方请再次读取 xxx_sop.md
```

这就是"省 token 但不丢记忆"的核心：模型的真实长上下文里只有**单行 summary 历史**，真要回忆细节 → 去读 memory 目录。

### 3.2 外部干预文件（`agentmain.py` + `ga.py:543-546`）

在 `temp/{task_dir}/` 下投放：
- `_stop` → 任务立即终止
- `_keyinfo` → 内容追加到 `working['key_info']`（前缀 `[MASTER]`）
- `_intervene` → 内容追加到下一轮 prompt
- `reply.txt` → subagent 模式下回送下一轮输入
- `output.txt` / `output1.txt` ... → subagent 流式输出，父 agent 监察

这套**文件级 IPC** 是 "subagent" 能力的基础（`memory/subagent.md`）：不搞 MQ、不开额外端口，就用文件 + poll。

---

## 4. `llmcore.py`：多协议 LLM 抽象（983 行的心脏）

### 4.1 Session 继承树

```
BaseSession  (cfg 解析、history、trim、thinking/reasoning 配置)
├── ClaudeSession          (Anthropic 协议，系统内缓存 + ephemeral cache_control)
├── LLMSession             (OpenAI Chat Completions / Responses 双模式)
├── NativeClaudeSession    (模拟 Claude Code CLI，user-agent/metadata/beta flags)
│   └── NativeOAISession   (同样"假装自己是 CC"，但请求走 OAI 协议)
└── (通过组合) MixinSession  (多 session fallback + spring-back 回归主节点)
```

然后用两种 **Client** 包一层，供 `agent_loop` 调用：

| Client | 用途 | 关键动作 |
|---|---|---|
| `ToolClient` | **文本协议工具** | 把 9 个工具的 JSON Schema 塞进系统提示，定义 `<tool_use>{...}</tool_use>` 文本协议；自带 `_parse_mixed_response`，能宽容解析 `<tool_use>` 标签、`<tool_call>` 标签、裸 JSON `{"name":...,"arguments":...}` 等多种模型"方言"。兼容性>>正确率，适合非 overfit 模型。 |
| `NativeToolClient` | **API 原生 function calling** | 工具走 API tools 字段；`backend.tools = tools`；把多条 messages 合并成一条 user message（带 `tool_result` 块）发给 Claude 原生协议；用于 Claude Code / Codex overfit 模型。 |

`agentmain.py:54-78` 的 `load_llm_sessions` 把 `mykey.py` 所有形如 `*_config/cookie/api*` 的字典变量扫出来，按变量名关键字路由：

```
含 'native' + 'claude' → NativeClaudeSession + NativeToolClient
含 'native' + 'oai'    → NativeOAISession   + NativeToolClient
含 'claude'           → ClaudeSession      + ToolClient
含 'oai'              → LLMSession         + ToolClient
含 'mixin'            → MixinSession (组合多个上面的 session)
```

**`mykey.py` 的变量名决定协议**（不是 model 名决定）——这是新手最易踩的坑，mykey_template.py 有 425 行注释反复强调。

### 4.2 `MixinSession` 故障转移（`llmcore.py:871-930`）

- `__setattr__` 广播：`system/tools/temperature/history` 等属性会同步到所有子 session，保证主备切换后上下文一致。
- 主 session 的 `raw_ask` 被改写为 `_raw_ask`，内部 round-robin 重试；子 session 的 `max_retries=0`（避免双层重试爆炸）。
- **Spring back**：切到备用节点 300 秒后（`spring_back`），下次请求自动试回主节点（`_pick()`）。
- **部分失败检测**：如果流中途收到 `[!!! 流异常中断`，下一次请求主动切下一个节点（不重试当前请求，避免重复消耗）。

### 4.3 Prompt Cache / Thinking / Reasoning

- Claude 侧：最后 2 条 user message 的最后一个 block 自动打 `cache_control: ephemeral`（`make_messages`，`llmcore.py:598-603`）；支持 `thinking_type: adaptive/enabled/disabled`；`reasoning_effort` 映射到 `output_config.effort`（`xhigh → max`）。
- OpenAI 侧：`chat_completions` 和 `responses` 两种 API 模式全写；用 `_stamp_oai_cache_markers` 给走 OAI-compat 中继的 Claude 模型打 cache 标记。
- **`_RESP_CACHE_KEY`**：模块级生成 UUID 作为 `prompt_cache_key`，同一进程内稳定，多轮共享前缀缓存。

### 4.4 历史压缩（`llmcore.py:33-63`）

`compress_history_tags` 每 5 次调用触发 1 次：
- 保留最近 `keep_recent=10` 条原样
- 更早的消息里，把 `<thinking>/<tool_use>/<tool_result>/<history>/<key_info>` 标签的 body 截断为 `max_len=800`（头 400 + 尾 400）
- 进一步 `trim_messages_history` 会在 `cost > context_win * 3` 时砍最前面的消息（保持 user 起始、`_sanitize_leading_user_msg` 把 tool_result 压成纯文本避免孤儿引用）

这是 README 所说"<30K 上下文"的工程来源。

### 4.5 SSE 解析的鲁棒性

`_parse_claude_sse` / `_parse_openai_sse` 各自处理：
- `message_delta/content_block_delta/tool_use` 的 **流式拼装**（含 `input_json_delta` 的 partial JSON）
- **流异常中断检测**：没收到 `message_stop` 或 `stop_reason` 时，拼接 `[!!! 流异常中断]` 作为哨兵文本（给 Mixin 识别）
- **max_tokens 截断**：拼接 `[!!! Response truncated: max_tokens !!!]`，触发 `do_no_tool` 的拆分提示
- `_try_parse_tool_args`：面对 `{..}{..}` 连体 JSON 会 split 成多个 tool_use（模型罕见 bug 兜底）

`_stream_with_retry` 统一处理 HTTP 429/408/5xx，支持 `Retry-After` header。

---

## 5. 分层记忆（这是 GenericAgent 真正的"骨架"）

**规则文件**：`memory/memory_management_sop.md`（L0 元 SOP，88 行的"记忆宪法"）。

### 5.1 层级语义

| 层 | 文件 | 容量上限 | 职责 |
|---|---|---|---|
| **L0** | `memory_management_sop.md` | 固定 | 元规则：怎么写 L1/L2/L3，核心公理（"No Execution, No Memory"）、不可删改性、禁存易变状态、最小充分指针 |
| **L1** | `global_mem_insight.txt` | ≤30 行 | 极简索引，两层 `场景关键词→定位` 映射 + RULES（红线规则） |
| **L2** | `global_mem.txt` | 随环境膨胀 | 全局事实：路径/凭证/配置/ID 等 **Zero-shot 推不出**的环境特异性信息 |
| **L3** | `memory/*.md` + `memory/*.py` | 无 | 任务级 SOP（`*_sop.md`）+ 可复用工具脚本（ljqCtrl/ocr/adb/procmem/vision/ui_detect/keychain/…） |
| **L4** | `memory/L4_raw_sessions/` | 自动归档 | scheduler 每 12h 调 `compress_session.batch_process`，把 `temp/model_responses/*.txt` 压缩为 `MMDD_HHMM-MMDD_HHMM.txt` 供长程召回 |

### 5.2 系统提示如何装配（`agentmain.py:36-40` + `ga.py:550-561`）

```python
sys_prompt = open('assets/sys_prompt.txt').read()            # 极短的 Role + Principles
sys_prompt += f"\nToday: {today}\n"
sys_prompt += get_global_memory()                             # 注入 L1 Insight + cwd + 固定骨架
sys_prompt += backend.extra_sys_prompt                        # native client 的 thinking 协议
```

`assets/sys_prompt.txt` 只有 7 行。真正"压缩的能力目录"在 `global_mem_insight.txt`（L1）里：

```
浏览器特殊操作: tmwebdriver_sop(文件上传/图搜/PDF blob/物理坐标/HttpOnly Cookie/...)
键鼠: ljqCtrl_sop(禁pyautogui/先activate)  截图/视觉: ocr/vision_sop
定时:scheduled_task_sop | 自主:autonomous_operation_sop
手机:adb_ui.py
L3: memory_cleanup_sop | skill_search | ui_detect.py | ocr_utils.py | subagent | web_setup_sop | plan_sop | ...
[RULES] 1. 搜索先行... 2. 交叉验证... 3. 编码安全... 4. 闭环... 5. 进程... 6. 窗口... 7. web JS... 8. SOP...
```

这意味着：**主系统提示只告诉模型"我有这些能力类别"**，具体实现模型在需要时 `file_read ../memory/xxx_sop.md` 按需获取。这是 GenericAgent 省 token 且可扩展的根基。

### 5.3 L3 SOP 的写作范式

抽样 `plan_sop.md`（263 行）、`subagent.md`（62 行）、`verify_sop.md`（65 行）、`autonomous_operation_sop.md`（45 行），可以归纳出统一模式：

1. **触发/禁用条件**（什么时候用，什么时候别用）
2. **硬约束/红线**（⛔ / ⚠️ 符号标出）
3. **步骤或流程**（带 checkpoint 提示、文件路径模板）
4. **失败处理 + 强制约束**

Plan 模式尤其精致：
- 主 agent 禁止直接探测，必须启 subagent 探测（保护主 agent 上下文）
- 步骤标注 `[D]` 委托、`[P]` 并行、`[?]` 条件分支
- 强制 `[VERIFY]` 步骤（由独立 subagent 对抗性验证）
- 完成检查：`file_read(plan.md)` 扫全文确认 0 个 `[ ]` 残留
- 通过 `do_no_tool` 拦截"声称完成但没过 VERIFY"（`ga.py:456-459`）

### 5.4 Plan 模式的内核耦合点

`handler.enter_plan_mode(plan_path)`（`ga.py:422-424`）把 `max_turns` 从 40 提到 100，并把 plan.md 路径写入 `self.working['in_plan_mode']`。之后：
- 每 5 轮注入 "📌 当前步骤：..." 提示（`ga.py:539`）
- 扫 plan.md 剩余 `[ ]` 数，全清零自动退出 plan 模式
- 自称"任务完成"但未走 VERIFY → 拦截（见 `do_no_tool`）

这是整个系统里**唯一硬编码在内核的 SOP hook**；其他 SOP（subagent/autonomous/scheduled/tmwebdriver/ljqCtrl/…）都是纯 markdown，靠 LLM 自己读自己执行。

### 5.5 长期使用下的上下文膨胀风险分析

这是一个值得专门展开的问题：**用得越久，Skill 越多，上下文会不会反而被记忆本身塞爆？** 答案要分三层来看——常驻层、召回层、历史层，每一层都有不同的膨胀风险与防御机制。

#### 5.5.1 当前项目实测基线（2026-05）

先给量化基线，便于理解各层规模：

| 文件/组件 | 当前体积 | 注入频率 |
|---|---|---|
| `assets/sys_prompt.txt` | 699 字节 / 7 行 | 每请求 1 次（常驻） |
| `assets/insight_fixed_structure.txt` | 649 字节 | 每请求 1 次（常驻） |
| `memory/global_mem_insight.txt`（L1） | 1.8 KB / 22 行 | 每请求 1 次（常驻） |
| `memory/global_mem.txt`（L2） | 23 字节（仅头部注释，**当前空**） | 不直接注入 |
| `memory/*.md` + `memory/*.py`（L3） | 14 个 SOP + 7 个工具 ≈ 1016 行 | **按需 `file_read`** |
| 工具 Schema（`tools_schema.json`） | ~2 KB | 每 10 轮重注入 1 次 |
| Anchor Prompt（最近 40 条 summary） | ≤ 40 × ~100 字符 = ~4 KB | 每轮注入 |
| 当前 handler.working.key_info | ≤ 200 tokens | 每轮注入 |

**常驻基线 ≈ 5 KB / 1.5K tokens**（系统提示 + L1 + 固定骨架 + 当前 Schema）。这是任何一次请求都要付的"入场费"。README 宣称"<30K 上下文"的实际含义，正是把这个常驻基线 + 历史 summary + 工作记忆控制在 30K 之内，而把细节挤到 L3 按需读取。

#### 5.5.2 三层膨胀风险解析

**① 常驻层（每轮必付）—— 这才是真正的敌人**

唯一**无条件注入每轮 prompt** 的记忆是 L1（`global_mem_insight.txt`）。所以 L1 膨胀 = 每轮都多花 token × 无数轮 × 所有任务。这也是为什么 `memory_management_sop.md` 把 L1 上限写成**硬约束 ≤30 行**（当前实测 22 行 / 1.8 KB），而 `memory_cleanup_sop.md` 进一步给出明确的 **ROI 评估公式**：

```
ROI = (不放这几个词的犯错概率 × 代价) / 每轮词数成本
```

——这是极少见的把"记忆条目的存在价值"量化到公式层面的设计。

**L1 的潜在膨胀点**：

| 膨胀源 | 现有防御 | 实际强度 |
|---|---|---|
| 新 SOP 加入时在 L1 写描述/翻译 | `memory_cleanup_sop` 明确禁止"括号里放内容描述/实现细节/名字翻译" | ⚠️ 全靠模型自觉，无强制 |
| `[RULES]` 规则越攒越多 | 要求"全局高 ROI 才留，特定场景降级到 L3" | ⚠️ 靠模型定期清理 |
| SOP 数量无上限增长 | 只写文件名不写描述，依赖文件名自解释 | ✅ 每条 20 字符左右，14 个 SOP 才 ~1 行 |

**结论**：L1 **理论上**能随使用量缓慢漂移膨胀，但增速受制于"模型按 cleanup SOP 做压缩"。一个用了半年的实例，L1 从 22 行到 35–40 行完全可能；超过 40 行就会进入明显劣化区（每轮多 ~1K tokens 常驻成本 + 前缀 cache 可能失效）。

**② 按需召回层（读了才付）—— 风险集中在单任务内的读取爆炸**

L2 / L3 都是 `file_read` 拉取，理论上不会自动膨胀上下文。但单次任务内**反复读 SOP** 会有问题：

从 `ga.py:410-416` 看到：
```python
if 'memory' in path or 'sop' in path:
    next_prompt += "\n[SYSTEM TIPS] 正在读取记忆或SOP文件，若决定按sop执行请提取sop中的关键点（特别是靠后的）update working memory."
```

这段逻辑是**诱导模型读 SOP 后立即蒸馏到 key_info**，避免把整个 SOP 字面量留在对话历史里。但这有两个隐患：

- **SOP 越写越长的漂移**：`plan_sop.md` 已经 262 行 / ~11 KB，`tmwebdriver_sop.md` 122 行。单次读一个 SOP 就相当于 3–5K tokens 的一次性吞吐。Claude 的 prompt cache 能部分消化（第二次读几乎免费），但换模型、换任务时 cache 命中率显著下降。
- **重复召回放大**：`file_access_stats.json` 只记 count/last，**未被任何压缩代码消费**。长程运行后，热 SOP 可能被反复读入历史；虽然 `compress_history_tags` 会截断老消息里的 `<tool_result>` 块（`llmcore.py:42-44`，单 block 压到 800 字符），但这依赖 5 轮一次的触发节奏，短期高频重读仍会冲击当轮 prompt。

**③ 历史层（`client.backend.history`）—— 唯一真正"无限涨"的地方**

这是最大的潜在风险点。`BaseSession.history` 是 list，只由两个机制裁剪：

1. **`compress_history_tags`**（`llmcore.py:33-63`）：每 5 次调用触发 1 次，把 keep_recent=10 之外的消息里的标签 body 压到 800 字符
2. **`trim_messages_history`**（`llmcore.py:90-102`）：只有在 `cost > context_win * 3` 时才触发硬裁剪，目标压到 `context_win * 3 * 0.6`

注意 `context_win` 默认 28000 字符，所以硬裁剪门槛 = **84000 字符 ≈ 21K tokens**。这意味着：在达到硬裁剪门槛前，历史会**持续堆积**，只靠标签压缩减速。

长期使用的真实后果链条：

```
单任务 100+ 轮 plan 模式 → history 膨胀到 ~80K 字符
    → compress_history_tags 按 5 轮一次截断老 tool_result
    → 大量 "[Truncated]" 占位符出现在历史里
    → 模型回看"我上一步做了什么"时拿到的是摘要片段，细节丢失
    → 如果任务继续扩张触发 trim_messages_history
    → pop 掉最前面的 user 消息 → 任务起点信息丢失
    → 模型可能"忘了最初目标"，开始漂移
```

`compress_history_tags` 和 `trim_messages_history` 都**不触碰 `<history>` tag 本身**（`_hist_pat` 只会把 `<history>...</history>` 里的内容替换为 `[...]`，这个压缩反而是把 Anchor Prompt 里的 40 行 summary 砍掉——`llmcore.py:43`）。所以长程任务的"Agent 失忆"会优先表现为 **Anchor 摘要丢失**，而不是整段对话消失。

#### 5.5.3 实际会导致"执行质量下降"的三种典型场景

结合上面的机制和现有防御，用户长期使用下真正可能遇到的质量下降路径：

**场景 A：L1 索引漂移（缓慢劣化，数月尺度）**

- 表现：常驻 prompt 从 1.8 KB 涨到 4–6 KB，每轮多付 1–2K tokens，前缀 cache 随 L1 改动频繁失效（改一个字符整条 L1 cache block 失效）
- 触发条件：长期新增能力未触发 `memory_cleanup_sop`
- 防御强度：⭐⭐（靠模型自觉，且 cleanup SOP 本身得被记得去读）

**场景 B：单任务内 SOP 二次污染（单会话内，轮数尺度）**

- 表现：plan_sop + tmwebdriver_sop + verify_sop 都读过之后，单任务对话历史里塞了 500+ 行 SOP 文本；换模型/失败重试导致 cache miss，成本翻数倍
- 触发条件：复杂任务链多次读 SOP，且没及时把关键点蒸馏进 key_info
- 防御强度：⭐⭐⭐（`[SYSTEM TIPS] 提取关键点 update working memory` 在诱导，`compress_history_tags` 在兜底）

**场景 C：超长任务 history trim 丢上下文（临界点突变）**

- 表现：任务在第 150+ 轮突然"忘了自己在干什么"，重复已做过的步骤
- 触发条件：`cost > context_win * 3`（~84K 字符），`trim_messages_history` pop 到最前面 user 消息
- 防御强度：⭐⭐⭐⭐（`agent_loop.py:53` 每 10 轮重注入工具 + `ga.py:533-537` 第 7/65 轮强制提醒 + Anchor 里的 key_info 不会被裁剪）

#### 5.5.4 相对同类系统的优劣

对比"把全部工具描述和能力目录塞进一个大 system prompt"的传统做法（Claude Code / Cursor 早期 / AutoGPT 等），GenericAgent 的三层设计**确实有效**：

- ✅ **常驻层仅 1.5K tokens**，是传统做法的 1/10 到 1/50——这是真实节省，非营销数字
- ✅ **L3 按需加载**意味着新增能力几乎不增加常驻成本（只要 L1 条目用"场景词"而非描述）
- ✅ **Summary 化 history** 让 40 轮对话的工作记忆只占 ~4 KB
- ✅ **Plan 模式硬阈值**（max_turns=100, 第 90 轮强制 ask_user）防止失控

但也有**真实不足**：

- ❌ **L1 压缩完全依赖模型自觉**：没有硬指标监控（例如"L1 > 40 行自动告警"）；`file_access_stats.json` 收集了访问频次却无人消费，浪费了一个现成的"冷条目下沉"信号
- ❌ **L3 SOP 本身可能膨胀**：`plan_sop.md` 262 行已经偏重，没机制阻止 SOP 继续增长
- ❌ **缺"记忆回归测试"**：记忆被模型改坏了（比如误删 tmwebdriver_sop 的 CDP 章节）只能等到下次用到才发现
- ❌ **`context_win * 3` 的硬裁剪阈值过于乐观**：真到那一步已经严重影响 cache 命中率，实际应该在 `1.5×` 就启动更积极的 summary 化

#### 5.5.5 结论与给长期用户的建议

**直接回答原问题**：是的，长期使用会导致一定的上下文膨胀，但**不是线性失控**。分层记忆的设计确实把膨胀速度压到了很低的水平——单纯使用（不做任何维护）可能在 3–6 个月后出现场景 A 的缓慢劣化，表现为"模型比刚装时慢一点、每轮贵一点"。场景 B 和 C 是单次任务的事，不受长期使用累积影响。

**可操作的维护建议**：

1. **每月 1 次**对 Agent 说：`按 memory_cleanup_sop 清理 L1`——强制触发 ROI 评估
2. **每季度 1 次**：检查 `memory/*_sop.md` 行数，>200 行的 SOP 考虑拆分或精简
3. **观察信号**：如果某个常规任务的轮数明显增多、或者模型在 Anchor 摘要里出现"[omitted long content]"频繁，就是 history 压缩开始伤害质量的前兆
4. **手动消费 `file_access_stats.json`**：6 个月没被读过的 L3 SOP 可以归档到 `memory/archive/`，L1 同步删触发词
5. **升级建议（代码级）**：`launch.pyw` 的 idle_monitor 里可以加一个"记忆体检"反射——空闲时自动跑 `ls memory/ | wc -l`、`wc -l memory/global_mem_insight.txt`，超阈值自动触发清理任务

**一句话总结**：GenericAgent 的分层记忆在"抵抗膨胀"这件事上做对了 80% 的工程，剩下 20% 依赖模型自觉（cleanup SOP）和运气（用户会不会主动维护）。它不会让你"用了一年后卡成幻灯片"，但确实会**慢慢变钝**——这是所有自演化系统的共同宿命，只能靠周期性维护而非一劳永逸的架构解决。

---

## 6. 浏览器接管 —— `TMWebDriver` + `simphtml` + CDP Bridge

### 6.1 反向控制架构

不是 Selenium/Playwright，而是：

```
用户真实 Chrome（保留 Cookie 登录态）
     ↓ 装 MV3 扩展 tmwd_cdp_bridge/
     ↓ extension background.js 连回 localhost:18765 (WS)
                          ↓
TMWebDriver(host=127.0.0.1, port=18765)
  - WebSocketServer  (ws://) ← 主通道，页面注入脚本连入
  - bottle HTTP      (port+1) ← long-poll fallback + 远端 link API
  - sessions{}       ← 每个 tab 一个 Session
```

- 启动时（`TMWebDriver.__init__`）先探测 `port+1` 是否已被占用：如果是，说明已有主 Driver，自己变成 **remote 模式**（通过 `/link` 转发请求）。实现了多进程共存。
- 扩展通过 `chrome.debugger` API 拿到 CDP（Chrome DevTools Protocol）能力，可做：cookies、tabs、CDP 任意方法（`DOM.setFileInputFiles` 文件上传、`Page.bringToFront` 切前台、`Input.dispatchMouseEvent` 物理点击、`Page.navigate` 导航等）。
- `web_execute_js` 识别 JSON 字符串（如 `{"cmd":"cdp","tabId":N,"method":"...","params":{...}}`）→ 走 CDP 分支；否则走普通 JS 注入。
- 支持 `batch` 命令：单次请求里嵌多个 cmd，子命令用 `$N.path` 引用前面结果（见 `tmwebdriver_sop.md` §CDP桥）。

### 6.2 `simphtml.get_html`：给 LLM 看的 HTML

`simphtml.py`（870 行）在页面端跑一段大 JS（`js_optHTML`），做以下事情：
- 跳过 SCRIPT/STYLE/NOSCRIPT/META/LINK/TEMPLATE 等噪声标签
- 同源 iframe 内容内联、Shadow DOM 展平
- 计算每个节点的 `getBoundingClientRect` + `getComputedStyle`，判断可见性（opacity/display/visibility/zIndex/面积）
- 剔除边栏/浮动/被遮盖元素
- 小 dropdown（≤7 个 item）保留，避免丢失菜单
- INPUT/TEXTAREA 的 `value` 写回 DOM attr，radio/checkbox 的 `checked`、SELECT 的当前值回写
- autofill 状态标记为 `⚠️受保护`（引导模型读 `tmwebdriver_sop` 绕过方案）
- 结果由 BeautifulSoup 再做一轮瘦身，裁到 `maxchars=35000`

于是 LLM 拿到的"HTML"只有关键可交互元素，token 成本可控。

---

## 7. 入口与调度（`agentmain.py` / `launch.pyw` / `hub.pyw`）

### 7.1 `agentmain.py` 的三种运行模式

```python
argparse:
  (none)                    → REPL 模式，stdin 读 prompt
  --task IODIR              → 文件 IO 模式（subagent 用）
     --input "文本" 可选，长文本手动写 temp/IODIR/input.txt
     [--bg]                 → popen 自己，print PID 后退出（后台）
  --reflect PATH            → 反射模式，动态 import PATH，每 INTERVAL 秒调 check()
                              check() 返回 None 则跳过，返回字符串则作为 prompt 触发
```

### 7.2 `GeneraticAgent` 主类（`agentmain.py:42-172`）

- `load_llm_sessions`：每次调用都检查 `mykey.py` mtime，改了就热重载；保留旧 history 接到新 client。
- `next_llm(n)`：切模型时把 `backend.history` 整个搬过去；如果目标是 GLM/MiniMax/Kimi 自动切换 `tools_schema_cn.json`（这些模型更喜欢中文 schema）。
- `run()` 是后台 worker 线程，从 `task_queue` 取任务循环。每个任务构造一个新的 `GenericAgentHandler`，但 LLM history 保持连续（handler 只管本轮 working memory）。
- **前一轮 checkpoint 继承**：`handler.working['passed_sessions']` 记录上次 checkpoint 经过了几个对话，>0 时在 key_info 里注入 `[SYSTEM] 此为 N 个对话前设置的 key_info，若已在新任务，先更新或清除`。
- **slash 命令**：`/session.xxx=value`（热改 backend 属性）、`/resume`（扫 `temp/model_responses/*.txt` 恢复会话）。

### 7.3 `reflect/` 两个内置反射脚本

- **`autonomous.py`**（5 行！）：每 30 分钟返回一条 "[AUTO] 用户离开超过30分钟，请读自动化 sop" 触发自主任务。
- **`scheduler.py`**（131 行）：
  - 用 socket bind `127.0.0.1:45762` 做端口锁，防止重复起实例（reload 时 `_lock` 保留跳过）
  - 每 120s 扫 `sche_tasks/*.json`，条件（enabled + 过了 schedule 时间 + cooldown 已过 + 未超 max_delay）满足则返回 prompt
  - repeat 支持 `daily/weekday/weekly/monthly/once/every_Nh/every_Nd`
  - 每 12h 静默调 `L4_raw_sessions/compress_session.batch_process` 做归档
  - 日志写 `sche_tasks/scheduler.log`

启动方式：`python agentmain.py --reflect reflect/scheduler.py`（`launch.pyw --sched` 自动 popen）。

### 7.4 `launch.pyw` 桌面启动器

- 起 streamlit（`frontends/stapp.py`）在随机端口 18501–18599（`find_free_port`）
- 用 pywebview 包装成桌面浮窗（Win 屏右上，macOS 固定 x=100）
- 可选 `--tg/--qq/--feishu/--wecom/--dingtalk/--sched` popen 对应 bot/调度器
- **idle_monitor**：每 5s 扫页面 DOM 的 `#last-reply-time`，如果 >30 分钟没回复且距上次触发 >2 分钟，自动注入那条 `[AUTO]🤖 用户已经离开超过30分钟...` 去激活自主任务——这是 `autonomous.py` 在 **Streamlit 版**里的等价实现。

### 7.5 `hub.pyw` 服务管理器

纯 tkinter + stdlib，扫 `reflect/*.py` 和 `frontends/*app.py` 自动生成服务列表，一个 GUI 表格启停。

---

### 7.6 启动与使用完整指南

> 本节直接面向使用者，给出从零开始到熟练运维的全部操作路径。所有示例默认 `cwd = GenericAgent 代码根目录`。

#### 7.6.1 环境准备（一次性）

```bash
# 1. 克隆
git clone https://github.com/lsdefine/GenericAgent.git && cd GenericAgent

# 2. Python 版本：3.10 ≤ python < 3.14（pywebview 对 3.14 不兼容）
python3 --version

# 3. 装最小依赖（核心 4 个包即可跑）
pip install requests beautifulsoup4 bottle simple-websocket-server

# 4. 复制密钥模板
cp mykey_template.py mykey.py
#   然后编辑 mykey.py 填 apikey/apibase/model（详见 §4.1 的变量命名规则）
```

**哲学提醒**：README 明确说"更推荐由 Agent 在使用中自举环境，而不是预先手动装完整依赖"。即 GUI/Bot 相关的包可以等你第一次用到时再让 Agent 自己装（`pip install streamlit pywebview` 等）。

#### 7.6.2 终端（REPL）模式 —— 最轻量

```bash
python3 agentmain.py                      # 用 mykey.py 里第 0 个 session
python3 agentmain.py --llm_no 2           # 用第 2 个 session
python3 agentmain.py --verbose            # 显示每轮 LLM 原始输出（调试用）
```

启动后进入 `> ` 提示符，直接打字发送任务。按 `Ctrl+C` 中止当前任务（不退出进程）。

**内置 REPL 命令**（在输入框里敲）：

| 命令 | 作用 |
|---|---|
| `/new` | 清空当前对话上下文（history 清零） |
| `/continue` | 列出最近 10 个可恢复会话（从 `temp/model_responses/*.txt`） |
| `/continue 3` | 恢复第 3 个历史会话 |
| `/resume` | 让 Agent 自己扫历史文件并推荐恢复（本质是一条预制 prompt） |
| `/session.reasoning_effort=high` | 热改当前 backend 的 reasoning 等级 |
| `/session.thinking_type=adaptive` | 热改 thinking 模式 |
| `/session.temperature=0.3` | 热改温度 |

#### 7.6.3 桌面 GUI 模式 —— 默认最舒服

```bash
pip install streamlit pywebview
python3 launch.pyw                        # 默认：streamlit + pywebview 浮窗
python3 launch.pyw --llm_no 2             # 指定 session
python3 launch.pyw --sched                # 同时启动定时任务调度器（背景进程）
```

发生了什么（见 `launch.pyw:81-144`）：
1. `find_free_port(18501, 18599)` 随机选端口
2. `streamlit run frontends/stapp.py` 后台启动
3. `pywebview.create_window` 包装成桌面窗口（Windows 右上角，macOS 固定 x=100）
4. `idle_monitor` 线程每 5s 检测页面 `#last-reply-time`，>30 分钟无回复自动注入"[AUTO]" 自主任务

**同时启动多个 Bot**（所有 Bot 共享同一个 `launch.pyw` 父进程）：

```bash
python3 launch.pyw --tg --qq --feishu --wecom --dingtalk --sched
```

**替代 UI**（不喜欢 Streamlit 的）：

```bash
python3 frontends/qtapp.py                # PyQt 版桌面应用
streamlit run frontends/stapp2.py         # 另一种 Streamlit 风格（更炫）
python3 frontends/dcapp.py                # 轻量 Desktop Chat 窗口
```

#### 7.6.4 一次性任务/Subagent 模式（脚本化）

用于在脚本中调 Agent 做一件事：

```bash
# 同步模式：等 Agent 完成，结果写 temp/mytask/output.txt
python3 agentmain.py --task mytask --input "帮我统计 ~/Downloads 里的 pdf 数量"

# 后台模式：立刻 print PID 后退出，Agent 继续在后台跑
python3 agentmain.py --task mytask --input "..." --bg
# 输出：12345   ← PID
```

文件 IO 协议（详见 `memory/subagent.md`）：

```
temp/mytask/
├── input.txt       ← 你的任务描述（--input 会自动写）
├── output.txt      ← Agent 流式输出（append），以 "[ROUND END]" 结尾
├── output1.txt     ← 第二轮输出
├── reply.txt       ← 你写这个文件 → 触发 Agent 继续对话
├── _stop           ← 你写这个（空内容即可）→ Agent 当轮结束立即退出
├── _keyinfo        ← 你写这个 → 内容注入 working memory 的 key_info
├── _intervene      ← 你写这个 → 内容追加到下一轮 prompt
└── stdout.log / stderr.log  ← --bg 模式的子进程日志
```

这就是 plan_sop 里"主 Agent 派 subagent 做探测"的底层机制。

#### 7.6.5 反射（Reflect）模式 —— 被动触发

```bash
# 定时任务调度器（每 120s 扫 sche_tasks/*.json）
python3 agentmain.py --reflect reflect/scheduler.py

# 自主模式（用户离开 >30min 自动触发）—— 已被 launch.pyw 内置，一般不单独用
python3 agentmain.py --reflect reflect/autonomous.py

# 自定义反射脚本：写个返回 str 或 None 的 check() 函数
cat > reflect/mywatch.py <<EOF
INTERVAL = 60
ONCE = False
def check():
    # 在这里写监控逻辑，返回字符串触发任务，返回 None 跳过
    import os
    if os.path.exists('/tmp/trigger.flag'):
        os.remove('/tmp/trigger.flag')
        return "触发条件满足，请执行 xxx"
    return None
EOF
python3 agentmain.py --reflect reflect/mywatch.py
```

定时任务 JSON 示例（放 `sche_tasks/` 下）：

```json
{
  "schedule": "08:00",
  "repeat": "daily",
  "enabled": true,
  "prompt": "检查我的邮箱未读邮件，汇总写到 inbox_summary.md",
  "max_delay_hours": 6
}
```

`repeat` 可选：`daily | weekday | weekly | monthly | once | every_Nh | every_Nd`。执行报告自动写到 `sche_tasks/done/YYYY-MM-DD_HHMM_<taskname>.md`。

#### 7.6.6 IM 机器人配置（全平台）

**统一模式**：所有 bot 都是独立 Python 进程，通过 `from agentmain import GeneraticAgent` 各自实例化一个 Agent，共享 `mykey.py` + `memory/` + `temp/`。配置方式都是编辑 `mykey.py` 添加凭证字段，然后运行对应的 `frontends/<platform>app.py`。

| 平台 | 安装命令 | `mykey.py` 字段 | 启动命令 | 默认锁端口 |
|---|---|---|---|---|
| **Telegram** | `pip install python-telegram-bot` | `tg_bot_token`, `tg_allowed_users=[uid1,uid2]` | `python frontends/tgapp.py` | 19527 |
| **QQ** | `pip install qq-botpy` | `qq_app_id`, `qq_app_secret`, `qq_allowed_users=['openid']` 或 `['*']` | `python frontends/qqapp.py` | 19528 |
| **飞书** | `pip install lark-oapi` | `fs_app_id`, `fs_app_secret`, `fs_allowed_users=['ou_xxx']` 或 `['*']` | `python frontends/fsapp.py` | — |
| **钉钉** | `pip install dingtalk-stream` | `dingtalk_client_id`, `dingtalk_client_secret`, `dingtalk_allowed_users=['staffid']` | `python frontends/dingtalkapp.py` | 19530 |
| **企业微信** | `pip install wecom-aibot-sdk` | `wecom_bot_id`, `wecom_secret`, `wecom_allowed_users`, `wecom_welcome_message` | `python frontends/wecomapp.py` | 19531 |
| **个人微信** | `pip install pycryptodome qrcode requests` | 无需配置，扫码登录 | `python frontends/wechatapp.py` | — |
| **Discord** | `pip install discord.py` | `discord_bot_token`, `discord_allowed_users` | `python frontends/dcapp.py` | 19532 |

**获取凭证的入口**：

- **Telegram**：找 `@BotFather` 发 `/newbot` 拿 token；用 `@userinfobot` 查自己的 uid
- **QQ**：[q.qq.com](https://q.qq.com) 开放平台创建机器人；首次用户发消息后，`temp/qqapp.log` 会记下 openid
- **飞书**：[open.feishu.cn](https://open.feishu.cn/) 创建自建应用 → 添加"机器人"能力 → 开权限 `im:message` / `im:message:send_as_bot` / `contact:user.id:readonly` → 凭证与基础信息页拿 App ID / App Secret（详见 `assets/SETUP_FEISHU.md`）
- **钉钉**：开放平台创建"机器人"应用 → 连接模式选"Stream"（无需公网 webhook）→ 拿 AppKey/AppSecret
- **企业微信**：企微智能机器人 SDK 文档
- **个人微信**：无需凭证，首次启动会弹二维码，手机扫码绑定

**鉴权语义**（重要！）：

- `*_allowed_users` 为**空列表** = 拒绝所有人（Telegram 会直接 ERROR 退出，见 `tgapp.py:881-882`）
- `*_allowed_users = ['*']` = 公开访问（QQ/飞书/钉钉/企微/Discord 支持，Telegram 不支持通配）
- `*_allowed_users = ['uid1', 'uid2']` = 白名单

**通用聊天命令**（所有 IM 前端 + Streamlit UI 都支持）：

```
/help           查看命令列表
/status         当前状态
/stop           停止当前任务
/new            清空对话
/restore        恢复上次对话
/continue       列出可恢复会话
/continue 3     恢复第 3 个
/llm            查看模型列表
/llm 2          切到第 2 个模型
```

**飞书特殊能力**（`fsapp.py` 653 行最复杂）：
- 入站：文本 / 富文本 post / 图片 / 文件 / 音频 / media / 交互卡片 / 分享卡片
- 出站：流式进度卡片（边执行边更新）、图片回传、文件回传
- 视觉：图片首轮以多模态输入直接喂给兼容 OpenAI Vision 的后端

#### 7.6.7 hub.pyw —— 图形化服务管理器

如果不喜欢开一堆终端，用这个：

```bash
python3 hub.pyw
```

- 纯 tkinter + 标准库，零第三方依赖，跨平台
- 自动扫描 `reflect/*.py` 和 `frontends/*app.py`，生成服务列表（每项一个 checkbox）
- 勾选即启动，取消勾选即停止（`SIGTERM` + 5s 超时 `SIGKILL`）
- 每个子进程的 stdout/stderr 实时显示在下方 Output 区（黑底，Consolas）
- 自身用 `127.0.0.1:19735` 做端口锁，重复启动会弹"Already running."

#### 7.6.8 多实例运行（Multi-Instance）

这是个**需要手动绕过设计约束**的进阶场景。默认架构是**单实例导向**的，证据：

1. `hub.pyw:LOCK_PORT=19735`、`scheduler.py` bind `45762`、`launch.pyw` streamlit 抢 18501–18599 端口段
2. 每个 IM bot 都调 `ensure_single_instance(port, label)` 占固定端口：tg=19527, qq=19528, dingtalk=19530, wecom=19531, dcapp=19532
3. `plugins/langfuse_tracing.py` 自激活，多实例同用一个 Langfuse project 会追踪混淆
4. `memory/` 目录所有实例共享，并发写 SOP 会相互覆盖
5. `temp/` 下 subagent 任务目录以 `mytask` 命名，多实例容易撞名

**方案 A：不同代码副本 + 不同 mykey.py（推荐）**

最干净，每个实例独立的记忆/配置/日志：

```bash
# 1. 复制整个目录
cp -r GenericAgent GenericAgent_work
cp -r GenericAgent GenericAgent_home

# 2. 各自编辑 mykey.py（可用不同的 LLM / 不同的 bot token）

# 3. 分别启动（不同平台 bot 可并存）
cd GenericAgent_work  && python3 launch.pyw --tg &
cd GenericAgent_home  && python3 launch.pyw --feishu &
```

代价：记忆不共享，技能树会分叉生长。

**方案 B：同代码目录 + 错开端口（折中）**

共享 `memory/`，但要逐一改端口：

```bash
# 实例 1：正常起
python3 launch.pyw --tg --qq

# 实例 2：改 streamlit 端口段 + 关掉已占用的 bot
python3 launch.pyw 18700        # 第一个位置参数 = streamlit port
#     这个实例就不要再开 tg/qq（端口已被实例 1 占）
```

如果非要让两个实例都跑 Telegram，必须：
1. 改 `frontends/tgapp.py:880` 里的 `ensure_single_instance(19527, ...)` 端口
2. 或者 fork 一份 `tgapp.py` 改名 `tgapp2.py` 并改端口、用不同的 `tg_bot_token2` 字段
3. 由于两个 bot 会并发写 `temp/model_responses/<pid>.txt`（按 PID 分文件），这一块本身没冲突

**方案 C：不同平台 bot 并存同一实例（零改造，最常用）**

其实不需要"多实例"——**一个 `launch.pyw` 就能同时跑 6 个 bot**，因为它们占不同端口、独立进程、共享 Agent 后端：

```bash
python3 launch.pyw --tg --qq --feishu --wecom --dingtalk --sched
```

这对应 6 个子进程 + 1 个 streamlit + 1 个 scheduler + 1 个 pywebview 窗口，所有 Bot 的消息都路由到**同一个 `GeneraticAgent` 实例**（在 stapp.py 里 `@st.cache_resource` 单例），共享 history、共享记忆、共享任务队列。**消息按到达顺序排队处理**（`task_queue` 是 FIFO，并发来的多条消息串行跑）。

**方案 D：脚本化 subagent 并发（代码级）**

如果目的是"并行处理多个任务"（不是多用户），用 subagent 文件 IO 协议，天然支持并发：

```bash
# 同时派 3 个 subagent
python3 agentmain.py --task job1 --input "任务A" --bg   # → 12345
python3 agentmain.py --task job2 --input "任务B" --bg   # → 12346
python3 agentmain.py --task job3 --input "任务C" --bg   # → 12347

# 监察进度
tail -f temp/job1/output.txt temp/job2/output.txt temp/job3/output.txt
```

每个 subagent 是独立 Python 进程、独立 LLM history、独立工作目录——这是 `memory/subagent.md` 所说 **Map 模式** 的本质。约束：
- 浏览器不可共享（TMWebDriver 默认监听 `127.0.0.1:18765`，第二个实例会自动降级为 remote 模式但仍冲突）
- 键鼠不可共享（物理操作会打架）
- 文件系统是优势（不同 subagent 处理不同输入文件）

**多实例速查表**：

| 目的 | 推荐方案 | 难度 |
|---|---|---|
| 工作/生活环境分离 | A（复制目录） | ⭐ |
| 多平台 IM 统一入口 | C（同实例多 bot） | ⭐（默认就行） |
| 并行跑多个任务 | D（subagent --bg） | ⭐⭐ |
| 两个 LLM 并行跑同类任务对比 | A + 不同 `mykey.py` | ⭐⭐ |
| 同平台多账号（如 2 个 TG Bot） | B + 改端口 + 新字段名 | ⭐⭐⭐⭐ |

#### 7.6.9 常见故障排查

| 症状 | 常见原因 | 修复 |
|---|---|---|
| 启动报 "mykey.py or mykey.json not found" | 没从模板复制 | `cp mykey_template.py mykey.py` |
| REPL 第一次发消息卡住 | LLM 请求超时（proxy/网络） | `mykey.py` 加 `proxy='http://127.0.0.1:xxxx'`；或 `/llm N` 切别的 session |
| 每轮都看到 "工具库状态" 长 prompt | 前一次工具未变化时的缓存提示，正常 | 不用管 |
| `web_scan` 返回"没有可用标签页" | tmwd_cdp_bridge 扩展没装 | 读 `memory/web_setup_sop.md`，手动加载扩展 |
| Plan 模式一直不退出 | plan.md 里还有 `[ ]` 未处理 | 检查 plan.md，补上勾或手动 `handler._exit_plan_mode()` |
| IM bot 启动秒退 | `*_allowed_users` 为空 / 端口被占 / 凭证错 | 看对应 `temp/*app.log` 日志 |
| scheduler 不触发 | 过了 `max_delay_hours`、或 done/ 下已有今天报告 | 删掉 `sche_tasks/done/YYYY-MM-DD_*_<task>.md` 重跑 |
| 多实例启动互相踢 | 端口锁冲突 | 见 7.6.8 方案 A/B |

#### 7.6.10 日志与调试入口

```
temp/
├── model_responses/
│   └── model_responses_<PID>.txt   ← 每个进程完整 Prompt/Response 流（核心调试文件）
├── reflect_logs/
│   └── <script>_<date>.log          ← 反射模式执行记录
├── tgapp.log / qqapp.log / ...      ← 各 IM 前端日志
└── <taskname>/                      ← subagent 工作目录
    ├── output.txt, reply.txt, _stop, stdout.log, stderr.log

sche_tasks/
├── *.json                          ← 定时任务定义
├── done/YYYY-MM-DD_HHMM_*.md        ← 执行报告
└── scheduler.log                   ← 调度器日志

memory/
└── file_access_stats.json          ← SOP 访问频次（观察哪些 SOP 被反复读）
```

调试技巧：
- **追 LLM 真实行为**：`tail -f temp/model_responses/model_responses_<PID>.txt`（有 `=== Prompt ===` / `=== Response ===` 分隔）
- **追 Agent 决策流**：启动时加 `--verbose`，每轮 LLM 原始流 + 工具结果都打屏
- **追特定工具调用**：在 `ga.py` 的 `do_<tool_name>` 里加 print 即可，改了 `.py` 下次启动自动生效
- **观测记忆读写**：`watch -n 5 'cat memory/file_access_stats.json'` 看哪个 SOP 频繁被读（可能该升 L1）

---

## 8. 前端适配器总览（`frontends/`）

| 文件 | 行 | 协议/平台 | 特点 |
|---|---|---|---|
| `stapp.py` | 243 | Streamlit | `launch.pyw` 默认加载，内含重注入工具、桌面宠物启动、对话恢复 |
| `stapp2.py` | 1049 | Streamlit 豪华版 | 更多主题/动画 |
| `qtapp.py` | 2022 | PyQt 桌面 | 纯桌面版本；也最大，因为做了完整 GUI |
| `tgapp.py` | 917 | Telegram | `python-telegram-bot`；支持命令菜单 |
| `qqapp.py` | 121 | QQ 机器人 | `qq-botpy` WebSocket 长连接，无需 webhook |
| `fsapp.py` | 653 | 飞书 | `lark-oapi`；入站文本/富文本/图片/文件/音频/卡片；出站流式卡片；图片以多模态输入交给 Vision 模型 |
| `wecomapp.py` | 350 | 企业微信 | `wecom_aibot_sdk` |
| `dingtalkapp.py` | 151 | 钉钉 | `dingtalk-stream` |
| `wechatapp.py` | 397 | 个人微信（扫码）| `pycryptodome + qrcode`，无需公众号 |
| `dcapp.py` | 187 | (Desktop Chat app) | 轻量桌面对话窗 |
| `desktop_pet.pyw` / `desktop_pet_v2.pyw` | — | 桌面宠物 | HTTP 41983 接收 `?state=/?msg=`，显示 Agent 执行状态 |
| `chatapp_common.py` | 336 | 共享逻辑 | `/continue` `/new` `/restore` `/llm` 等命令解析；tag 清洗、分片、恢复会话 |
| `continue_cmd.py` | 296 | — | `/continue` 命令实现：扫 `temp/model_responses/*.txt`，解析 Prompt/Response 对，抽取用户首问 + summary，提供会话列表/恢复 |

所有前端的共同点：都 `from agentmain import GeneraticAgent` → `agent.put_task(query)` → poll `display_queue`。**业务逻辑 0 行在前端**。

---

## 9. `plugins/langfuse_tracing.py`：零侵入观测

37 行核心代码，自激活逻辑：

```python
_cfg = _load_mykeys().get('langfuse_config')
from langfuse import Langfuse
_lf = Langfuse(**_cfg) if _cfg else None
if _lf:
    # monkey-patch llmcore._write_llm_log → wrap as Langfuse generation span
    # monkey-patch agent_loop.agent_runner_loop → outer agent trace
    # monkey-patch BaseHandler.tool_before/after → tool span
```

只要 `mykey.py` 有 `langfuse_config`，`llmcore.reload_mykeys` 里一行 `from plugins import langfuse_tracing` 就会触发自激活——**核心文件零修改**。这种 monkey-patch 风格是 GenericAgent 扩展机制的另一个范式。

---

## 10. 依赖、配置与可运行性

### 10.1 `pyproject.toml` 最小依赖

```toml
dependencies = ["requests", "beautifulsoup4", "bottle", "simple-websocket-server"]
[optional] ui = ["streamlit", "pywebview"]
[optional] all-frontends = ["python-telegram-bot", "qq-botpy", "pycryptodome", "qrcode",
                             "lark-oapi", "wecom-aibot-sdk", "dingtalk-stream"]
```

核心只依赖 4 个 HTTP/WS/HTML 包。这和 README "~3K 行、pip install + API Key" 自洽。

### 10.2 `mykey_template.py`（425 行）

极详细的配置模板。关键：
- 变量名决定协议（见 §4.1）
- `mixin_config` 推荐用法，`llm_nos` 里字符串对应 session 的 `name` 字段
- `[1m]` 后缀触发 context-1m-2025-08-07 beta
- `fake_cc_system_prompt=True` 是 CC switch / CRS 等反代渠道必填
- 运行时 `/session.xxx=value` REPL 命令现场改（`reasoning_effort` / `thinking_type` / `thinking_budget_tokens` / `temperature` / `max_tokens`）

### 10.3 启动路径

1. 最小：`python agentmain.py`（REPL）
2. GUI：`python launch.pyw`（pywebview + streamlit）
3. 带调度：`python launch.pyw --sched`（额外起 scheduler）
4. Bot：`python frontends/<xxx>app.py`（各自独立进程）

---

## 11. 自我进化的实现机制（逐字代码级）

README 反复强调 "每次任务自动沉淀 Skill"。拆开看，其实是三个相互独立的落地点：

1. **长期记忆沉淀**：`start_long_term_update` 工具（`ga.py:492-507`）
   - 模型觉得任务有价值 → 调此工具
   - 工具自动把 `memory_management_sop.md` 的 L0 元规则读进来塞回 prompt
   - 模型按 L0 的"**只能提取行动验证成功的信息**"等约束，用 `file_patch` 去更新 L2 事实或新建 L3 SOP
   - **没有自动"总结并写盘"的黑盒**，是模型自己决定写什么、写哪层、写多少

2. **L4 会话归档**：`memory/L4_raw_sessions/compress_session.py` + `scheduler.py` 每 12 小时 batch
   - 扫 `temp/model_responses/*.txt`（每个 PID 一个文件，`_write_llm_log` 写入的 `=== Prompt ===` / `=== Response ===`）
   - 压缩格式 A（纯 JSON）与格式 B（裸文本）
   - 输出 `MMDD_HHMM-MMDD_HHMM.txt`，供"扫最近 10 个文件找上次聊了什么"的 `/resume` 命令用

3. **自主探索循环**：`autonomous.py` + `autonomous_operation_sop.md`
   - 用户离线 30 分钟，触发"阅读 autonomous_operation_sop"
   - SOP 约束：报告写在 `./autonomous_reports/RXX_xxx.md`，用 `helper.complete_task(...)` 自动编号、迁移、prepend 到 history.txt
   - 有权限边界：只读探测 + cwd 内写允许；修改 global_mem / 装软件 / 外部 API / 删非临时文件 **必须写报告待审**；读密钥 / 改核心代码 / 不可逆危险操作**绝对禁止**

三者之和：模型在**LLM 文本空间**里实现了"技能树生长"——没有 Python 层的 Skill 存储数据结构，一切都是 markdown + 脚本 + 模型自己按 SOP 维护。

---

## 12. 关键坑点与设计哲学摘录

从 `global_mem_insight.txt [RULES]` + 各 SOP 提炼：

1. **搜索先行**：搜文件名用 Everything `es`，禁 PS 递归 / 禁 dir 遍历；搜互联网优先 Google，禁 DuckDuckGo。
2. **交叉验证**：禁信摘要，数值必须进详情页核实。
3. **编码安全**：禁 PS `cat/type`（乱码）用 `file_read`；改文件前必读；memory 目录已在 `sys.path`，禁加虚假前缀 import。
4. **闭环**：模拟操作后必须物理确认；3 次失败请求用户介入；Git 操作完整闭环。
5. **进程**：禁 `pkill python`（会杀自己），必须精确 PID；禁 `os.kill(pid, 0)` 判活。
6. **物理坐标（ljqCtrl）**：传入必须是物理坐标 = 截图像素坐标；从 `pygetwindow` 拿的逻辑坐标要 `/ dpi_scale`。
7. **web JS**：输入用原生 setter + 事件链（绕过 React），点击前检 disabled，注意引号转义；`web_scan` 空/不全先等再 scan。
8. **记忆写入宪法**：No Execution, No Memory（无行动不记忆）；神圣不可删改；禁易变状态；最小充分指针。

---

## 13. 总体评价

### 13.1 架构亮点

- **三层极简**：Loop 100 行 + 9 工具 + 分层记忆。没一行是冗余的。
- **LLM 抽象力**：`llmcore.py` 把 Claude / OAI / Native CC / Native OAI / Mixin 五种协议统一到一个 `chat(messages, tools)` 接口，且兼顾 prompt cache / thinking / reasoning / SSE 流异常 / max_tokens 截断 / 重试退避 / 部分失败切节点。这部分是很多大框架都没做全的。
- **省 token 工程化**：1）单行 summary 历史替代完整对话 2）L1 索引 <30 行替代预装全部能力描述 3）Claude ephemeral cache 打最后两条 user 4）每 10 轮重注入工具 schema 5）`compress_history_tags` 按 5 的倍数渐进压缩。实测能把 Agent 上下文压到 30K 以内跑复杂任务。
- **扩展性错位**：扩展能力不靠写 Python plugin，靠**新增 L3 SOP 和脚本**。非开发者也能加能力。
- **真实浏览器接管**：通过 MV3 扩展 + WS + CDP，无头浏览器搞不定的登录态/文件上传/跨域 iframe 一把梭。
- **容错哲学**：每个协议解析都有"坏 JSON"兜底（`bad_json` 虚拟工具）、每个流都有"流异常中断"哨兵、每个子 agent 失败都 fallback 读 output.txt。

### 13.2 潜在风险

1. **单文件膨胀**：`ga.py`（561）、`llmcore.py`（983）、`simphtml.py`（870）、`TMWebDriver.py`（286 + 一堆内联 bottle）——文件内行数密度极高（大量行内分号、lambda、单行 if），可读性要求高。
2. **文本协议 ToolClient 渐被弃**：代码注释多次标注 `(deprecated)`，但仍保留以兼容弱模型。未来移除时要小心 mykey.py 向后兼容。
3. **记忆一致性全赖模型自觉**：没有任何代码强制 "有 tool 返回 success 才能写 memory"；L0 SOP 是约束，但依赖模型严格执行。写入的正确性最终由用户做 review（`autonomous` 模式显式要求用户审查）。
4. **subagent IPC 用文件系统**：简单可靠，但 Windows 下文件锁偶尔冲突；大规模并发 subagent 会产生很多 `temp/xxx/` 目录，需要手动清理。
5. **安全性**：`code_run` 的 `inline_eval=True` 可以直接在主进程 eval 任意 Python（被 `plan_sop` 用来触发 `handler.enter_plan_mode`）。在生产环境必须严格控制模型 prompt 注入面。

### 13.3 和同类项目的差异（对比 README 的表）

| 维度 | GenericAgent | OpenClaw / Claude Code |
|---|---|---|
| 设计心态 | **代码即文档**：Agent 能读自己源码，所以任何功能直接问它 | 预置插件/工具集 |
| 能力装载 | **运行时语义索引**：L1 30 行 → 按需读 L3 | 启动时全量装载 |
| 浏览器 | 真实浏览器 + 扩展 + CDP | 无头 / MCP plugin |
| 复杂度换算 | 1 个文本文件 ≈ 1 个能力 | 1 个 npm 包 ≈ 1 个能力 |

GenericAgent 把"Agent 能力增长"的成本从**开发者写插件**转移到了**LLM 自己写 SOP/脚本并入库**——这是它宣称"3K 行种子代码生长出专属技能树"的根本原因。

---

## 附录 A：关键代码引用

```125:125:/Users/taliszhou/code/src/github.com/GenericAgent/agent_loop.py
# agent_loop.py 总共 125 行，其中 agent_runner_loop 本体 42-99 即 ~58 行
```

```561:561:/Users/taliszhou/code/src/github.com/GenericAgent/ga.py
# ga.py 561 行覆盖 9 个工具 + Handler + 3 个辅助函数
```

```983:983:/Users/taliszhou/code/src/github.com/GenericAgent/llmcore.py
# llmcore.py 983 行，是整个项目最大的单文件，包含 5 种 Session + 2 种 Client + Mixin
```

## 附录 B：文件清单速查（核心 runtime）

| 文件 | 职责 |
|---|---|
| `agent_loop.py` | Agent 运行循环、StepOutcome 协议、BaseHandler |
| `ga.py` | 9 原子工具实现 + GenericAgentHandler |
| `llmcore.py` | LLM Session/Client 抽象、Mixin 故障转移、SSE 解析 |
| `agentmain.py` | 主进程、任务队列、mykey 热重载、task/reflect 模式 |
| `simphtml.py` | 页面 DOM 简化器（给 LLM 看的瘦身 HTML） |
| `TMWebDriver.py` | 通过 Chrome 扩展反向接管真实浏览器 |
| `assets/tools_schema.json` | 9 原子工具 JSON Schema |
| `assets/sys_prompt.txt` | 系统提示词（7 行） |
| `assets/code_run_header.py` | 注入 `code_run` 子进程的 header |
| `assets/tmwd_cdp_bridge/` | MV3 Chrome 扩展（CDP 桥） |
| `memory/memory_management_sop.md` | L0 记忆宪法 |
| `memory/global_mem_insight.txt` | L1 索引（≤30 行） |
| `memory/global_mem.txt` | L2 全局事实 |
| `memory/*_sop.md` + `memory/*.py` | L3 任务 SOP + 工具脚本 |
| `memory/L4_raw_sessions/compress_session.py` | L4 会话归档器 |
| `reflect/autonomous.py` | 空闲自主任务触发 |
| `reflect/scheduler.py` | cron 定时任务调度 |
| `plugins/langfuse_tracing.py` | 可选 Langfuse 观测（monkey-patch） |
| `frontends/*app.py` | 10 个前端适配器 |

---

**报告完**
