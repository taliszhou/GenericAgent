# Aimemkb 知识库 Agent 专用 SOP

> **目标**：帮助 Agent 高效使用 aimemkb 记忆系统（两层架构：原始记忆层 + 主题页面层）
> **服务器**：http://9.134.45.136:11920/mcp
> **文档版本**：基于 help 工具返回的 v3 帮助文档整理

---

## 核心概念

### 两层架构
```
       你（agent）
          │
   ┌───────┴───────┐
   │ remember    │     search / get
   ▼             ▼              ▼
┌──────────────┐    ┌──────────────┐
│  原始记忆层    │    │  主题页面层    │
│  你写的每条    │ ─► │  系统编译派生  │
│  原封不动落这里│    │  按主题组织    │
└──────────────┘    └──────────────┘
   ground truth          被组织过的视图
```

**简单心智模型**：你写的是流水账，aimemkb 自动给你整理成 wiki。
- `remember` = 写流水账
- `search` = wiki 目录
- `get` = wiki 词条

### 关键术语：slug

- **slug** = 主题页面的稳定标识符
- 格式：小写 kebab-case，人类可读
- 示例：`project-omega` / `task-fix-login-bug` / `zhang-san`
- **不是你猜的 UUID 也不是数字**
- 永远先 `search`，再从搜索结果或 remember 返回结果中获取 slug

### 主题类型（type）

| type | 中文 | 典型内容 |
|------|------|---------|
| `task` | 任务 | 待办、行动项 |
| `event` | 事件 | 会议、上线、事故 |
| `entity` | 实体 | 人、组织、项目、产品 |
| `concept` | 概念 | 抽象概念、术语、原理 |
| `source` | 资料 | 文档片段、单一资料 |
| `synthesis` | 综合 | 跨多来源的归纳判断 |
| `comparison` | 对比 | 多对象对比 |
| `query` | 查询 | 可重复问的问题（"活的视图"） |

**重要**：`remember` 不接受手动指定 type —— 系统读取你的 content 自动判断。

---

## 三大工具

| 工具 | 一句话 |
|------|--------|
| `remember` | 写一条记忆。系统自动派生/更新相关主题页面。 |
| `search` | 找主题页面（按关键词、类型、属性、智能集合）。返回每个主题页面的 slug。 |
| `get` | 用 search 给的 slug 取这个主题页面的完整详情（可分层取）。 |

---

## Step 1: 写入记忆（remember）

### 应该写
| 触发 | 写法 |
|------|------|
| 完成一个功能/修复 | `remember(content="改了 X，因为 Y", concept="X 修复")` |
| 做了技术决策 | `remember(content="选 A 方案，否定 B，原因是 C")` |
| 修了 bug | `remember(content="现象 + 根因 + 修复方式")` |
| 用户提需求/任务 | `remember(content="任务 X：周五前完成 Y")` |
| 任务状态变更 | `remember(content="任务 X 已完成", about_slug="task-x", properties={"status":"已完成"})` |
| 学到用户偏好/习惯 | `remember(content="用户偏好：所有 commit 必须 sign-off")` |
| 部署/上线 | `remember(content="X 已部署到 server-Y, commit Z")` |
| 跨会话需要记住的状态 | `remember(content="...")` |

### 不要写
- 纯查询、检索、读代码 —— 你查就完事，别记
- 简单 shell 操作（kill 进程、推代码、跑测试）
- 闲聊、问候、确认（"好的"、"收到"）
- 用户的提问本身（只记**结论**，不记**问题**）
- 与上一条记忆字面相似的内容（系统有 5 分钟 hash dedup 兜底，但浪费 token）
- 自己的内心 OS / 思考过程

### 写入质量铁律
1. **一事一条** —— 不要把"今天做了 A、B、C"塞一条。三件事就写三条。
2. **concept 用中文短短语** —— `"KB Chat SSE 实现"` ✓ / `"task-12345"` ✗
3. **content 完整自洽** —— 假设 6 个月后你再看，仍然能完全理解。包含：是什么、为什么、谁、何时（如果相关）。
4. **写结论，不写过程** —— `"方案 A 已选定"` ✓ / `"我正在讨论方案 A"` ✗

### 关联到已有主题页面：about_slug

如果你已经知道这条记忆属于哪个主题（先 search 拿到 slug），用 `about_slug`：

```
remember(
  content="任务 X 进度过半，预计明天完成",
  about_slug="task-x",
  properties={"进度":"50%"}
)
```

这样新记忆直接挂到 `task-x` 主题页上，避免系统重新猜测应该归到哪。

---

## Step 2: 读取信息（search 和 get）

