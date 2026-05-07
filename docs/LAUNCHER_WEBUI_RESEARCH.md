# 调研：Launcher / 端口 / 记忆共享 / Wechat-Web 整合 / WebUI 架构

> **文档编号**：TZ-RESEARCH-002
> **版本**：v1.0
> **日期**：2026-05-03
> **作者**：架构评审（Claude Opus 4.7 1M）
> **关联文档**：[`PROJECT_DIRECTION.md`](./PROJECT_DIRECTION.md) §4.4
> **声明**：本文档是**调研笔记**，不是实施规范。结论性建议见各章末"建议"段；落地前需开 PR 把决策写进规格。

---

## 0. 调研问题清单

本文档回答 5 个问题：

1. `launch.pyw` 用 webview 起 GUI 是否必要？是否承载某些"GUI-only"特性？
2. 端口当前是随机的，怎么改成 mykey.py 可配置（既灵活又能固定）？
3. bot / web / GUI 多个 frontend 之间是否共享记忆？共享到什么程度？
4. 改完 (2) 后，怎么改造 `start_wechat.sh` 让它启动 wechat 同时拉起 web 服务？
5. 当前 WebUI 是什么架构？这是后面要重点打造的对象。

---

## 1. launch.pyw GUI 是否必要

### 1.1 你的猜测 vs 事实

你的猜测：GUI 是为了承载"键鼠控制那种大功能特性"。

**部分对，部分错**：
- ✅ GUI 是有意为之，不是疏忽
- ❌ 但**不是为了键鼠控制**——`ljqCtrl` 是 agent 通过 `code_run` 直接调用的 Python 库，不依赖 launcher GUI（grep 验证：`launch.pyw` + `frontends/*.py` 中**零次** import ljqCtrl）

### 1.2 GUI 真正承担的 webview-only 功能

读 `launch.pyw` 全文（144 行），webview 不可替代的功能**只有一个**：

**自主任务注入**（line 25-41 + 65-79）：

```python
def inject(text):
    window.evaluate_js(f"""
        const textarea = document.querySelector('textarea[data-testid="stChatInputTextArea"]');
        // 用原生 setter 绕过 React，强行设值
        // 触发 input + change 事件
        // 200ms 后点击 submit 按钮
    """)

def idle_monitor():
    while True:
        time.sleep(5)
        last_reply = get_last_reply_time()
        if now - last_reply > 1800:  # 30 分钟无回复
            inject("[AUTO]🤖 用户已经离开超过30分钟，作为自主智能体，请阅读自动化sop，执行自动任务。")
```

**为什么必须 webview，不能用普通浏览器**：
- 需要 Python 进程**主动**向 web UI 注入文本（不是 web UI 主动拉）
- `window.evaluate_js(...)` 是 Python ↔ JS 双向通道，只有 webview 提供
- 普通浏览器中 Python 进程无法操作 DOM——必须借助 server push（WebSocket / SSE），但 Streamlit 没有原生的"从 Python 端推消息进特定 session"API

**次要功能**：
- `PASTE_HOOK_JS`（line 50-63）：粘贴图片 / 文件时自动插入占位符（可在普通浏览器实现，不需要 webview）
- 窗口位置控制（line 135-138）：右上角固定（普通浏览器也行，但要操作系统 API）

### 1.3 结论与建议

**保留 launch.pyw GUI 的核心理由**：**autonomous idle injection**——这是"30 分钟没操作就自动跑自主任务"的实现基底，是 GA "自主行动" 哲学的物理体现。

**但这个能力可以用别的方式实现**（如果未来想纯 web）：
- Streamlit 端轮询一个磁盘上的 trigger 文件，发现 trigger 后 self-inject
- 或者 streamlit_autorefresh + URL 参数推任务
- 或者 SSE / WebSocket 双工通道

**短期建议**：保留 launch.pyw 不动。它已经能用，且 webview 模式确实是"自主注入"的最直接方案。把精力放在改进 web 体验本身（§5）。

---

## 2. 端口固定配置（mykey.py 加配置项）

### 2.1 现状

读 `launch.pyw:8-13`：

