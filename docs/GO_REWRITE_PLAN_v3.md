# GenericAgent → Go 重写实施方案 v3

> **文档编号**：GA-GO-003
> **版本**：v3.0
> **日期**：2026-05-02
> **变更说明**：在 v2 (Compliance Observatory) 基础上，围绕 GA 的**自进化核心招牌**重新构造的版本。v3 引入"Evolution Engine"作为第五个架构层，把 v2 留在"被动观察"层面的观测数据，升级为**带安全网的自改进闭环**。
> **前置阅读**：v1 `docs/GO_REWRITE_PLAN.md`、v2 `docs/GO_REWRITE_PLAN_v2.md`、作者自分析 `ga_architecture_analysis(2).md`、代码级调研报告 `GenericAgent_代码级调研报告.md`

---

## 0. v3 修订摘要

### 0.1 v2 的成就与盲点

v2 完成了一次关键认知升级：**从"翻译 Python 到 Go"转向"为 LLM-CPU 提供可靠 runtime"**。撤销了 5 项与 LLM-native 理念冲突的伪改进，新增 4 项 compliance 观测机制（Tracer / Gate / Spectrum / AnchorRules）。

但 v2 的 compliance 四件套**停留在"让人类发现问题"**这一层，并未解决 GA 的**真正独特能力**——自我进化。具体盲点：

| 盲点 | v2 的状态 | v3 要解决的问题 |
|---|---|---|
| **自进化闭环未工程化** | `start_long_term_update` 只是一个工具，靠 LLM 自觉触发 | 把"从失败中学习"升级为**可观测、可回放、可 A/B 比较**的工程系统 |
| **观测数据不反哺 Agent** | Compliance trace 写到 JSON，给人类看 | Trace 自动派生 "Lessons" 喂回下次启动的 L1，形成**经验跨会话传递** |
| **记忆修改单向且无反馈** | LLM 写 L3 后，不知道是否真的让后续任务变好 | 每次记忆写入打上**可追溯 ID**，后续任务命中该记忆时回采**效用指标** |
| **L4 原始会话只是仓库** | 写入后基本不被读 | 升级为**经验回放池**：相似任务到来时，自动从 L4 召回过去相关的执行轨迹作为参考 |
| **无"假想 / 沙盘"模式** | 所有 plan 都是实战产出 | 新增 **Shadow Run**：高风险操作前先在沙盘跑一遍 subagent，对结果做事前预测 |
| **缺"多 SOP 版本并存"能力** | SOP 修改即生效，无回退 | SOP 变更走 **git-style diff + canary**，坏版本可一键回退 |

### 0.2 v3 的核心主张

> **v3 = v2 的 Compliance Observatory + 一个闭环"Evolution Engine"**

- v2 回答了"LLM 错在哪里能被看见"
- v3 回答了"看见之后怎么形成**带安全网的自动改进**"，同时**不违背**作者"代码层不自动改 SOP/记忆"的红线

这个看似矛盾的命题的解法是：**代码层不自动改记忆，但代码层可以"组织好一个让 LLM 自己改得更安全、更有证据、更可回退"的舞台**。Evolution Engine 是舞台，LLM 仍是唯一的编剧和演员。

### 0.3 v3 新增架构层（第五层）

```
┌─────────────────────────────────────────────┐
│ 记忆层（硬盘）                                │  ← 只读读，写仍走 file_patch
├─────────────────────────────────────────────┤
│ SOP 层（LLM 上的软代码）                      │  ← 对 Go 完全透明
├─────────────────────────────────────────────┤
│ 代码层（Go 硬代码）                           │
├─────────────────────────────────────────────┤
│ 观测层（v2 引入）                             │  ← 不改行为，只记录
├─────────────────────────────────────────────┤
│ 进化层【v3 新增】                             │  ← 组织闭环，不做决策
│   Lessons / Replay / Shadow / Canary /      │
│   Arena / Memory-Diff                       │
└─────────────────────────────────────────────┘
```

**进化层的四条铁律**（v2 三原则的延伸）：

1. **代码组织过程，LLM 做出决策**。一切 SOP/L1 的变更依然由 LLM 发起，代码只提供"diff/staging/canary/rollback"这些 DevOps 级机制。
2. **每次记忆改动都是可撤销的、可追溯的、可比较的**。记忆变成 git-style 仓库。
3. **没有"自动学习"。只有"便于学习"**。代码不从 trace 自动生成 SOP，但代码把 trace 格式化为 LLM 下次能读懂的"Lessons 草稿"。
4. **进化是带评估的**。任何 SOP 版本上线后，有 N 次或 M 小时的 canary 观察期；期间表现退化则自动提醒 LLM（而非回滚）重新评估。

---

## 1. v1→v2→v3 演进路线

