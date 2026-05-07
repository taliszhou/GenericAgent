# 项目方向 — 个人 fork 战略文档

> **文档编号**：TZ-GA-DIRECTION-001
> **版本**：v1.0
> **日期**：2026-05-03
> **作者**：taliszhou（与 Claude Opus 4.7 1M 在 ga-go 项目中的多轮讨论提炼）
> **适用范围**：本 fork（`taliszhou/GenericAgent`，非 upstream `lsdefine/GenericAgent`）
> **状态**：Active（取代 `docs/GO_REWRITE_PLAN_v1/v2/v3.md` 三份历史文档作为活跃路线图；那三份保留作为架构参考，不再驱动实施）

---

## 0. TL;DR

1. **放弃 ga-go**（Go 重写项目），全部精力回到本 Python fork。
2. **保留 ga-go 沉淀的设计资产**——v3 Evolution Engine 六件套（Tracer / Lessons / Replay / Shadow / Canary / Arena / MemDiff）+ Compliance Observatory 四件套（Tracer / Done Gate / Spectrum / AnchorRules）的**架构设计**值得保留并在 Python 端实现。
3. **实施路径**：分阶段把 v3 Evolution Engine 概念**用 Python 实现**到本 fork，作为"可验证框架"的物理基础，再在其上叠加个人想法。
4. **不变量**（不许动摇的红线）：短上下文、9 工具、SOP > Skill、`inline_eval` 完整 Python 灵活性、记忆只读+file_patch 写、L0 神圣性。

---

## 1. 战略决策：放弃 ga-go，回到 Python

### 1.1 决策

**2026-05-03**：放弃 `taliszhou/ga-go` 项目（Go 重写）。后续所有功能扩展、想法落地、架构演进均在本 Python fork 进行。

### 1.2 ga-go 经历的脉络（简史）

| 阶段 | 事件 |
|---|---|
| 起点 | 想用 Go 重写 GA，理由：单 binary、性能、类型安全、多并发 |
| v1 | "翻译 Python 到 Go"——意识到这把 LLM-native 立身之本砍掉 |
| v2 | 转向"为 LLM-CPU 提供可靠 runtime"，加 Compliance Observatory 4 件套 |
| v3 | 在 v2 基础上加 Evolution Engine 6 件套（Lessons / MemDiff / Replay / Shadow / Canary / Arena） |
| Stage 1.5 | Parity audit 发现：unit-shipped 多但 binary-live 少；7 个修复任务全部交付 |
| Stage 2 决策点 | inline_eval 的实现要求做 Python sidecar + RPC（4-7 周新投资）→ 触发整体反思 |
| **2026-05-03** | **决策放弃**。改回 Python fork 实施 v3 概念 |

### 1.3 放弃 ga-go 的真实原因（不是事后辩护）

**表层原因**：
- "单 static binary"卖点被 Stage 2 sidecar 杀死（Python 仍是硬依赖）
- "性能更强"被证伪（agent 是 LLM-bound 不是 CPU-bound）
- "复刻 Python"无新价值（Python 自己跑得好好的）

**深层原因**：**摩擦系数 mismatch**。
- 本人（taliszhou）的真实驱动力：**对系统有掌控感、能自由地往里塞想法**
- ga-go 路径下：每个新想法都要在 Go runtime + Python sidecar + 协议规约三处协调，摩擦系数 5-10 倍
- Python fork 路径下：1700 行 Python，下午就能验证一个想法
- 对一个"想往里塞想法"的人来说，**摩擦系数是头号杀手**

**Go 选择的真实理由**（事后承认）：
- 不是因为 Go 技术上更优
- 是因为本人熟悉 Go，**容易看懂、容易发现问题**
- 这是"思考脚手架"价值，不是"工程产物"价值
- Go 已完成了它的使命（逼我想清楚每个组件的边界），可以退役

### 1.4 不要在未来动摇这个决策

未来几个月可能出现的"诱惑"：
- "ga-go Stage 2 sidecar 那 4-7 周再坚持一下就出来了..."
- "Python 性能不够，应该用 Go..."
- "单 binary 部署确实有用..."

**反诱惑回应**：
- Sidecar 出来之后是"Python GA 的又一个壳"，新增价值不清楚
- 性能不是 agent 系统瓶颈，LLM API 延迟才是
- 单 binary 部署只是 bot 一个细分场景，那个场景未来如果真痛了，单独做个 bot 二进制 satellite 就行，不需要重写 agent core