```python
def find_free_port(lo=18501, hi=18599):
    ports = list(range(lo, hi+1)); random.shuffle(ports)
    for p in ports:
        try: s = socket.socket(); s.bind(('127.0.0.1', p)); s.close(); return p
        except OSError: continue
    raise RuntimeError(f'No free port in {lo}-{hi}')
```

每次启动随机选 18501-18599 之间的空闲端口。后果：
- 浏览器收藏夹失效
- 远程 SSH tunnel 命令每次要改
- 反向代理配置不稳定

CLI 上虽然支持 `port` 位置参数（line 84：`parser.add_argument('port', nargs='?', default='0')`），但默认 `'0'` 仍走随机路径。

### 2.2 mykey.py 当前结构

`mykey_template.py` / `mykey_template_en.py` 当前是 **dict 集合**——每个 dict 是一个 LLM 配置（key 含 `api`/`config`/`cookie` 关键词的会被 `agentmain.py:54-78` 的 `load_llm_sessions` 扫描到）。

非 LLM 类的设置（如端口、bot token）也散落在各处。**没有统一的配置 schema**。

### 2.3 建议方案

**最小侵入方案**：在 `mykey.py` 加一个 `app_config` dict（不含 `api`/`config`/`cookie` 关键词，所以不会被 LLM scanner 误识别）：

```python
# mykey.py
app_config = {
    'webui_port': 18501,           # int = 固定端口；0 = 自动找空闲
    'webui_port_range': (18501, 18599),  # 自动模式时的范围
    'webui_bind': '127.0.0.1',     # 想暴露公网就改 '0.0.0.0'
    'wechat_lock_port': 19531,     # 与 wecomapp 互斥的端口
    'launcher_lock_port': 19735,   # hub.pyw 单例锁
    # ... 其他全局配置
}

# 已有的 LLM 配置 dict 不变
api_xxx = { ... }
native_claude_config = { ... }
```

**修改点**（具体 file:line）：

1. **`launch.pyw:8-13`** — `find_free_port` 之外加一个 `resolve_port` 函数：
   ```python
   def resolve_port(cli_port_arg):
       # 优先级：CLI 参数 > mykey.app_config.webui_port > 自动找空闲
       if cli_port_arg and cli_port_arg != '0':
           return int(cli_port_arg)
       try:
           import mykey
           cfg = getattr(mykey, 'app_config', {})
           configured = cfg.get('webui_port', 0)
           if configured > 0:
               return configured
           lo, hi = cfg.get('webui_port_range', (18501, 18599))
           return find_free_port(lo, hi)
       except (ImportError, AttributeError):
           return find_free_port(18501, 18599)
   ```

2. **`launch.pyw:93`** — `port = str(find_free_port())` 改为 `port = str(resolve_port(args.port))`

3. **`mykey_template.py`** + **`mykey_template_en.py`** — 加 `app_config` 模板段，含注释解释每项

4. **`stapp.py`**（可选）—— 如果直接 `streamlit run stapp.py` 而不是通过 launch.pyw，`stapp.py` 自己也读 `app_config['webui_port']` 给 streamlit 用（但 streamlit 端口由 CLI 控制，stapp.py 不能改自己端口；这条要么通过 wrapper 脚本，要么放弃）

5. **`reflect.py` / `agentmain.py --reflect`** — 如果有 web 探针之类的服务也读 `app_config`

**优先级语义**：
```
CLI 参数（--port N） > mykey.app_config.webui_port（int > 0） > 自动找空闲
```

这样：
- 想固定就在 mykey 配 `'webui_port': 18888`
- 想灵活就配 `'webui_port': 0`（或不配）+ 配 `webui_port_range`
- 想临时 override 就 `python launch.pyw 18999`

### 2.4 关于 mykey 配置 schema 的建议

当前 mykey 是裸 Python 文件 + 关键字扫描——很 hacky。如果未来要扩 `app_config` 的项（webui / bot / log / wechat），考虑：

- **保留 mykey.py 作为 LLM 凭证文件**（已习惯，不动）
- **新增 `app_config.py`**（与 mykey.py 同目录）作为应用级配置，结构化：
  ```python
  webui = {'port': 18501, 'bind': '127.0.0.1'}
  wechat = {'lock_port': 19531, 'qr_path': '~/.wxbot/wx_qr.png'}
  bots = {'tg_token': '...', 'feishu_app_id': '...'}
  ```