```
v1 "翻译工程"
    │  意识到：把工程思维硬套到 LLM-native 架构上会砍掉它的立身之本
    ▼
v2 "可靠 runtime + 被动观测"
    │  意识到：观测数据停留在日志里，没有形成改进闭环
    │  意识到：GA 真正的独特价值是"自进化"，v2 对此没工程化
    ▼
v3 "可靠 runtime + 闭环进化引擎"
```

对应到作者的"LLM-CPU + SOP + 记忆"类比：

| 版本 | Go 扮演的角色 |
|---|---|
| v1 | 给 CPU 换个更快的主板（错，CPU 瓶颈不在主板） |
| v2 | 给 CPU 配好散热+电源监控+总线示波器（对，可靠 runtime） |
| v3 | **v2 的一切 + "版本控制 + CI/CD + 实验台"**，让 CPU 跑的软件（SOP）能像人类代码一样演进 |

---

## 2. Evolution Engine 设计（v3 核心）

Evolution Engine 由 6 个协作子系统组成：

```
  ┌─────────────────────────────────────────────────────────────┐
  │                   Evolution Engine                           │
  │                                                              │
  │  ┌──────────┐  ┌───────────┐  ┌─────────────┐               │
  │  │ Lessons  │  │  Memory   │  │  Canary     │               │
  │  │ Compiler │←─│   Diff    │─→│  Controller │               │
  │  └──────────┘  └───────────┘  └─────────────┘               │
  │       │             ↑                │                       │
  │       ▼             │                ▼                       │
  │  ┌──────────┐  ┌───────────┐  ┌─────────────┐               │
  │  │ Replay   │→ │  Shadow   │←─│  Arena      │               │
  │  │ Pool     │  │  Runner   │  │  (bench)    │               │
  │  └──────────┘  └───────────┘  └─────────────┘               │
  └─────────────────────────────────────────────────────────────┘
         ↑                                      ↓
   从 v2 Tracer/Gate/Spectrum/AnchorRules 读数据
                                          向 LLM 下一次会话注入
```

### 2.1 Lessons Compiler —— 跨会话经验传递

**要解决什么**：v2 的 compliance trace 写到 `temp/compliance/<session>/*.json`，下次会话完全不看。人类能从 Grafana 面板看到规律，LLM 自己反而不知道"昨天我在 web_execute_js 上栽过跟头"。

**v3 方案**：Lessons Compiler 在**会话结束时**扫过该 session 的所有 trace，用**启发式规则**产出 1-5 条"Lesson 草稿"，写入 `memory/.lessons/drafts/YYYY-MM-DD-sess-xxx.md`。

**关键：它是草稿，不是生效的记忆**。

```go
// internal/evolution/lessons.go
type LessonsCompiler struct {
    tracer  compliance.Tracer
    gate    compliance.DoneGate
    spec    compliance.Spectrum
    out     string  // memory/.lessons/drafts/
}

type LessonDraft struct {
    SessionID     string
    Category      LessonCategory  // sop_violation / done_premature / low_verify / tool_error_pattern
    Evidence      []TraceRef
    SuggestedText string          // 建议追加到 L1 [RULES] 或某个 SOP 的候选文字
    Score         float64         // 该 lesson 的"值得关注度"
}

func (c *LessonsCompiler) OnSessionEnd(ctx context.Context, sid string) {
    traces := c.tracer.SessionTraces(sid)
    drafts := []LessonDraft{}

    // 规则 1：SOP 声明完成但未 VERIFY
    if c.gate.HasPrematureDone(sid) {
        drafts = append(drafts, LessonDraft{
            Category: DonePremature,
            SuggestedText: "[RULE] 声称完成前必须用 file_read 回读产物或 subagent 验证",
            ...
        })
    }
    // 规则 2：同一工具连续 N 次失败
    if errs := c.spec.RepeatedToolErrors(sid, n=3); len(errs) > 0 {
        ...
    }
    // 规则 3：某 SOP 声明了步骤但 trace 显示跳过
    for _, skipped := range c.tracer.SkippedSteps(sid) {
        ...
    }

    // 写入草稿文件夹，不合并到 L1/L3
    writeDrafts(c.out, sid, drafts)
}
```

**如何进入"生效"**：下次 LLM 启动时，**L1 自动附加一个小段**：

```
[Recent Lessons Drafts] memory/.lessons/drafts/ 下有 3 条待审阅
如果当前任务与其中任何一条相关，建议 file_read 查看并决定是否 file_patch 到 L1/SOP
```

**就这一句**。不强制读，不自动合并，不自动改 L1。LLM 判断相关就去读，判断无关就忽略。

**收益**：
- LLM 在新会话开头**被提醒**"你过去犯过错"，提高下次遵从度
- 草稿累积 → 人类也能看到，判断哪些该人工 merge 进 L1
- 严格遵守 §1.3 第一条：代码不强制、不替 LLM 决策