### 必须先 search 的场景
| 触发 | 做什么 |
|------|--------|
| 用户说"上次 / 之前 / 我们讨论过" | `search(query="<关键词>")` 找候选 |
| 修改已有模块的代码 | `search(query="<模块名>")` 看有没有相关历史 |
| 新会话第一个任务 | `search(query="<任务关键词>")` 建立上下文 |
| 涉及架构/配置/部署决策 | `search(query="<相关主题>")` 看有没有定过 |

### 不需要读的场景
- 用户给的指令完整明确，没有任何"过往依赖"暗示
- 全新功能、全新文件、全新代码
- 读代码 / grep 几下就能确认的纯技术事实

### search 四种用法

```python
# 1. 关键词搜
search(query="维护")

# 2. 按类型列举
search(type="task")              # 所有任务（含已完成）
search(type="task", status="evolving")  # 进行中的任务

# 3. EAV 属性精确过滤
search(filters={"项目":"omega", "优先级":"P0"})

# 4. 智能集合（预定义查询）
search(set="active_tasks")
```

### search 返回结构 + 分页

每个 hit **直接含完整 body**，agent 通常不需要再 get 二次确认。配合 **page_size 默认 5** 防止上下文炸；total + has_more + next_page 让 agent 知道还有多少。

```json
{
  "vault": "worklogs",
  "query": "维护",
  "page_size": 5,
  "page_index": 0,
  "total": 12,
  "has_more": true,
  "next_page": 1,
  "hits": [
    {
      "slug": "maintenance-renewal",
      "title": "维护续约方案",
      "type": "comparison",
      "status": "stable",
      "summary": "...",
      "body": "# 维护续约方案

...完整正文...",
      "tags": ["合同", "维护"],
      "related_slugs": ["client-foo", "renewal-2026"],
      "body_chars": 1234,
      "updated_at": "2026-04-26T05:22:52Z"
    },
    ...
  ]
}
```

### 翻页
```python
search(query="维护", page_index=1)              # 拿第 2 页
search(query="维护", page_size=10, page_index=0) # 改大页大小
```

`page_size` 上限 50。set 模式下 total 可能为 -1（智能集合不算总数），翻到 has\_false 即结束。

### get 默认就给完整内容

`get(slug)` 默认返回：subject 自身**完整 body** + **related[]**（正反链相关主题，每项含 title/summary/截断 body 1000 字）。agent 通常一次调用就够。

```
get(slug="project-omega")
```

返回大约：
```json
{
  "id": "...", "slug": "project-omega",
  "title": "项目 Omega", "type": "entity",
  "summary": "...",
  "body": "# 项目 Omega

...完整正文...",
  "tags": ["产品", "p0"],
  "updated_at": "2026-04-26T...",
  "related": [
    {"slug": "task-omega-launch", "title": "Omega 上线任务", "type": "task",
     "summary": "...", "body": "...（截断到 1000 字）", "body_truncated": true,
     "direction": "out"},
    {"slug": "zhang-san", "title": "张三", "type": "entity",
     "summary": "...", "body": "...", "direction": "in"},
    ...
  ]
}
```

`direction`：`"out"` = 正链（这个主题的 related\_slugs 列出的）；`"in"` = 反链（其它主题的 related\_slugs 指向这个）。

### 需要更深时，opt-in 几个 include

| include 项 | 拿到什么 |
|-----------|---------|
| `properties` | EAV 属性快照（{"status":"进行中","截止日":"2026-05-01"} 这种）|
| `memories` | 关联的原始 memory ID 列表（轻量）|
| `memories_content` | 上面 + 每条 memory 的原文/概念/源信息 |
| `source_docs` | 关联的源文档元数据（doc\_id, title, file\_name 等）|

写法：
```
get(slug="...", include=["memories_content"])           # 看原始证据
get(slug="...", include=["properties", "source_docs"])  # 拉属性 + 文档来源
```

### 路由速查

| 我想要... | 用什么 |
|-----------|--------|
| 看所有进行中的待办 | `search(type="task", status="evolving")` |
| 找含某关键词的主题页面（连 body 一起看） | `search(query="<词>")` |
| 翻下一页 | `search(query=..., page_index=1)` |
| 跑预定义的智能集合 | `search(set="<set 名>")` |
| 按属性精确筛选 | `search(filters={"key":"value"})` |
| 取某主题完整详情 + 正反链 | `get(slug=...)` |
| 看某主题原始证据 | `get(slug=..., include=["memories_content"])` |
| 看某主题 EAV 属性 | `get(slug=..., include=["properties"])` |

### 不要这样做
- ❌ 反复换关键词搜（一次搜不到就换工具，或者直接 ask user）
- ❌ 把 search 当全文 LIKE 用（它是 FTS，按 token 切，不会匹配子串）
- ❌ 跳过 search 直接 get(slug="盲猜的slug")（slug 是 kebab-case，猜不准）
- ❌ 一上来 page\_size=50（除非真要遍历全量；默认 5 是经过 token 预算计算的）