- 或者直接用 `app_config.toml` / `app_config.yaml`（更标准，但需要解析依赖）

**短期不要动这一层**，先在 mykey.py 加 `app_config` dict 满足当前需求。**等真的有 5+ 个跨模块设置时**再考虑结构化重构。

---

## 3. 多 frontend 之间的记忆共享模型

### 3.1 你的记忆没错，但**共享方式有重要细节**

读 `frontends/*.py` 的 `GeneraticAgent()` 实例化点：

```
frontends/dcapp.py:23       agent = GeneraticAgent()
frontends/dingtalkapp.py:16 agent = GeneraticAgent()
frontends/fsapp.py:238      agent = GeneraticAgent()
frontends/qqapp.py:16       agent = GeneraticAgent()
frontends/qtapp.py:1972     agent = GeneraticAgent()
frontends/stapp.py:24       agent = GeneraticAgent()      # web
frontends/stapp2.py:802     agent = GeneraticAgent()      # web v2
frontends/tgapp.py:30       agent = GeneraticAgent()
frontends/wechatapp.py:255  agent = GeneraticAgent()
frontends/wecomapp.py:338   agent = GeneraticAgent()
```

**每个 frontend 是独立进程**，**各自实例化一个 GeneraticAgent**。这意味着：

| 状态类型 | 是否共享 | 共享机制 |
|---|---|---|
| **L1 长期记忆**（`memory/global_mem_insight.txt`） | ✅ 共享 | 各进程读同一文件 |
| **L2 长期记忆**（`memory/global_mem.txt`） | ✅ 共享 | 同上 |
| **L3 SOP / 脚本**（`memory/*.md` / `*.py`） | ✅ 共享 | 同上 |
| **L4 历史会话归档**（`memory/L4_raw_sessions/`） | ✅ 共享（一处写多处读） | 文件系统 |
| **`memory/file_access_stats.json`**（工具使用统计） | ✅ 共享 | 文件系统 |
| **当前对话历史**（`agent.handler.history_info`） | ❌ **不共享** | 各进程独立 |
| **当前任务队列**（`agent.task_queue`） | ❌ **不共享** | 各进程独立 |
| **当前 working memory**（`handler.working['key_info']`） | ❌ **不共享** | 各进程独立 |
| **LLM 选择**（`agent.llm_no`） | ❌ **不共享** | 各进程独立 |
| **`temp/model_responses_<PID>.txt`** | ❌ 各 PID 独立文件 | 但**互相可读**（`/restore` / `/continue` 命令会跨 PID 扫） |

### 3.2 这个设计的精妙与代价

**精妙**：
- 无 IPC 复杂度（filesystem 即接口）
- 任意 frontend 独立崩溃不影响其他
- 加新 frontend 零侵入（只需 import GeneraticAgent）
- Python 上游写到 memory 的更新，Go 端 / Bot / Web 都立即看见

**代价**：
- **跨 frontend 不能"接力对话"**：你在 web 里跟 agent 聊到一半，切到 telegram 不能继续——telegram 的 GeneraticAgent 不知道 web 那边的 history
- **任务状态不共享**：tg 启动一个长跑任务，web 端看不到"正在跑"的状态
- **LLM 切换不同步**：在 web 切到 LLM #2，tg 还在用 #0
- 单台机器跑多 frontend → 多份内存（每份 agent 实例 ~100MB+）

### 3.3 跨 frontend 接续对话的现有机制

**`/restore` 命令**（`chatapp_common.py:181-192`）：
- 扫 `temp/model_responses/model_responses_*.txt`
- 取最新（按 mtime）的那份
- 解析其中的 `=== Prompt ===` / `=== Response ===` 对
- 重建 history_info

**`/continue [n]` 命令**（`continue_cmd.py`）：
- 列出所有可恢复的会话（不限 PID）
- 用户选 N 恢复

**所以**：跨 frontend 接续是**用户手动 `/continue` 触发的"快照恢复"**，不是自动 sync。你在 web 聊一半切到 tg 想继续，要在 tg 输入 `/continue` 然后选择 web 那次的会话。

### 3.4 v3 Evolution Engine 视角下的影响

如果你按 `PROJECT_DIRECTION.md` §4.2 阶段 1-2 实施 MemDiff + Tracer + Lessons Compiler：