如果再次动摇，**重读本文档 §3 的"我看重的特性，到底是 GA 哪个层的特性"**——那会让你重新意识到你看重的是 GA 的**设计**，不是 Go 的**实现**。

---

## 2. 我（taliszhou）的真实价值排序

这是本文档最重要的一节。未来任何技术决策都要回到这张表对账。

### 2.1 我看重 GA 的两个核心特性（自我披露 2026-05-03）

**特性 A：与 LLM 交互的上下文非常短**

- 价值：让本地化部署的 LLM 服务（Qwen / Llama 7B-32K 等弱模型）也能跑实用 agent
- 反例：OpenClaw、Hermes Agent 这类框架因上下文撑爆 LLM provider 而崩溃
- 这不是品味偏好，**是技术必需**——决定了我能不能用本地模型

**特性 B：自进化 + SOP 优于 Skill**

- 价值：SOP 把决策路径外化为可读、可版本化、可 diff 的文档
- 对比 Claude Skills / OpenAI Functions 那套"给工具自己想办法"——后者依赖 LLM 自由发挥，结果分布宽
- SOP 的 step-by-step 形式，**重跑结果分布窄**——这正是"可验证"的物理基础
- 我认同原作者的设计哲学

### 2.2 真实驱动力（行为反推）

- 想要**对系统有掌控感**（自己 fork、自己改、自己懂每一行）
- 想要**自由地往里塞想法**（低摩擦实验通道）
- 想要"**自己的轮子**"——但本质是要一个**有 agency 的基底**，不是一定要从零造
- 想要**可验证的框架**——指 v3 Evolution Engine 那种"observability + 可回溯 + 可对标"的整体能力

### 2.3 不在意的（防止被诱惑）

- 部署形态（单 binary 还是 Python venv 都接受）
- 启动速度（agent 任务时间尺度是分钟级，启动 100ms 还是 500ms 不重要）
- 工程语言时尚度（Go vs Python 的"现代感"无关）
- 对外能力宣传面（不需要"全能 agent"标签，只需要自己能用得爽）

### 2.4 决策对账模板

未来任何技术选型 / 架构决策，先过这张表：
- [ ] 这个改动**保护**特性 A（短上下文）吗？还是会撑大上下文？
- [ ] 这个改动**保护**特性 B（SOP 可验证性）吗？还是会让结果分布变宽？
- [ ] 这个改动**降低**还是**增加**我"塞新想法"的摩擦系数？
- [ ] 我做这个是为了真实需求，还是被外界"应该"叙事推着走？

---

## 3. 从 ga-go 沉淀的设计资产（要继续用的部分）

ga-go 的代码不再维护，但其**设计文档**是有价值的，因为：
1. 它把 v3 Evolution Engine 想清楚了（Python 上游没有同等深度的设计）
2. 它产生了"binary-live vs unit-shipped"的方法论红线
3. 它产生了完整的 Python ↔ Go 行为对账表（顺带是 Python 上游的行为索引）

### 3.1 v3 Evolution Engine 六件套（要在 Python 实现）

详细架构在 `docs/GO_REWRITE_PLAN_v3.md`（已 copy 进本 fork docs 目录）。一句话回顾：

| 子系统 | 作用 | Python 实现路径建议 |
|---|---|---|
| **Lessons Compiler** | session 结束扫 trace 产出 1-5 条 markdown 草稿到 `memory/.lessons/drafts/` | 一个 Python 类，挂在 agentmain 的 turn_end / loop_exit 路径上 |
| **Memory Diff** | `memory/` 自动初始化 git repo；每次 `file_patch` 自动 commit | GitPython 库（或直接 subprocess git）；hook 进 `do_file_patch` 之后 |
| **Replay Pool** | L4 会话存 fingerprint.json；新任务用关键词 Jaccard 召回相似历史 | Python 端写 fingerprint/outcome.json；新会话开头算 Jaccard，最高分 ≥0.4 注入 hint |
| **Shadow Runner** | 高风险操作（改 L1、`rm -rf` 等）前起 subagent 沙盘预演 | 复用现有 subagent 协议，加一个 dispatcher 在 do_file_patch / do_code_run 前 |
| **Canary Controller** | SOP 修改后 5 次/24h 内 compliance 退化 ≥ 20% → 提醒（不自动回退） | 简单状态机，跟 Tracer 配合 |
| **Arena** | bench 任务集；`agentmain.py --bench` 子命令；JSON 报告对比 | `bench/tasks/*/{task.md, fixtures/, expect.md}`；新增 entry point |