**成本**：每次会话末 ~50 行代码扫 trace，输出 <1KB markdown；L1 注入增加 ~30 tokens。

### 2.2 Memory Diff —— 把记忆变成 git 仓库

**要解决什么**：
1. `file_patch` 只保证单次修改是唯一匹配的，但**连续多次修改**会越改越乱（某次改错了无从回退）
2. v2 §3.2 说"记忆只读、修改走 file_patch"，但 file_patch 没有版本概念
3. 无法回答"这个 SOP 上周和这周差别大吗？"

**v3 方案**：`memory/` 目录在 Go 版启动时**自动初始化为一个内嵌 git repo**（或使用 `go-git` 在后台维护），每次 `file_patch` / `file_write` 写入 `memory/*.md` 时：

1. 写前 `git add -A && git stash` 保存快照
2. 写入
3. 写后自动 `git commit -m "[auto] agent patch <file> by <session>"` 带上 session id 和工具调用 index

**暴露给 LLM 的能力**：

```
新工具（或 code_run 白名单）：
  memory_log(path)       列出某文件的改动历史
  memory_diff(path, N)   看最近 N 次 diff
  memory_revert(path, N) 回到 N 次前（需要 ask_user 确认）
```

**关键设计**：
- Git repo **完全在 Go 后台维护**，LLM 不需要懂 git 命令
- `memory_revert` 的 `ask_user` 强制确认，防止误回退
- 每次 commit 自动打 tag `session-<id>-turn-<n>`，可按会话回溯
- 提供 `ga memory log / diff / revert` CLI 让人类维护者也能用

**对应 v2 红线**：
- ✅ L0 "神圣不可删改性" —— git 本身就是"可回溯"的最强保证，甚至比"不删"更稳妥
- ✅ "代码不自动改记忆" —— git 只在 LLM 已经决定写的时候做快照，不主动改内容

**实现量**：`go-git` 上手快，~200 行代码包住。

### 2.3 Replay Pool —— 把 L4 从"档案"升级为"案例库"

**要解决什么**：Python 版 `memory/L4_raw_sessions/` 只是按月归档，没有结构化元数据，无法被 LLM 有效召回。

**v3 方案**：所有会话结束时，在 L4 存 3 份产物：

```
memory/L4_raw_sessions/2026-05/sess-abc123/
  ├── transcript.md         # 人类可读摘要（原有）
  ├── fingerprint.json      # 【新】任务指纹
  ├── trace.json            # 【新】完整 compliance trace
  └── outcome.json          # 【新】结果评估
```

**fingerprint.json 结构**：

```json
{
  "task_summary": "用户要求修改 wechat bot 使支持图文混发",
  "entry_tools_used": ["file_read", "file_patch", "code_run"],
  "sops_consumed": ["plan_sop", "wechat_sop"],
  "keywords": ["wechat", "bot", "图文", "file_patch", "python"],
  "hash": "sha256:...",
  "turns": 42,
  "llm_tokens": {"input": 120000, "output": 8500, "cached": 65000}
}
```

**outcome.json 结构**：

```json
{
  "exit_reason": "CURRENT_TASK_DONE",
  "user_intervention_count": 2,  // /stop + /intervene 次数
  "gate_trips": 1,
  "compliance_scores": {"plan_sop": 0.85, "wechat_sop": 0.92},
  "subjective_label": null      // 可由用户事后 ga label <sid> success/fail
}
```

**召回机制**（LLM 新任务开始时）：

```
[Replay Hint] 检测到当前任务与 sess-abc123 (7 天前) 相似（keywords 命中 5/7）。
该会话 outcome: CURRENT_TASK_DONE，compliance 0.88。若相关可 file_read 查阅：
  memory/L4_raw_sessions/2026-05/sess-abc123/transcript.md
```

**关键**：
- 相似度只用**关键词 Jaccard** 或 embedding（用本地 bge-small 级小模型或直接 keywords Jaccard，不依赖 LLM）
- 只提示最相似的 1-2 个过去会话，不做多选
- 又是"草稿式提醒"——LLM 判断相关就读

**为什么这是"自进化"**：没有机器学习模型，没有自动 SOP 生成。但**经验通过被提醒**而跨会话传递——相当于给 LLM 配了"长期记忆检索"，但是**人工可审计、可删除、可关闭**的版本。

### 2.4 Shadow Runner —— 高风险操作的沙盘预演

**要解决什么**：v2 §6.2 Done Gate 是"事后发现未验证"。但更多损失发生在"**事前没想清楚**"——一个 `file_patch` 改了 10 处，一个 `web_execute_js` 点了危险按钮。

**v3 方案**：对**标记为高风险**的工具调用，先在影子环境跑一遍。

**高风险判定**（都是启发式，可关闭）：