- **MemDiff（git 化）**：自动 commit，**多 frontend 都从 memory 写就都被 commit**——很自然地统一 audit
- **Tracer**：每个 frontend 自己写 `temp/compliance/<sid>/trace.json`——**多个 trace 各 sid 独立**；一个 frontend 看不到另一个的 trace（除非主动扫盘）
- **Lessons Compiler**：每个 frontend 各自结束自己的 session 时跑 compiler——drafts 写到同一个 `memory/.lessons/drafts/`——**多 frontend 的 lessons 自然汇总**
- **Replay Pool**：fingerprint 写到 L4 archive 的同一个目录树——**自动跨 frontend 共享**

**结论**：v3 Evolution Engine 的设计**天然适配 filesystem-based loose coupling**，不需要为多 frontend 做特殊改造。这是 GA 设计哲学的延伸——所有共享状态都是 filesystem-mediated。

### 3.5 建议

**短期**：
- **不要**试图引入跨 frontend 的实时状态同步（会破坏现有 loose coupling 的简洁性）
- **要**把"跨 frontend 接续"的 UX 优化：例如 web UI 启动时自动扫 `temp/model_responses_*.txt` 列出"上次在 tg 的会话 / 上次在 wechat 的会话"，让用户一键恢复

**中期**（v3 Evolution Engine 落地后）：
- Replay Pool 自动注入"上次类似任务在 X frontend 跑过"的 hint，让 LLM 自己决定是否读取 transcript
- 这本质上就是用现有的 v3 设计满足跨 frontend 协作的需求

---

## 4. start_wechat.sh + Web 服务整合

### 4.1 用户需求

完成 §2（端口可配）后，改造 `start_wechat.sh`：启动 wechat bot 的同时启动 web 服务，**让浏览器直接可用**。

### 4.2 整合方案设计

#### 设计原则

1. **wechat bot 与 web 服务生命周期解耦**：单独启停（用户可能只想跑 bot 不要 web，或反过来）
2. **保留 daemon 模型**：两者都后台跑、都有 PID 文件、都能 restart 不影响对方
3. **复用 §2 的端口配置**：web 服务从 `mykey.app_config.webui_port` 取
4. **向后兼容**：现有 `./start_wechat.sh start` 行为保留（启 bot），新增子命令启 web

#### 命令扩展

```
./start_wechat.sh                # 同 start
./start_wechat.sh start          # 启动 wechat bot (现有)
./start_wechat.sh start --web    # 启动 wechat bot + web 服务
./start_wechat.sh web start      # 只启 web 服务
./start_wechat.sh web stop       # 只停 web 服务
./start_wechat.sh stop           # 停 wechat bot
./start_wechat.sh stop --all     # 停 bot + web
./start_wechat.sh status         # 查看 bot 状态
./start_wechat.sh status --all   # 查看 bot + web 状态
./start_wechat.sh restart        # 重启 bot (沿用)
./start_wechat.sh log            # tail bot 日志
./start_wechat.sh web log        # tail web 日志
```

#### 实现 sketch

在 `start_wechat.sh` 加一段：