### 3.2 Compliance Observatory 四件套（要在 Python 实现）

Python 上游已经有 `_done_hooks` 和 `_turn_end_hooks` 等扩展点，可以构造：

| 子系统 | Python 实现路径 |
|---|---|
| **Tracer** | 一个 hook，记录每轮的 tool_call/result/tokens 到 `temp/compliance/<sid>/trace.json` |
| **Done Gate** | 检测器：FileWriteWithoutRead / CodeRunUnverified / PlanClaimsComplete；触发 next_prompt 追加 nudge |
| **Spectrum** | 按工具名统计 calls/errors/retries/unique_paths |
| **AnchorRules** | 简短 rule 文本插入 next_prompt（每轮 ≤ 2 条；总 advisory ≤ 200 tokens） |

### 3.3 红线（继承自 ga-go 设计、加进本 fork）

不可违反的"反向红线"，违反任一即设计跑偏：

1. **不自动合并 Lesson 到 L1**（drafts 永远只在 `.lessons/drafts/`）
2. **Shadow / Canary 默认 advisory 不拦截**
3. **per-turn advisory 累加 ≤ 200 tokens**
4. **不新增第 10 个原子工具**
5. **每个新功能都必须可被关掉**（`--no-lessons` / `--no-shadow` 等 flag），关掉后退回 baseline 行为
6. **"binary-live vs unit-shipped" 区分**：单元测试通过 ≠ 任务完成；必须有 entry point 端到端可观察的证据

### 3.4 ga-go 设计文档索引（参考用，不再维护）

如果将来想看具体设计细节，去这些文件：

| ga-go 路径 | 内容 |
|---|---|
| `/Users/taliszhou/code/src/github.com/taliszhou/ga-go/docs/GO_REWRITE_PLAN_v3.md` | v3 完整架构（Evolution Engine 六件套详细设计） |
| `/Users/taliszhou/code/src/github.com/taliszhou/ga-go/docs/IMPLEMENTATION_PLAN.md` | v3 落地的 60 个任务分解（任务粒度参考） |
| `/Users/taliszhou/code/src/github.com/taliszhou/ga-go/docs/PARITY_AUDIT_AND_FIX_PLAN.md` | binary-live vs unit-shipped 的红线案例 + parity scenarios 设计 |
| `/Users/taliszhou/code/src/github.com/taliszhou/ga-go/docs/research/01-code-run-architecture.md` | Python `code_run` / `inline_eval` 的完整解剖（即上游 ga.py 的行为参考） |
| `/Users/taliszhou/code/src/github.com/taliszhou/ga-go/docs/research/02-go-port-tensions.md` | 跨语言移植的张力分析（已被 03 部分推翻，仅作历史参考） |
| `/Users/taliszhou/code/src/github.com/taliszhou/ga-go/docs/research/03-inline-eval-implementation.md` | `inline_eval` 的 sidecar 设计（Python 端不需要这个，但分析过程有价值） |
| `/Users/taliszhou/code/src/github.com/taliszhou/ga-go/bench/parity/scenarios/` | 13 个 parity 场景（scenario 写法可借鉴） |

**重要**：本 fork 的所有新工作不应再依赖 ga-go 仓库；上面只是"灵感和细节查询"用途。

---

## 4. 本 fork 的前进路线图

### 4.1 心态调整

- **写代码先于写规范**：Python 改起来快，先 prototype 跑通，再补 SOP 和文档
- **小步迭代**：每个想法 1-3 天验证，不做超过 1 周的设计-不-跑代码
- **保留个人 commit messages 自由度**（不需要严格的 conventional commits）
- **upstream sync 节奏**：每月一次 `git fetch upstream && git merge upstream/main`，关注 lsdefine 是否有新机制可借鉴

### 4.2 实施阶段（建议性，不强制顺序）

#### 阶段 1：MemDiff（最低投入回报最高）