- `file_patch` 涉及 `memory/global_mem_insight.txt` 或 `*_sop.md`
- `code_run` 包含 `rm -rf` / `DROP TABLE` / `os.kill` / `requests.post` 等敏感关键词
- `web_execute_js` 在首次使用某站点时
- `file_write` 目标路径在 `L4_raw_sessions/` 或 `.git/`

**Shadow 流程**：

```
LLM 决定调用 file_patch memory/global_mem_insight.txt
  ↓
Shadow Runner 先 fork 到一个 subagent
  ↓
让 subagent 回答三个问题：
  1. 这次修改会让 L1 超过 30 行硬约束吗？
  2. 被删/替换的内容是否包含原来的 [RULES]？
  3. 改动后的 L1 对常见 10 个场景的 recall 是否下降？
  ↓
Shadow 报告回 main session（文本形式）
  ↓
Main session 的下一轮 prompt 附加 "Shadow Report" 段
  ↓
LLM 自行判断是否修改方案
```

**关键设计**：
- Shadow 是**提示**而非**拦截**——LLM 可以看完 Shadow 报告后坚持原方案
- Shadow 的预算严格限制（单次 ≤5 turns，≤10k tokens），避免递归
- 默认**只对"改记忆"**开启 Shadow（风险最高 + 审阅收益最大）
- 用户可 `--no-shadow` 关闭整个系统

**区别于 v2 Done Gate**：
- Done Gate 是**完工后检查**
- Shadow 是**动工前预演**
- 两者互补，不重复

### 2.5 Canary Controller —— SOP 变更的金丝雀期

**要解决什么**：LLM 决定修改一个 SOP（比如给 `plan_sop.md` 加一条新规则）→ 立即生效 → 下次任务就跑在新规则上 → 如果新规则有问题，不知道是新规则的锅还是其他原因。

**v3 方案**：SOP 文件引入 **canary 状态机**。

**状态机**：

```
  stable ──[LLM 写入改动]──→ canary(cool=24h, uses=5)
    ↑                              │
    │                              │ 期内 compliance 不退化
    │                              ▼
    └─────── promote ──────────── watch
                                    │
                                    │ 期内 compliance 显著退化
                                    ▼
                                  flagged（提醒 LLM 审阅）
```

**Canary 怎么工作**：
1. LLM 用 `file_patch` 改 SOP → Git 自动提 commit → 打标签 `canary-<sop>-<sha>`
2. 改动期间（5 次使用或 24 小时），compliance trace 被**单独统计到 canary 分组**
3. 若 canary 组的 compliance 分数比前 20 次（stable 期）均值低 **≥20%**，自动生成 `memory/.lessons/drafts/canary-<sop>.md`：
   ```
   [CANARY WARN] plan_sop.md 在 5 次使用内，VERIFY 步骤的执行率从 0.9 降到 0.4。
   请 memory_diff plan_sop.md 1 查看改动，决定是否 memory_revert
   ```
4. 通过则 `stable`，同时清除 canary tag

**关键**：
- 代码**永远不自动回滚**，只"打警告灯"
- 回滚与否由 LLM 判断（或人类）
- Canary 只覆盖 SOP 变更，不覆盖 L1/L2（L1 变更即 RULES 变更，影响太广，直接走人工审）

### 2.6 Arena —— 离线基准测试集

**要解决什么**：我们怎么知道"这周的 SOP 比上周好"？Compliance 分数可能因为任务变难而降低，不是 SOP 变差。

**v3 方案**：维护一个小而稳定的"benchmark task set"。

```
ga/bench/
  ├── tasks/
  │   ├── 001-fix-readme-typo/
  │   │   ├── task.md            # 任务描述（当作用户 prompt）
  │   │   ├── fixtures/          # 预置文件
  │   │   └── expect.md          # 成功条件
  │   ├── 002-run-subagent-parallel/
  │   ├── 003-plan-multi-step/
  │   └── ...
  └── README.md
```

**`ga bench run`** 跑完所有 benchmark task，输出：

```
$ ga bench run --llm gpt-5.4 --sop-version git:HEAD
Running 20 tasks...
 ✓ 001 fix-readme-typo       (turns=3,  tokens=1.2k, compliance=1.00)
 ✓ 002 subagent-parallel     (turns=8,  tokens=3.4k, compliance=0.92)
 ✗ 003 plan-multi-step       (turns=15, tokens=8.1k, compliance=0.58, verify_skipped)
 ...
Summary: 17/20 pass, avg compliance 0.86, avg turns 7.2
```

**用法**：
- 每次 SOP 重要修改后，跑一次 bench，对比上次分数
- 不同 LLM 切换时跑 bench 做选型
- CI 可定期跑，检测是否有"静默退化"（LLM API 升级导致某些 SOP 失效）