```bash
# ── Web 服务路径（追加到现有变量段）─────────────────
WEB_PID_FILE="$SCRIPT_DIR/temp/webui.pid"
WEB_LOG_FILE="$SCRIPT_DIR/temp/webui.log"
WEB_BOOT_LOG="$SCRIPT_DIR/temp/webui.boot.log"

# ── Web 端口（从 mykey 读取）─────────────────────────
get_web_port() {
    "$PY" -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR')
try:
    import mykey
    cfg = getattr(mykey, 'app_config', {})
    port = cfg.get('webui_port', 0)
    if port > 0:
        print(port); sys.exit(0)
    # 自动模式：找空闲
    import socket, random
    lo, hi = cfg.get('webui_port_range', (18501, 18599))
    ports = list(range(lo, hi+1)); random.shuffle(ports)
    for p in ports:
        try: s = socket.socket(); s.bind(('127.0.0.1', p)); s.close(); print(p); sys.exit(0)
        except OSError: continue
except Exception: pass
print(18501)  # fallback
"
}

# ── Web 进程管理 ────────────────────────────────────
get_web_pid() {
    if [ -f "$WEB_PID_FILE" ]; then
        local pid; pid=$(cat "$WEB_PID_FILE" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo "$pid"; return 0; fi
    fi
    pgrep -f "[s]treamlit run.*stapp.py" | head -1
}

is_web_running() {
    local pid; pid=$(get_web_pid)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

cmd_web_start() {
    check_python
    if is_web_running; then
        c_yell "[SKIP] Web 已在运行 (PID=$(get_web_pid))"
        cmd_web_status; return 0
    fi
    local port; port=$(get_web_port)
    c_blue "[INFO] 启动 Web UI on port $port ..."
    nohup "$PY" -m streamlit run "$SCRIPT_DIR/frontends/stapp.py" \
        --server.port "$port" --server.address localhost --server.headless true \
        >"$WEB_BOOT_LOG" 2>&1 &
    local pid=$!
    echo "$pid" > "$WEB_PID_FILE"
    c_green "[OK] Web 已后台启动, PID=$pid, URL=http://localhost:$port"
    sleep 3
    if ! is_web_running; then
        c_red "[ERR] Web 进程已退出，最后输出:"
        tail -20 "$WEB_BOOT_LOG" 2>/dev/null
        rm -f "$WEB_PID_FILE"; exit 1
    fi
    c_blue "[INFO] 浏览器访问: http://localhost:$port"
    # macOS 自动打开浏览器
    if [ "$(uname)" = "Darwin" ] && [ "${OPEN_BROWSER:-1}" = "1" ]; then
        open "http://localhost:$port"
    fi
}

cmd_web_stop() {
    if ! is_web_running; then
        c_yell "[SKIP] Web 未在运行"; rm -f "$WEB_PID_FILE"; return 0
    fi
    local pid; pid=$(get_web_pid)
    c_blue "[INFO] 正在停止 Web PID=$pid ..."
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
    rm -f "$WEB_PID_FILE"
    c_green "[OK] Web 已停止"
}

cmd_web_status() {
    if is_web_running; then
        local pid; pid=$(get_web_pid)
        local port; port=$(lsof -p "$pid" 2>/dev/null | grep LISTEN | head -1 | awk '{print $9}' | sed 's/.*://')
        c_green "[RUNNING] Web PID=$pid, URL=http://localhost:${port:-?}"
    else
        c_yell "[STOPPED] Web 未在运行"
    fi
}

cmd_web_log() {
    [ -f "$WEB_LOG_FILE" ] || { c_red "[ERR] Web 日志不存在，先 web start"; exit 1; }
    tail -n 50 -f "$WEB_LOG_FILE"
}

# ── 入口扩展（替换现有 case 段）─────────────────────
case "${1:-start}" in
    start)
        cmd_start
        # --web 选项：bot 启动后再起 web
        if [ "${2:-}" = "--web" ]; then cmd_web_start; fi ;;
    stop)
        cmd_stop
        if [ "${2:-}" = "--all" ]; then cmd_web_stop; fi ;;
    status)
        cmd_status
        if [ "${2:-}" = "--all" ]; then cmd_web_status; fi ;;
    web)
        case "${2:-start}" in
            start)  cmd_web_start  ;;
            stop)   cmd_web_stop   ;;
            status) cmd_web_status ;;
            log)    cmd_web_log    ;;
            *) c_red "未知 web 子命令: $2"; exit 1 ;;
        esac ;;
    restart)  cmd_restart ;;
    log)      cmd_log     ;;
    fg)       cmd_fg      ;;
    relogin)  cmd_relogin ;;
    deps)     check_deps  ;;
    -h|--help|help) usage ;;
    *) c_red "未知命令: $1"; usage; exit 1 ;;
esac
```

### 4.3 实施前提

依次完成（顺序重要）：

1. **先做 §2 的 mykey.app_config**（不然 web 端口拿不到）
2. **再改 start_wechat.sh**（用 `get_web_port` 读 mykey）
3. **手动验证**：
   - `./start_wechat.sh start --web` → bot + web 都启
   - 浏览器访问 `http://localhost:<port>` 看 chat 界面
   - 在 web 里发消息 → 同时观察 wechat bot 是否收到（**应该不会**——它们是两个独立 GeneraticAgent 进程，见 §3.3）
   - `./start_wechat.sh web stop` → 只停 web，bot 继续跑
   - `./start_wechat.sh stop --all` → 都停