- **工作量**：1-2 天
- **做什么**：
  - `memory/` 启动时自动 `git init`（如果没有 .git）
  - 在 `ga.py:do_file_patch` 和 `do_file_write` 写入成功后，自动 `git add . && git commit -m "[auto] <session>:<turn> <tool> <path>"`
  - 加 3 个 inline_eval 白名单函数：`memory_log(path)` / `memory_diff(path, n)` / `memory_revert(path, n)`（最后一个走 ask_user 确认）
- **价值**：立即获得"记忆改动可追溯、可回退"——这是后续所有 Evolution 子系统的基础

#### 阶段 2：Tracer + Lessons Compiler

- **工作量**：3-5 天
- **做什么**：
  - 实现 Tracer：每轮记录 tool_calls / tool_results / token usage 到 `temp/compliance/<sid>/trace.json`
  - 实现 Lessons Compiler：session 结束后扫 trace，按启发式（连续工具失败 / SOP 步骤跳过 / Done Gate 触发等）产出草稿到 `memory/.lessons/drafts/<date>-<sid>.md`
  - 在 sys_prompt 增加"Recent Lessons drafts pending: N"hint（≤ 30 tokens）
- **价值**：开始建立"可观测 → 可回顾"循环；每次 session 都在产可被自己读的 lessons

#### 阶段 3：Replay Pool

- **工作量**：3-5 天
- **做什么**：
  - L4 archive 时同时写 fingerprint.json（task summary + keywords + outcome）
  - 新会话开头算 Jaccard 相似度，top-1 ≥ 0.4 时注入"Replay hint: 7 天前的 sess-XXX 与当前任务相似（命中 5/7 关键词），outcome=DONE，可 file_read transcript.md 查阅"（≤ 100 tokens）
- **价值**：跨会话经验复用；与 Lessons 互补

#### 阶段 4：Done Gate + AnchorRules

- **工作量**：3-5 天
- **做什么**：
  - 在 `turn_end_callback` 加几个检测器：file_write 没先 file_read 过、code_run 后没验证 exit code、claim "完成" 但未触发 verify SOP
  - 触发时在 next_prompt 追加 [RULE] nudge
- **价值**：把 Python 上游已有的 turn_end DANGER 注入机制扩展为可配置规则集

#### 阶段 5：Arena bench

- **工作量**：5-10 天
- **做什么**：
  - `bench/tasks/*/` 目录格式：task.md + fixtures/ + expect.md
  - `agentmain.py --bench` 子命令：跑所有 task，输出 JSON
  - `--bench --compare-to <prev.json>` 做 diff
  - 录 10-20 个真实场景作为 baseline
- **价值**：任何 SOP 修改都有"绝对对标"；防止 LLM 升级导致的静默退化

#### 阶段 6+：Shadow / Canary / 你自己的想法

- 阶段 1-5 是地基；地基稳了之后，你的"想塞的想法"就有可验证的实施基底了
- Shadow 和 Canary 复杂度高、收益边际递减，按需实施
- 你自己的新想法（暂未列出）按"§2.4 决策对账模板"过一遍再做

### 4.4 专属 agent 整合方向（正向目标）

> 你的核心动机是"打造属于自己的专属 agent"——把常用工具一站式整合进 launcher。本节列出已识别的整合方向。具体优先级由你按当时的痛点排序。

#### 4.4.1 当前 launcher 形态梳理

upstream 目前有两个 GUI 入口，定位不同：