**为什么放进核心**：没有 bench，所有 compliance 数据都是相对的。有了 bench，自进化才有**绝对对标**。

---

## 3. 与 v2 关系：增量而非替换

**v3 不推翻 v2**，而是把 v2 的 compliance 观测**作为数据底座**。调用关系：

```
v2 层                    v3 层
────────                ────────
Tracer        ────→     Lessons Compiler
Done Gate     ────→     Shadow Runner (事前版)
Spectrum      ────→     Canary Controller
AnchorRules   ────→     Replay Pool (替规则找证据)

(全部)         ────→     Arena (对标评估)
(git state)   ────→     Memory Diff
```

v2 各组件**不做任何改动**。v3 只从它们消费数据，并向它们上游/下游提供新能力。

---

## 4. 目录结构（v2 基础上的增量）

```
ga/
├── internal/
│   ├── agent/           (同 v2)
│   ├── llm/             (同 v2)
│   ├── tools/           (同 v2)
│   ├── memory/          (同 v2，纯只读接口)
│   ├── browser/         (同 v2)
│   ├── frontend/        (同 v2)
│   ├── subagent/        (同 v2)
│   ├── reflect/         (同 v2)
│   ├── config/          (同 v2)
│   ├── observability/   (同 v2)
│   ├── compliance/      (同 v2)
│   │
│   └── evolution/       【v3 新增】
│       ├── lessons.go        # §2.1
│       ├── memdiff.go        # §2.2 (封装 go-git)
│       ├── replay.go         # §2.3
│       ├── shadow.go         # §2.4
│       ├── canary.go         # §2.5
│       └── arena.go          # §2.6
│
├── cmd/ga/              (增 memory/bench 子命令)
├── bench/               【v3 新增】基准任务集
│   └── tasks/*/
├── memory/
│   ├── .git/            【v3 新增】后台维护
│   ├── .lessons/        【v3 新增】
│   │   └── drafts/
│   └── (其他不变)
└── docs/
    ├── EVOLUTION.md     【v3 新增】进化层说明
    └── ...
```

---

## 5. 新/改 工具清单

v3 在 v2 的 9 个原子工具之外，**不新增面向 LLM 的工具**，因为：
- 新工具 = 扩大决策空间 = 违背"9 工具决策空间小"的设计哲学
- §2 的所有能力要么通过**现有工具背后挂 hook**（file_patch 自动 git commit），要么通过**下一轮 prompt 注入文本**（Shadow report / Canary warn / Replay hint），要么通过 CLI 给人类用

唯一例外：`memory_log` / `memory_diff` / `memory_revert` 作为 `code_run` 的白名单特权函数（沿用 v2 §3.1 的 privileged_eval 机制），不算新工具：

```python
code_run({'inline_eval': True, 'script': 'memory_log("plan_sop.md")'})
code_run({'inline_eval': True, 'script': 'memory_diff("plan_sop.md", 1)'})
code_run({'inline_eval': True, 'script': 'memory_revert("plan_sop.md", 1)'})
```

这样就保持了"9 原子工具不膨胀"的核心约束。

---

## 6. Agent Loop hook 的 v3 扩展

v2 定义了 `LoopHook` 接口（OnTurnStart / OnLLMResponse / OnToolCall / OnToolResult / OnTurnEnd / OnLoopExit）。v3 在其上加两个新 hook：

```go
type LoopHook interface {
    // v2 原有
    OnTurnStart(ctx, turn, messages)
    OnLLMResponse(ctx, turn, resp)
    OnToolCall(ctx, turn, call)
    OnToolResult(ctx, turn, outcome)
    OnTurnEnd(ctx, turn, summary)
    OnLoopExit(ctx, exitReason)

    // v3 新增
    BeforeToolCall(ctx, turn, call) ToolGateDecision  // Shadow 可插在这
    OnSessionStart(ctx, sid, task)                    // Replay 可在这注入 hint
}

type ToolGateDecision struct {
    Proceed       bool        // 总是 true，代码不会真 block
    AdvisoryNote  string      // 下一轮 prompt 追加的提示（Shadow Report 通过这里注入）
}
```

**关键约束**：即便 `BeforeToolCall` 返回 `Proceed: false`（代码理论上能 block），v3 的默认策略也是 **always proceed**，只把 `AdvisoryNote` 累积到下一轮 prompt。这保证了"代码不替 LLM 做决定"的哲学底线。

`Proceed: false` 通道只对 **用户通过 `--strict-shadow` CLI flag 明确开启** 的场景生效。默认关闭。

---

## 7. 12 周路线图修订

v2 的总路线不变（12 周），但第 4 阶段的内容进一步扩充：