### 4.4 注意事项

- **wechat 和 web 是两个独立 agent 进程**——发到 wechat 的消息不会出现在 web，反之亦然。这是 §3 描述的设计。**用户预期要管理好**
- web 端口被占（如 launch.pyw 已经在跑同一端口）会启动失败；fallback 是 `get_web_port` 自动找空闲，但建议固定端口避免混乱
- 如果用户希望"web 和 wechat 共享对话"——这是另一个量级的问题（要么共进程，要么实现 IPC sync）。**不在本次范围**

---

## 5. WebUI 架构剖析（重点）

### 5.1 技术栈选择：Streamlit

`frontends/stapp.py`（243 行） + `stapp2.py`（1049 行，更复杂的版本） 都基于 **[Streamlit](https://streamlit.io/)**。

**Streamlit 选型的优势**：
- ✅ Python-only：没有 React/Vue/前端构建链
- ✅ 内置 chat UI 组件（`st.chat_input` / `st.chat_message`）
- ✅ session state + reactive rerun 模型简单
- ✅ 内置长连接 / WebSocket 处理
- ✅ 部署简单：一行 `streamlit run xxx.py`

**Streamlit 的代价**：
- ❌ 整页 rerun 模型：任何 input 变化都重跑整个 script，难做精细 partial update（虽然有 `@st.fragment`）
- ❌ 难做高定制 UI（深度 CSS / 自定义组件麻烦）
- ❌ 服务端单进程模型，多用户并发需要副本
- ❌ JS 注入只能通过 `streamlit.components.v1.html`，受限于 iframe sandbox

### 5.2 stapp.py 的核心架构（v1 - 243 行）

#### 5.2.1 启动序列

```
streamlit run stapp.py
  │
  ├── @st.cache_resource init() (line 23-29)
  │   └── 创建 GeneraticAgent + 启动 agent.run() 后台线程
  │       (cache_resource 保证整个 streamlit server 生命周期内只创建一次)
  │
  ├── 渲染 sidebar (line 38-95)
  │   ├── LLM 选择 selectbox
  │   ├── 强行停止任务 / 重新注入工具 / 桌面宠物 按钮
  │   └── 自主行动开关
  │
  ├── 渲染历史消息 (line 151-158)
  │   └── 每条消息 fold_turns + render_segments
  │
  └── 处理 chat_input (line 后段)
      └── 触发 agent_backend_stream
```

#### 5.2.2 关键机制：Agent ↔ Streamlit 跨线程通信

```python
def agent_backend_stream(prompt):
    display_queue = agent.put_task(prompt, source="user")  # 把 prompt 入 agent.task_queue
    response = ''
    try:
        while True:
            try: item = display_queue.get(timeout=1)  # 阻塞读 1s
            except queue.Empty:
                yield response   # heartbeat: 让 streamlit 渲染 → 检查 abort
                continue
            if 'next' in item:
                response = item['next']; yield response
            if 'done' in item:
                yield item['done']; break
    finally: agent.abort()
```

**机制**：
- `agent.put_task()` 把任务放进 agent 的 queue（agent 后台线程在跑 `agent.run()` 循环）
- `display_queue` 是 agent 推流过来的输出队列
- 流式 yield 给 streamlit 的 `st.write_stream()` 用
- **timeout=1 是关键**：让 streamlit 有机会检测 abort 信号、刷新页面
- `finally: agent.abort()` 防止 streamlit 异常退出时 agent 还在跑

#### 5.2.3 关键机制：Turn 折叠渲染

`fold_turns()`（line 97-125）：
- 把流式输出按 `**LLM Running (Turn N) ...**` 标记切段
- 每段除最后段外，提取 `<summary>` 作为标题
- 最后段不折叠（当前正在生成）

`render_segments()`：
- 每个 fold 段用 `st.expander(title, expanded=False)` 包装
- 最后段用 `st.markdown()` 直接渲染

**效果**：长 session 不会撑爆页面，过去的 turn 折叠成"📑 标题"，点开看详情。

#### 5.2.4 关键机制：Session State 与 Rerun

Streamlit 的 reactive 模型：
- `st.session_state.messages` 持久化对话历史（每个用户 session 独立）
- 用户 chat_input → 整个 script rerun
- 通过 `if "messages" not in st.session_state` 模式判定首次还是 rerun
- `st.rerun()` 主动触发重渲染（如切 LLM 后）

**`@st.fragment`**（line 38）：
- 装饰 `render_sidebar`
- fragment 内部 rerun 不会重跑外部 script
- 减少不必要的全页 rerun

#### 5.2.5 边角处理（暴露设计成熟度）

读 line 167-178 的 `_js_scroll_fix`：
- Streamlit expander 折叠/展开动画过程中可能留下幻影高度
- 注入 JS：监听 `transitionend` 事件 + MutationObserver，触发 `m.style.minHeight` 重排
- 解决"滚动条很长但滚不到底部"的 bug

读 line 178-... 的 `_js_ime_fix`（macOS-only）：
- 修复中文输入法 composition 期间 Enter 误触发 submit

**这些 hack 显示 Streamlit 不是为这种 long-streaming chat 场景设计的**，原作者花了很多力气把它打磨能用。

### 5.3 stapp2.py vs stapp.py（v2 vs v1）

`stapp2.py` 是 1049 行，4 倍于 `stapp.py`。猜测是迭代增强版（更多功能：多会话、文件上传、多模态、工具面板等）。**调研建议**：你接下来打造 WebUI 时，优先以 stapp2 为基线，stapp 作为简化对比参考。

未在本次详细分析；建议你下次开工时单独读一遍 stapp2.py 评估"哪些是值得保留的功能"。

### 5.4 chatapp_common.py 提供的共享能力

不只是 web，所有 frontend 都用这一份（`chatapp_common.py:248` `class AgentChatMixin`）：

- `clean_reply` / `extract_files` / `strip_files` / `split_text`：消息后处理
- `format_restore` / `_restore_log_files` / `_restore_native_history`：跨 frontend 历史恢复
- `build_done_text`：完成消息构建
- `public_access` / `to_allowed_set` / `allowed_label`：权限白名单
- `ensure_single_instance`：端口锁单例
- `require_runtime` / `redirect_log`：启动校验 + 日志重定向
- `AgentChatMixin`：被 bot frontends 继承的 chat 能力基类

**所以 web 和 bot 的"chat 行为一致性"在这一层保证**——切换 frontend 不应该感觉到行为差异。

### 5.5 WebUI 的扩展点

如果按 `PROJECT_DIRECTION.md` §4.4.2 整合方向 A（统一 launcher），WebUI 是核心舞台。可能的扩展方向：

**A. 服务管理面板**（合并 hub.pyw 功能进来）：
- 侧边栏加一个"Services"区
- 列出 reflect/* 和 frontends/*app* 服务
- 启停按钮 + 状态指示
- 点击查看服务输出 log
- 借鉴 `hub.pyw` 的 `discover_services` + `ServiceManager` 逻辑

**B. v3 Evolution Engine 仪表盘**（与 §4.2 阶段 1-5 联动）：
- Tracer 当前 session 的 trace 实时展示
- Lessons drafts 数量 badge + 点开查看
- Memory git log 面板（最近 commits + diff 预览）
- Replay Pool 命中提示
- Arena bench 结果对比图

**C. 工具盒整合**：
- 自定义工具按钮（一键触发 `code_run({inline_eval:true, ...})` 类的快捷动作）
- 文件浏览器（看 `memory/` 下的文件）
- SOP 编辑器（直接在 WebUI 里改 SOP，触发 file_patch）
- 命令历史 / 收藏夹

**D. 多模态增强**：
- 拖拽上传图片 / 文件
- 截图（macOS Cmd+Ctrl+Shift+4 风格）
- 录音 + 转写

**E. 跨 frontend session 探索器**：
- 列出所有 PID 的 `model_responses_*.txt`
- 按时间 / 内容关键词搜索
- 一键 `/continue` 恢复（含跨 frontend 来源）

### 5.6 WebUI 的几个可能瓶颈

如果未来要做"专属 agent"主入口，这些是潜在痛点：

1. **Streamlit 单页 rerun 模型**：复杂工具盒可能会被 rerun 卡。考虑用 `@st.fragment` 隔离更多面板
2. **session 隔离性**：Streamlit 默认每个浏览器 tab 一个 session，但 `@st.cache_resource` 跨 session 共享 GeneraticAgent → 多 tab 操作同一 agent 可能竞态。要不要支持"多 tab 多 session"是个产品决策
3. **服务端推送**：Streamlit 没有原生 server-push API；目前用"后台线程 + queue + yield"绕过——能用但脆弱。如果未来想加"agent 主动通知用户"功能（不只是 idle injection），可能要换底座
4. **移动端**：Streamlit 移动端不友好。如果要手机用，可能需要 PWA 或独立 mobile UI
5. **替代选型评估**（如果 Streamlit 限制成为瓶颈）：
   - **Gradio**：与 Streamlit 类似，对 chat 更友好，但生态小
   - **FastAPI + 自定义前端**（React/Vue/Svelte）：完全自由但工作量爆炸
   - **NiceGUI**：Python-native UI，比 Streamlit 自由，比 FastAPI 简单
   - **Textual + Web**：终端 UI 也能映射到 web

**短期**：继续 Streamlit。**只有当 Streamlit 真的卡到无法绕过**才换。

### 5.7 建议

1. **WebUI 升级路径分阶段**：
   - 第 1 步：完成 §2 端口固定 + §4 wechat-web 整合（让用户能稳定通过浏览器使用）
   - 第 2 步：在 stapp2.py 基础上扩展（不要从零写新 UI）
   - 第 3 步：按 §5.5 的 A-E 方向，按当前痛点优先级实施
2. **保留 launch.pyw**：它的 idle injection 短期没替代方案；让它继续作为"桌面专属入口"
3. **WebUI = 主入口，launch.pyw = 桌面入口**：两条路并存，使用场景不同
   - WebUI：日常用、跨设备访问（手机、平板、其他电脑）、远程访问
   - launch.pyw：桌面深度集成场景（autonomous idle injection、与 desktop_pet 联动）

---

## 6. 综合：本次调研的可执行清单

按依赖顺序排列。每项独立可交付。

| ID | 任务 | 工作量 | 依赖 |
|---|---|---|---|
| **R-1** | mykey.py 加 `app_config` dict + `mykey_template*.py` 同步 | XS | — |
| **R-2** | `launch.pyw` `find_free_port` → `resolve_port`，读 mykey.app_config | XS | R-1 |
| **R-3** | 验证：mykey 配 fixed port → launch.pyw 用该端口；改 0 → 自动 | XS | R-2 |
| **R-4** | `start_wechat.sh` 加 web 子命令 + `get_web_port` 函数 | S | R-1 |
| **R-5** | 验证：`./start_wechat.sh start --web` 同时启 bot + web | XS | R-4 |
| **R-6** | 跨 frontend session 共享体验调研：写一个 `/sessions` 命令列出所有 PID 的会话 | S | — |
| **R-7** | （可选）"WebUI 服务管理面板"原型：在 stapp.py 侧边栏加 hub.pyw 的服务列表 | M | R-2 |

R-1 至 R-5 是本次讨论的直接落地；R-6 / R-7 是顺势延伸。

**不在本次范围**：
- WebUI 替换 Streamlit（太大，等真痛了再说）
- 跨 frontend 实时 session sync（破坏 loose coupling 哲学）
- launch.pyw 完全替换为纯 web（idle injection 没替代方案）

---

## 7. 文档版本历史

- **v1.0 (2026-05-03)**：首版。基于对 `launch.pyw` / `hub.pyw` / `start_wechat.sh` / `frontends/stapp*.py` / `frontends/chatapp_common.py` / `frontends/*.py` 的 file:line 级取证。回答 5 个用户问题：launcher GUI 必要性 / 端口配置 / 多 frontend 记忆共享模型 / wechat-web 整合方案 / WebUI 架构。

---

> **致未来的 taliszhou**：本文档 §3 的"多 frontend 之间记忆共享真实模型"是隐藏的设计精髓——不要在未来某天为了"统一 session"去强行加 IPC，那会破坏 GA 哲学。要的是"loose coupling + filesystem-mediated"，配合 v3 Evolution Engine（Replay Pool 等）来达成"跨 frontend 经验共享"，不是状态共享。