| 文件 | 定位 | 整合范围 | 启动模型 |
|---|---|---|---|
| `launch.pyw` | "用 agent" — webview 包装 Streamlit chat + 旁路启 bot | tg / qq / feishu / wecom / dingtalk / sched | 关窗即停（chat session 寿命） |
| `hub.pyw` | "管 agent" — tkinter 服务管理面板 | 自动发现 reflect/* + frontends/*app* | 单例锁；输出 ring buffer；关窗 stop_all |
| `start_wechat.sh` | "wechat daemon 化" — 独立 bash 管理脚本 | 仅 wechat | nohup + PID 文件，**完全脱离 GUI** |

**为什么 wechat 不在前两者里**（详细见本次讨论分析）：
- iLink 协议（非官方），首次必须扫码 + 手机确认
- token.json 凭证管理 + relogin 重扫码运维需求
- 需要 24/7 daemon，不能跟 GUI 寿命绑定
- 端口 19531 与 wecomapp 冲突，不能并存
- HTTPS_PROXY 必须 unset；UA 必须伪装；依赖 pycryptodome 等重型包
- 失败成本高（封号），运维操作要谨慎

**这是有意识的架构分割，不是疏忽**。整合前要想清楚：你是想（a）把 wechat 也降级为"chat session 期间的 bot"——则要接受关窗即停的语义；或（b）保留 daemon 模型，只在 launcher 里加一个"启停 wechat daemon"的按钮——按钮调 `start_wechat.sh start/stop`，UI 与进程解耦。**(b) 更合理**。

#### 4.4.2 整合方向候选（不强制顺序）

每条由你按当时痛点决定先做哪个：

**A. 统一 launcher**（合并 `launch.pyw` + `hub.pyw` + wechat 的优点）
- 一个 GUI，下边 chat 区（streamlit），上边服务管理区（hub.pyw 风格）
- wechat 作为"daemon 控制面板"项：启动按钮触发 `start_wechat.sh start`，stop 按钮触发 `stop`，状态行显示 PID + token 状态——UI 独立于 wechat 进程
- 其他 bot 维持"跟 launcher 寿命绑定"的简单模型（节约首次扫码这种复杂度）
- reflect 任务自动发现（沿用 hub.pyw 逻辑）
- 工作量预估：2-3 天（在 launch.pyw 上加 service 管理面板）

**B. 个人工具盒整合**
- 把你日常用的任意 Python 脚本 / shell 命令 / 网页快捷方式都注册成"服务"或"工具"
- 服务（长跑）：进 hub.pyw 面板
- 工具（一次性）：注入 chat 当 inline_eval / code_run 调用
- 类似"个人 SOP 库 + 工具集"的私人版
- 工作量预估：取决于工具数量

**C. 与 Evolution Engine 联动**
- launcher 里展示当前 session 的 trace（与 Tracer 联动）
- Lessons drafts 数量 badge（与 Lessons Compiler 联动）
- Memory git log 查看面板（与 MemDiff 联动）
- Arena bench 一键跑 + 结果对比图（与 Arena 联动）
- 工作量预估：跟 §4.2 对应阶段一起做

**D. 桌面体验优化** ✅ **v1 完成 2026-05-03**
- ✅ 全局热键唤起 chat（默认 Cmd+Shift+Space）
- ✅ 系统托盘常驻（点击 Show/Hide/Snap to edge/Always on top/Quit）
- ✅ 边缘吸附（默认右边）+ 失焦自动隐藏（snap-aware）
- ✅ chat input 焦点保护（打字时不会自动隐藏）
- ✅ idle injection 整合（30 分钟无回复自动唤窗 + 注入自主任务）
- 实施文档：[`DESKTOP_UX_PLAN.md`](./DESKTOP_UX_PLAN.md)
- 用户文档：[`DESKTOP_UX_USAGE.md`](./DESKTOP_UX_USAGE.md)
- ⏳ 跨设备消息同步——v2 路线图，待 WebUI 主入口稳定后做

#### 4.4.3 整合的硬约束

不管走哪个方向，必须守住的不变量（违反就退回 §2.4 对账）：
- **特性 A 不破**：UI 增加的功能不能让每轮 advisory > 200 tokens（单纯 GUI 渲染不影响 LLM 上下文，所以这条主要约束 hint 注入类功能）
- **特性 B 不破**：UI 不能给 LLM 新的"自由发挥"决策点；所有 LLM 行为仍然由 SOP 驱动
- **wechat 不绑死**：daemon 进程必须能独立于 launcher 运行；launcher 只是"控制器"
- **服务发现不要硬编码**：沿用 hub.pyw 自动扫盘风格，加新 reflect/bot 不需要改 launcher 代码

### 4.3 需要保留的现有 fork 工作

`git log` 显示你最近在做：
- `peer_hint mechanism & history folding compression`（commit 95a7aec）
- `compress_history_tags` 改进（e66473f）
- `_pending_tool_ids` orphan tool_result 修复（de24f0b）

这些是有价值的本地改进，**不要因为本文档的方向调整而废弃**。它们和 v3 Evolution Engine 是叠加关系，不冲突。

---

## 5. 反向红线（不许做的事）

不再重复 ga-go 那 5 条（已在 §3.3 列）。本节是**针对本 fork 自己**的。

### 5.1 不许做的技术动作

- **不许把 inline_eval 改成白名单**——你已经决策"完美保留 Python 灵活性"，这是承重墙
- **不许加第 10 个原子工具**——保持 9 工具决策空间
- **不许让 advisory 文字超过每轮 200 tokens**——会撑爆短上下文优势（这是你最看重的特性 A）
- **不许在 Lessons / Replay 实现里加"自动合并到 L1"路径**——草稿永远是草稿
- **不许搞"Python 性能不够要换 Go"那一套话术**——agent 不是 CPU-bound

### 5.2 不许做的范围扩张

- **不许做"全平台 bot"目标**（除非真的痛了）——现有几个 IM 平台够用
- ~~不许做"完美 web UI"目标~~ —— **撤销**。整合常用工具打造专属 agent **是核心目标**，详见 §4.4
- **不许做"完整 OpenAI 兼容 API server"**——agent 不是 LLM 网关
- **不许试图取代 Cursor / Continue 等 IDE agent**——定位不同

### 5.3 不许做的心态扩张

- **不许把这个 fork 当"商业产品"做**——做不动，会让你失去 hobby 价值
- **不许追"100 star / 1000 star"目标**——upstream 已经有用户群
- **不许期待"被外部用户大量使用"**——本 fork 是个人定制，不是公共项目
- **不许重复"我应该用 Rust / Bun / Mojo"等"语言诱惑"**——你的瓶颈不在语言

---

## 6. 与 upstream 的关系

### 6.1 维持原则

- **upstream 优先**：upstream lsdefine/GenericAgent 有新功能、修了 bug，每月 sync 一次
- **本 fork 增量**：只在 upstream 之上叠加 v3 Evolution Engine 和你的个人想法
- **不主动 PR 回 upstream**：除非 upstream 作者主动要某个特性。你的改动定位是"个人增强"，不需要承担"通用化、向后兼容"的设计成本

### 6.2 冲突处理

如果 upstream 的某次提交与你的 Evolution Engine 实现冲突：
- 优先尊重 upstream 的方向（作者比你更懂 GA 的整体哲学）
- 自己的实现做适配，不要 revert upstream
- 如果适配成本巨大 → 重新评估"这个 Evolution 子系统是否真的有用"

### 6.3 不要做的事

- **不要 fork 后再 fork 散布**（保持本 fork 是你个人专用，避免维护负担）
- **不要在 README 里宣称"this is a better GA"**（不是。是"我自己用着舒服的 GA"）

---

## 7. 决策记录

未来再做重要技术决策时，按以下格式追加到本文档末尾：

```
## 决策记录 N — YYYY-MM-DD <短标题>

**问题**：xxx
**选项**：A: xxx / B: xxx / C: xxx
**决策**：选 <X>
**理由**：xxx
**与 §2.4 对账**：[√/×] 保护特性 A / [√/×] 保护特性 B / [√/×] 降低摩擦 / [√/×] 真实需求
```

### 决策记录 1 — 2026-05-03 放弃 ga-go

**问题**：是否继续 ga-go（Go 重写项目）？
**选项**：A. 继续 Stage 2 sidecar 实施 / B. 转为 Go 卫星定位（只做 bot+observability） / C. 完全放弃
**决策**：C（完全放弃）
**理由**：见本文档 §1。核心是"摩擦系数"——Go 双语言架构让"塞新想法"成本上升 5-10 倍，与本人真实驱动力背离
**与 §2.4 对账**：[√] 保护特性 A（Python GA 自己就保护短上下文） / [√] 保护特性 B（SOP 系统不变） / [√√] 降低摩擦（核心收益） / [√] 真实需求（"塞想法"是真实需求）

---

## 8. 文档版本历史

- **v1.0 (2026-05-03)**：首版。基于 2026-05-02/03 与 Claude 在 ga-go 项目中的多轮战略讨论提炼。决策放弃 ga-go、确立 Python fork 为主战场、列出 v3 Evolution Engine 的 Python 实施阶段、固化个人价值排序作为未来对账基线。

---

> **致未来的 taliszhou**：当你下次又开始想"是不是应该用 Go / Rust / Bun 重写"的时候，先回到 §2 重读你的真实价值排序。如果那张表还没变，你的工具就还没找错。
> 当你下次又开始想"加个新工具/扩个新平台/做个 Web UI"的时候，先回到 §5.3 看看你是不是又在扩张范围。
> 工具是为你服务的，不是反过来。