---

## Step 3: 创建活视图（query 类型主题页）

query 类型主题页面特别：**它会自动刷新**。你定义一次"问题 + 过滤条件"，之后每次有新数据进来，系统会自动更新这个页面里的"答案段"。

适合所有反复要问的高频问题：
- "今天最重要的 3 个待办"
- "本周新增的资料"
- "进行中的所有项目"
- "我未读的通知"

### 创建活视图
```python
remember(
  content="查询定义：今天最重要的 3 个待办任务",
  concept="今日待办 Top3",
  properties={
    "live_filter": {
      "filter": {"type": "task", "status": "进行中"},
      "rank_llm_hint": "重要程度（综合 deadline + 项目优先级）",
      "limit": 3
    }
  }
)
```

live\_filter 字段：

| key | 必填 | 说明 |
|-----|------|------|
| `filter` | 是 | SQL 过滤条件，键支支持 type / status / 任意 EAV 属性 |
| `rank` | 否 | 内置排序：due\_asc / created\_desc / updated\_desc（默认）/ manual |
| `rank_llm_hint` | 否 | 自然语言排序提示。**填了它，系统调 LLM 重排**，适合"最重要"这种主���排序 |
| `limit` | 是 | top N（1-20）|

### 取活视图答案
```
get(slug="<query 的 slug>", include=["body"])
```

每次取都是最新结果。

---

## Step 4: 错误速查

错误统一返回 JSON 结构，agent 用 error.code 做条件判断（不要靠解析 message 文本）：

```json
{"error": {"code": "not_found", "message": "未找到 slug=foo"}}
```

错误码：

| code | 说明 | 怎么办 |
|------|------|--------|
| `bad_request` | 入参缺失/非法 | 检查参数 |
| `not_found` | slug 不存在 | 先 search 找正确 slug |
| `permission_denied` | 无访问该 vault / 资源 | 确认 caller 身份 |
| `internal_error` | server 端异常（DB / SQL / parse） | 看 message 找原因，必要时 retry |

常见现象速查：

| 现象 | 原因 | 怎么办 |
|------|------|--------|
| `tool not found: <旧名>` | 用了未提供的工具 | 只有 3 个 agent 工具：remember/search/get |
| `search` 返回 0 结果但你确定写过 | 关键词偏 / FTS 不匹配子串 / vault 错 | 换更具体的词；或直接 search(type="...") 列举 |
| `remember` 返回 `status=failed` | properties 缺必填字段 | 看返回的 recommend 字段补齐 |
| `remember` 返回 `pending_compile=true` 后 search 找不到 | subject 编译还在跑 | 这是正常的，30-60s 后再 search |
| 关联到的主题页面 type 不符预期 | 系统按 content 自动判断 | 在 content 里把关键词写清楚（比如"任务"前缀触发 task）|

---

## 附录：新会话标准开场

第一次接手一个会话：

```
1. 用户说了关键词 → search(query="<词>")
   每个 hit 已经含 body, 多数情况看 hit 就够。
2. 想看正反链相关主题 → get(slug=候选)
   返回主体完整 body + related[] 含正反链相关主题。
3. 还需要追原始证据 → get(slug=候选, include=["memories_content"])
4. 完成动作后 → remember(content="<结论>", about_slug="<相关 slug>")
   记得：remember 是异步派生主题页面（pending\_compile=true），
   不要立刻 search 期待派生结果, 等 30s 再 search。
```

不确定时，**search 比 ask 用户更快**。

---

## 附录：最常踩的坑

1. **写得太碎** —— "我打开了文件" / "我开始改了" / "改了一行" 这种不要写。等做完整件事写一条结论。
2. **写得太抽象** —— "优化了性能" 没用。"把 FTS 查询从 O(n²) 改成倒排索引，p99 从 800ms → 40ms" 才有用。
3. **重复写** —— 同一件事不要因为多次提到就多次写。先 search，发现已经写过就 about\_slug 续写或 properties 更新。
4. **slug 当 ID 用** —— slug 是人类可读的 kebab-case 短句，不是 UUID。搜不到就别猜，先 search。
5. **跳过 search 直接 remember 同主题** —— 系统会尽量去重，但偶尔仍会派生新页（slug 微妙差异）。先 search 拿到准确 slug 用 about\_slug 是最稳的。
6. **把"任务完成"误作归档** —— 任务状态变更用 `remember(about_slug, properties={"status":"已完成"})`，不要试图删掉主题页面。aimemkb 设计上**不暴露删除/归档操作给 agent**，主题的生命周期管理在 WebUI 上由人工进行。

---

_整理时间：2026-05-04 · 基于 aimemkb help 工具 v3 文档整理_