| 阶段 | 周数 | 累计 | 里程碑 |
|---|---|---|---|
| 0 POC | 1 | 1 | Agent Loop + 1 工具 |
| 1 核心 | 3 | 4 | 9 工具 + 3 协议 + 记忆 |
| 2 浏览器 | 2 | 6 | 完整功能对齐 Python |
| 3 Bot | 2 | 8 | 7 个 IM 平台 |
| **4a Compliance (v2)** | **1** | **9** | v2 四件套：Tracer/Gate/Spectrum/AnchorRules |
| **4b Evolution (v3)** | **2** | **11** | v3 六件套：Lessons/MemDiff/Replay/Shadow/Canary/Arena |
| 5 发布 + 兼容 | 1 | 12 | Release + 迁移 |

第 4 阶段从 v2 的 2 周扩为 3 周，拆成 4a / 4b。之前 v2 的"发布+兼容"合并为 1 周——实现成熟后这是合理的。

### 4b 阶段验收条件

- [ ] **Lessons**：`memory/.lessons/drafts/` 有每个 session 的自动草稿；下次会话启动时 L1 能看到"Recent Lessons"提示
- [ ] **MemDiff**：`memory/.git` 初始化，每次 `file_patch` 自动 commit；`memory_log` / `memory_diff` / `memory_revert` 可用
- [ ] **Replay**：新会话开头若检测到相似历史会话（Jaccard ≥ 0.4），注入 Replay Hint
- [ ] **Shadow**：LLM 要 `file_patch memory/global_mem_insight.txt` 时，先起 subagent 产 shadow report，报告出现在下一轮 prompt
- [ ] **Canary**：修改任一 SOP 后，后续 5 次使用的 compliance 被单独记录；超 20% 退化会在 drafts 下生成警告
- [ ] **Arena**：`ga bench run` 跑通至少 10 个基准任务，输出可比较的 JSON 报告

---

## 8. 与作者设计哲学的对齐验证

v3 的每一项都必须通过"作者哲学三问"：

### Q1：代码层会自动改 SOP / 记忆吗？

**否**。
- Lessons Compiler 只产 `.lessons/drafts/*.md` 草稿（独立目录，不在 L1/L3）
- Memory Diff 只做**LLM 已决定的写**的版本化快照，不自己发起写
- Canary 只**提醒**，不回滚
- Shadow 只**产报告**，不**拦截**（默认）

### Q2：会扩大 LLM 的决策空间（工具数量/抽象复杂度）吗？

**否**。
- 不新增原子工具（维持 9 个）
- 新能力通过 `code_run inline_eval` 白名单函数调用（沿用 v2 §3.1）
- LLM 感知到的唯一变化：L1 偶尔多几句提示性文字（Recent Lessons / Replay Hint / Shadow Report / Canary Warn），每条 30-100 tokens

### Q3：会损害自进化特性吗？

**反而显著增强**。
- 原版 `start_long_term_update` 一次写入后无反馈 → v3 记忆被打上可追溯 ID，后续命中情况能被统计
- 原版 SOP 改完即生效无回退 → v3 自动 git 版本化 + canary 观察
- 原版 L4 只是档案 → v3 作为相似任务的案例库被召回
- 原版 compliance 只进日志 → v3 派生 Lessons 草稿反哺下次会话

**核心逻辑**：作者担心"自动迭代 SOP"会造成偏差放大（v2 §8.2），v3 的答案是——**代码不做闭环自动化，但代码提供让 LLM + 人类做闭环时的所有基础设施**（版本化、diff、canary、回退、对标、草稿审阅）。这就像 git 不会自动改你的代码，但没有 git，没人敢大改。

---

## 9. 风险与应对（v3 新增项）

| 新风险 | 发生场景 | 应对 |
|---|---|---|
| **Lessons drafts 累积过多** | 1000 个会话后 `drafts/` 有千个文件 | 按 `Score` 打分保留 Top 100，其余归档到 `drafts-archive/YYYY-MM/` |
| **Memory git repo 膨胀** | 一年后 `.git` 占几百 MB | 半年跑一次 `git gc --aggressive`；提供 `ga memory compact` 命令 |
| **Shadow subagent 费 token** | 每次改 L1 都起 subagent | 默认只对"改记忆" + "code_run 含敏感关键词"开启；单次 ≤5 turns 硬限 |
| **Replay 误召回** | 关键词 Jaccard 命中但任务其实不相关 | 只提示最高相似度 1 个，且注明相似度分数，LLM 自行判断 |
| **Canary 误报** | 新 SOP 本身没问题，但碰巧这 5 次任务都很难 | 仅提醒不回滚；警告文字明确"可能是任务分布偏差，请结合 diff 判断" |
| **Arena bench 僵化** | benchmark 任务变旧，新特性没覆盖 | Arena 任务集每季度 review；支持 `ga bench add` 让用户贡献任务 |
| **LLM 看到太多"提示性文字"反而困惑** | 每轮都有 Lesson+Replay+Shadow+Canary+Rules 5 条叠加 | Prompt 预算控制：同一轮最多 2 条 advisory，按 Score 排序；其余降级到"看 L1 Recent Lessons 摘要" |

### 9.1 v3 独有的"红线自检"清单

每次添加新 evolution 特性前，强制走一遍：

- [ ] 这个特性会让代码**直接修改** L1/L2/L3 的文本内容吗？（若是 → 砍掉或改为 draft 目录）
- [ ] 这个特性会在 LLM 未请求的情况下**拦截**工具调用吗？（若是 → 改为 advisory）
- [ ] 这个特性会让同一输入产生**不确定性**结果吗？（如不同时运行 shadow 产生不同 prompt → 记录到 trace 保证可复现）
- [ ] 这个特性产出的额外文字占 prompt 预算是否 **≤5%**？（超过就砍）
- [ ] 关闭该特性（CLI flag）后，系统能回退到 v2 行为吗？

所有 v3 六件套均通过此清单。

---

## 10. 验收标准的 v3 修订

v2 §10 保留，v3 追加：

### 10.1 自进化可度量指标

| 指标 | 目标 | 测量方式 |
|---|---|---|
| **Lesson 采纳率** | ≥ 20% 的草稿最终被 LLM 或人类合并进 L1/SOP | 统计 `.lessons/drafts/` vs `memory/` 的 diff 关联度 |
| **Replay 命中有用率** | 被注入 Replay Hint 的会话中，≥ 30% 会产生对相应 L4 文件的 `file_read` | tracer 统计 |
| **Shadow 改方案率** | Shadow 报告中标记"存疑"的操作，LLM ≥ 40% 会调整原方案 | 对比 shadow 报告发出后 LLM 的下一步 |
| **Canary 保护事件数** | 每月至少捕获 1 次 SOP 修改后的退化（若出现） | canary.WarnCount |
| **Bench 分数稳定性** | 连续 30 天 `ga bench run` 分数波动 ≤ 10% | Arena 结果时序分析 |
| **Memory git 回退次数** | 出现 revert 时，100% 有 ask_user 确认记录 | trace 审计 |

### 10.2 反向验证：不做什么

v3 被认定"偏离方向"的 5 个信号（出现就必须修正）：

1. 代码中出现"自动合并 Lesson 到 L1"的逻辑
2. Shadow 默认行为变成"拦截而非提醒"
3. Canary 默认行为变成"自动回滚"
4. Lesson/Replay 提示文字超过每轮 200 tokens
5. 新增了第 10 个原子工具

---

## 11. 一页总结（v3 版）

**做什么**：v2 的可靠 runtime + compliance 观测 + **把观测数据变成带安全网的自进化闭环**。

**v3 的 6 件套**：
- **Lessons Compiler**：会话失败点自动产草稿，下次会话 L1 提示
- **Memory Diff**：记忆文件自动 git 版本化，支持 log/diff/revert
- **Replay Pool**：L4 档案升级为案例库，相似任务自动召回
- **Shadow Runner**：高风险操作前先起 subagent 预演
- **Canary Controller**：SOP 改动有 5 次/24h 观察期
- **Arena Bench**：基准任务集做绝对对标

**与 v2 关系**：**v3 = v2 + 进化层（Evolution Engine）**，v2 是数据源，v3 是消费+反哺闭环。

**核心哲学（继承 v2）**：代码不替 LLM 做决策，只组织舞台。v3 的每一项都是"给 LLM 的工具"或"给人类的审阅入口"，不是"自动化规则引擎"。

**自进化真义**（v3 新结论）：
> 自进化不是"机器自动让自己变聪明"，而是**"让 LLM 和人类组合起来的系统，在每次循环中都比上次多一点证据、多一点可回退性、多一点对标基线"**。Go 代码的唯一职责是把这三个"多一点"工程化。

**3 个保留决策**（v1 → v2 → v3）：
- Only Native LLM 协议
- 个人微信 Python 侧车
- 记忆文件化

**v3 新增的 4 条铁律**：
- 代码组织过程，LLM 做出决策
- 每次记忆改动可撤销、可追溯、可比较
- 没有"自动学习"，只有"便于学习"
- 进化是带评估的（canary / bench）

**12 周里程碑（v3 最终版）**：POC(1) → 核心(3) → 浏览器(2) → Bot(2) → v2 Compliance(1) → **v3 Evolution(2)** → Release+兼容(1)

**最大的风险**：Lessons / Replay / Shadow 的额外 prompt 文字叠加导致 LLM 困惑——用每轮 ≤2 条 advisory + Score 排序控制。

**与 v2 的关键区别**：v2 让问题**可见**，v3 让问题**可进化**。前者是看诊，后者是康复方案。两者互补，缺一不可。

---

## 12. v1 → v2 → v3 差异对照

| 维度 | v1 | v2 | v3 |
|---|---|---|---|
| 定位 | Python→Go 翻译 | LLM-CPU 可靠 runtime | LLM-CPU 可靠 runtime + **闭环进化引擎** |
| 核心价值 | 快/小/并发 | 稳/透明/可观察 | 稳/透明/可观察 + **可进化/可回退/可对标** |
| 对"自进化"的处理 | 忽略 | 未工程化 | **Evolution Engine 六件套** |
| 改进项数 | 9 项"短板" | 4 项工程 + 4 项 compliance | 4 项工程 + 4 项 compliance + **6 项 evolution** |
| 对 SOP | 加 schema | 透明 | 透明 + **git 版本化 + canary** |
| 对记忆 | Guardian 自动修 | 只读 | 只读 + **git repo + diff/revert API** |
| 对 L4 | 不涉及 | 不涉及 | **升级为 Replay 案例库** |
| 对 compliance 数据 | - | 写日志 | **派生 Lessons 草稿反哺** |
| 对 SOP 变更 | - | 即时生效 | **canary 期 + 退化预警** |
| Agent Loop hook | 无 | OnXxx 6 个 | OnXxx 6 个 + **BeforeToolCall / OnSessionStart** |
| 新原子工具数 | +0 | +0 | **+0**（维持 9 个） |
| 新 CLI 子命令 | ga run/task/serve | +ga check/status/explain | +**ga memory / bench / lessons** |
| 验收重点 | 性能指标 | 可观测性指标 | 可观测性 + **自进化可度量指标** |

---

## 13. 附录：Evolution Engine 的哲学基础

### 13.1 为什么"进化"必须是"带安全网的"

作者自分析点出了两个真弱点：**SOP 遵从概率性 + LLM 缺主动验证**。

这两个弱点意味着：**LLM 自己做的任何决定都可能错**，包括"修改 SOP 以改进自己"这个决定。

因此任何自进化机制若没有安全网，就会陷入作者预警的陷阱：
> 闭环放大偏差：LLM 根据观测数据改 SOP → 下次受改后的 SOP 影响 → 生成更偏的观测 → 再改 SOP。

v3 六件套的"安全网"构成：

| 风险场景 | v3 的安全网 |
|---|---|
| LLM 改的 SOP 让后续任务退化 | Canary 警告 + Memory git revert |
| LLM 误判把错误经验当教训 | Lesson 只到 draft 不到 L1 + 人类审阅入口 |
| LLM 用过去相似任务的错误方法 | Replay 只是提示，不自动复制步骤 |
| LLM 贸然做危险操作 | Shadow 先预演，报告回主 session |
| 不同 LLM 版本导致整体退化 | Arena bench 做绝对对标 |

**有了这张网，LLM 就可以放心"大胆尝试"**——因为代价被 git/canary/bench 兜住了。

### 13.2 为什么这仍然是"LLM-native"而不是"工程至上"

v3 有可能被误读为"加了好多代码，是不是回到了 v1 的工程思维？"。辨析如下：

- v1 想**替 LLM 做决定**：自动归档冷 SOP、自动拒绝 inline_eval、自动压缩历史
- v3 只**替 LLM 准备工具**：git 快照在 LLM 决定写的时候才拍、canary 警告在数据退化时才出、shadow report 在 LLM 决定高风险操作时才生成

**判定标准**：把 v3 任一个特性关掉（通过 CLI flag），系统依然是 v2 的行为。这说明 v3 的能力都是**可选的增强**，不是**强制的规则**。

这正是 Evolution Engine 的底线——它是一组"LLM 可以自愿使用的 DevOps 工具"，而不是"强加在 LLM 身上的管控层"。

### 13.3 一句话区分 v2 和 v3

> **v2**：让 LLM 的错误**被看见**。
> **v3**：让看见的错误**能变成下次做得更好**。

---

## 14. 文档版本历史

- v1.0 (2026-05-02)：首版，工程师视角，9 项短板修复
- v2.0 (2026-05-02)：吸收作者自分析后的深度修订，定位从"翻译"转为"LLM-CPU runtime"，新增 4 项 compliance 观测机制，撤销 5 项与 LLM-native 理念冲突的"改进"
- **v3.0 (2026-05-02)**：**在 v2 基础上引入 Evolution Engine 第五层架构**，围绕 GA 的"自进化"核心招牌构造 6 件套（Lessons / MemDiff / Replay / Shadow / Canary / Arena），形成"观测 → 教训提炼 → 带安全网的变更 → 对标评估"的闭环。坚守作者三条铁律（代码不改 SOP/记忆、不强制 LLM、不扩大决策空间），同时让"进化"本身成为可工程化、可度量、可回退的一等公民。
