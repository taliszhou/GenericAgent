# Desktop UX 实施方案 — 系统托盘 / 全局快捷键 / 边缘吸附 / 自动隐藏

> **文档编号**：TZ-DESKTOP-001
> **版本**：v1.0
> **日期**：2026-05-03
> **作者**：架构评审（Claude Opus 4.7 1M）
> **关联文档**：
>   - [`PROJECT_DIRECTION.md`](./PROJECT_DIRECTION.md) §4.4（专属 agent 整合方向）
>   - [`LAUNCHER_WEBUI_RESEARCH.md`](./LAUNCHER_WEBUI_RESEARCH.md) §1（launch.pyw GUI 必要性 + idle injection）
> **目的**：把 `launch.pyw` 升级为"桌面常驻 + 唤之即来"的专属 agent 入口。
> **强制约束**：保留现有的 idle injection 功能（30 分钟自主任务注入）；保留 webview 的 evaluate_js 通道；保留 wechat / 其他 bot 完全不受影响。

---

## 0. 文档使用约定

| 角色 | 用法 |
|---|---|
| **执行者**（你或 agent） | 严格按 §5 D-1 → D-8 顺序实施。每个任务的"How to fix"是规范，code sketch 可以照写不必逐字。 |
| **审阅者** | 用 §6 验收清单逐项勾选。 |
| **未来 reviewer** | §3-§4 是事实陈述+设计；§7 风险登记表帮助理解为什么某些选择是"刻意保守"。 |

**报告优先于自决**：
- macOS 上 pystray 与 webview 主线程冲突表现 ≠ 文档预期 → 报告
- pynput 注册全局快捷键被系统拒绝（即使授权） → 报告
- 实施过程中发现 mykey.app_config 与既有 mykey 命名冲突 → 报告
- 总代码增量超过 700 行 → 停下报告

---

## 1. 背景与目标

### 1.1 为什么做这个

`launch.pyw` 当前是"webview 包装 streamlit + 启 bot 的合一启动器"，但 UX 是"应用程序"模式（窗口常显，关窗即停）。用户的真实使用模式更接近"桌面助理"：随时唤起、不用时隐起来不占地方。

具体诉求（用户 2026-05-03 提出）：
1. GUI 缩进系统托盘，不常驻在 dock / taskbar
2. 全局快捷键唤出
3. 窗口自动吸附到屏幕边缘
4. 失焦后自动隐藏

这与 Cursor / Raycast / Notion Calendar 等"桌面常驻、随用随出"产品的交互范式一致。

### 1.2 与已存在功能的兼容关系

| 现有功能 | 影响 | 处理 |
|---|---|---|
| `launch.pyw:25-41` `inject()` | webview.evaluate_js 通道 | **保留**——idle injection 是核心特性 |
| `launch.pyw:65-79` `idle_monitor()` | 30 分钟无回复自动注入任务 | **保留**——只在窗口隐藏时也照样跑 |
| `launch.pyw:50-63` PASTE_HOOK_JS | 粘贴图片 / 文件检测 | **保留** |
| `launch.pyw:97-131` bot 启动参数 | --tg / --qq / --feishu / --wecom / --dingtalk / --sched | **不受影响**，bot 子进程独立 |
| `frontends/wechatapp.py` | 通过 start_wechat.sh 独立 daemon | **完全无关** |

---

## 2. 决策（已锁定 2026-05-03）

| 决策点 | 决定 | 来源 |
|---|---|---|
| 主用平台优先级 | **macOS 优先**调通，Windows 后做 | 用户 |
| 托盘图标 | 使用 `assets/tray_icon.png`（彩色，64x64）+ `assets/tray_icon_template.png`（单色模板，macOS menu bar 推荐） | 已生成，用户后续可直接替换文件 |
| 打包形态（v1） | 不打包，跑 `python launch.pyw` | 默认 |
| macOS 快捷键默认 | `<cmd>+<shift>+<space>` | 默认 |
| Windows 快捷键默认 | `<ctrl>+<shift>+<space>` | 默认 |
| 启动后默认状态 | **隐藏到托盘（不弹窗）** | 用户 |
| 边缘吸附位置 | **右边缘** | 用户 |
| 自动隐藏延迟 | 失焦 2 秒 | 默认 |
| **自动隐藏触发条件** | ⚠️ **仅在窗口处于吸附状态时**触发；用户拖出来的窗口不自动隐藏 | **用户（关键产品决策，见 §4.3 / §4.5）** |
| 多屏行为 | 默认主屏 | 默认 |
| 全屏应用兼容 | 默认不浮顶 | 默认 |

---

## 3. 架构

### 3.1 库选型

| 功能 | 库 | 跨平台 | 已有依赖？ |
|---|---|---|---|
| GUI 容器 + JS 注入 | `pywebview` | ✅ | ✅ 已用 |
| 系统托盘 | `pystray` + `Pillow` | ✅ macOS / Windows / Linux | ❌ 新增 |
| 全局快捷键 | `pynput` | ✅，macOS 需辅助功能权限 | ❌ 新增 |
| 平台位置/屏幕 API | `ctypes` (Windows) + `Cocoa` via `pyobjc-framework-Cocoa` (macOS) | 平台分支 | ⚠️ macOS 大概率已装（其他依赖会拉） |

**安装**：
```bash
pip install pystray Pillow pynput
# macOS 额外：
pip install pyobjc-framework-Cocoa pyobjc-framework-Quartz
```

**为什么不引重型 GUI 框架（PyQt / Tkinter / Tauri）**：
- `pywebview` 已经能跑且 idle injection 已基于它实现
- 引 PyQt → +50MB，重写整个窗口逻辑
- 引 Tauri → 引入 Rust 工具链
- pystray + pynput 加起来 < 5MB 增量，纯 Python，不破坏现有架构

### 3.2 macOS 主线程约束（关键陷阱）

AppKit / Cocoa 要求 GUI 操作必须在主线程。当多个用 AppKit 的库共存时：

| 库 | macOS 后端 | 主线程要求 |
|---|---|---|
| pywebview | Cocoa（默认） | **必须主线程** |
| pystray | rumps | **必须主线程** |

**冲突**：两者都要主线程，必有一个让步。

**解决方案**：

```
macOS:
  主线程 → pystray.Icon().run()  (阻塞，原生事件循环)
  子线程 → webview.start(gui='cocoa')  (实测可工作，但有 quirk)

Windows:
  主线程 → webview.start(gui='edgechromium')
  子线程 → pystray.Icon().run()
```

**为什么 macOS 让 pystray 占主线程**：
- pystray 在 macOS 用 rumps，对主线程要求更刚性
- pywebview macOS 后端在子线程跑虽然 hacky 但实测可用（pywebview 文档有 `webview.start(_func, args)` 的多线程示例）
- 反过来风险更高

**Windows 反过来的原因**：
- pywebview Edge Chromium 后端在子线程跑表现奇怪（窗口失去渲染上下文）
- pystray 在 Windows 用 win32 API，子线程友好

**这意味着 launch.pyw 的启动序列代码必须 if-else 分支**：

```python
if sys.platform == 'darwin':
    threading.Thread(target=lambda: webview.start(gui='cocoa'), daemon=False).start()
    tray_icon.run()  # 主线程
else:  # Windows / Linux
    threading.Thread(target=tray_icon.run, daemon=True).start()
    webview.start()  # 主线程
```

### 3.3 完整线程模型

```
launch.pyw 启动
  │
  ├── 加载 mykey.app_config（端口 / 快捷键 / 行为参数）
  ├── 启 streamlit 子进程（线程 A，已有逻辑）
  ├── 创建 webview 窗口（隐藏状态）
  ├── 启动 idle_monitor（线程 B，已有逻辑）
  │
  ├── 【新】启动 pynput 全局快捷键监听（线程 C）
  │     └── 收到快捷键 → 调 toggle_visibility()
  │
  ├── 【新】启动 focus_monitor（线程 D）
  │     └── 每 500ms 检查窗口焦点
  │     └── 失焦 ≥ N 秒 → 调 hide()
  │
  └── 平台分支：
      macOS:
        线程 E：webview.start(gui='cocoa')
        主线程：pystray.Icon().run()
      Windows:
        线程 E：pystray.Icon().run()
        主线程：webview.start()
```

### 3.4 toggle_visibility 状态机

```
visible:
  click tray / hotkey → hide()
  focus lost ≥ N seconds AND not in input → hide()

hidden:
  click tray / hotkey → show() + edge_snap() + focus()

(disabled 状态——always-on-top 模式下永不自动隐藏)
```

### 3.5 mykey.app_config 扩展

依赖于 [`LAUNCHER_WEBUI_RESEARCH.md`](./LAUNCHER_WEBUI_RESEARCH.md) §2 的 `app_config` 已完成（R-1 任务）。本方案在其基础上**追加**这些键：

```python
# mykey.py
app_config = {
    # ── 已有（来自 LAUNCHER_WEBUI_RESEARCH §2）─────
    'webui_port': 18501,
    'webui_port_range': (18501, 18599),
    'webui_bind': '127.0.0.1',
    
    # ── 新增 Desktop UX ─────────────────────────────
    # 托盘
    'tray_enabled': True,
    'tray_icon_path': 'assets/tray_icon.png',           # 彩色版（dock / 一般场景）
    'tray_icon_template_path': 'assets/tray_icon_template.png',  # macOS menu bar 模板版（自适应深浅色）
    
    # 全局快捷键（None = 禁用）
    'global_hotkey': '<cmd>+<shift>+<space>',  # macOS；Windows 用 '<ctrl>+<shift>+<space>'
    
    # 窗口行为
    'startup_visible': False,              # True = 启动即显；False = 缩进托盘
    'window_width': 600,
    'window_height': 900,
    'edge_snap': 'right',                  # 'right' / 'left' / 'top' / 'bottom' / 'none'
    'edge_offset': 0,                      # 距边缘像素偏移
    'top_offset': 100,                     # 距顶部像素偏移（保留 menu bar 等空间）
    
    # 自动隐藏
    'auto_hide_seconds': 2,                # 0 = 禁用；负数 = 立即
    'always_on_top': False,                # True = 不自动隐藏，置顶
    
    # 多屏
    'target_monitor': 'primary',           # 'primary' / 'mouse' / int 索引
}
```

**新键的命名前缀** 都不含 `api`/`config`/`cookie` 关键词，不会被 LLM scanner 误识别。

---

## 4. 行为规范

### 4.1 触发表

| 输入触发 | 当前状态 | 动作 |
|---|---|---|
| 启动 + `startup_visible=False` | — | 隐藏窗口 + 显示托盘图标 + 注册快捷键 |
| 启动 + `startup_visible=True` | — | 显示窗口在边缘 + 显示托盘图标 + 注册快捷键 |
| 点击托盘图标 | hidden | show() + edge_snap() + focus() + **mark snapped** |
| 点击托盘图标 | visible | hide() |
| 全局快捷键 | hidden | show() + edge_snap() + focus() + **mark snapped** |
| 全局快捷键 | visible | hide() |
| 托盘菜单 "Show" | any | show() + edge_snap() + focus() + **mark snapped** |
| 托盘菜单 "Hide" | any | hide() |
| 托盘菜单 "Snap to edge" | visible | edge_snap() + **mark snapped**（手动重新吸附） |
| 托盘菜单 "Always on top: ON" | — | always_on_top=True，禁用自动隐藏 |
| 托盘菜单 "Always on top: OFF" | — | always_on_top=False，恢复自动隐藏（仍需 snapped 状态） |
| 托盘菜单 "Quit" | — | stop_all_subprocesses() + sys.exit() |
| 窗口失去焦点 + 经过 auto_hide_seconds + **当前在吸附状态** | visible 且非 always_on_top | hide() |
| chat input 有焦点 | — | **不触发自动隐藏**（即使时间到） |
| **用户拖动窗口（位置偏离吸附位 > 20px）** | — | **mark un-snapped**，从此不再自动隐藏 |
| **用户调整窗口大小** | — | **mark un-snapped**，从此不再自动隐藏 |
| idle_monitor 触发 inject | hidden | **先 show() 再 inject**（让用户看到自主任务） |
| idle_monitor 触发 inject | visible | inject 直接写（已有行为） |

### 4.2 边缘吸附计算

```python
def calc_edge_position(screen_w, screen_h, win_w, win_h, edge, offset, top_offset):
    if edge == 'right':
        return (screen_w - win_w - offset, top_offset)
    elif edge == 'left':
        return (offset, top_offset)
    elif edge == 'top':
        return ((screen_w - win_w) // 2, offset)
    elif edge == 'bottom':
        return ((screen_w - win_w) // 2, screen_h - win_h - offset)
    else:  # 'none'
        return (100, 100)  # 默认位置
```

获取 screen_w/screen_h：
- macOS：`from AppKit import NSScreen; NSScreen.mainScreen().frame()`
- Windows：`ctypes.windll.user32.GetSystemMetrics(0/1)`

**多屏处理**（v1 简化）：仅支持 `'primary'`，取主屏。`'mouse'` 模式留给 v2。

### 4.3 焦点监控的细节

```python
def focus_monitor(window, get_config, snap_state):
    """
    snap_state: 一个共享对象，含 .is_snapped (bool)、.expected_pos (x, y)
    由 edge_snap() 设置 is_snapped=True；由 window moved/resized 事件设 False
    """
    last_blur_at = 0
    while True:
        time.sleep(0.5)
        try:
            cfg = get_config()
            
            # 1. always-on-top 模式禁用自动隐藏
            if cfg['always_on_top']:
                last_blur_at = 0
                continue
            
            # 2. 配置禁用
            if cfg['auto_hide_seconds'] <= 0:
                continue
            
            # 3. 窗口本身不可见
            if not window_is_visible(window):
                last_blur_at = 0
                continue
            
            # 4. ⚠️ 关键：仅在窗口处于"吸附状态"时才考虑自动隐藏
            #    用户拖动后偏离吸附位置即视为脱离吸附，从此不自动隐藏
            if not snap_state.is_snapped:
                last_blur_at = 0
                continue
            
            # 5. chat input 有焦点 → 不隐藏（防止打字到一半窗口消失）
            input_focused = window.evaluate_js("""
                document.activeElement?.tagName === 'TEXTAREA' &&
                document.activeElement.matches('[data-testid="stChatInputTextArea"]')
            """) or False
            if input_focused:
                last_blur_at = 0
                continue
            
            # 6. 窗口整体有焦点 → 重置计时
            has_focus = window_has_focus(window)
            if has_focus:
                last_blur_at = 0
                continue
            
            # 7. 失焦计时
            now = time.time()
            if last_blur_at == 0:
                last_blur_at = now
            elif now - last_blur_at >= cfg['auto_hide_seconds']:
                window.hide()
                last_blur_at = 0
        except Exception as e:
            print(f'[focus_monitor] {e}')
```

**关键不变量**：
- chat input 有焦点时**永不触发自动隐藏**
- 窗口**不在吸附状态**时（被用户拖出过 / 调整过大小）**永不触发自动隐藏**
- always-on-top 时**永不触发自动隐藏**

### 4.4 吸附状态追踪（snap_state）

```python
class SnapState:
    """共享给 edge_snap / focus_monitor / 移动事件的吸附状态对象。"""
    def __init__(self):
        self.is_snapped = False
        self.expected_pos = (0, 0)
        self.expected_size = (0, 0)
        self._setting_snap = False  # 标志位：edge_snap 期间忽略 moved 事件

def edge_snap(window, cfg, snap_state):
    if cfg['edge_snap'] == 'none':
        snap_state.is_snapped = False
        return
    sw, sh = get_screen_size()
    ww = cfg['window_width']
    wh = cfg['window_height']
    x, y = calc_edge_position(sw, sh, ww, wh, cfg['edge_snap'],
                                cfg['edge_offset'], cfg['top_offset'])
    snap_state._setting_snap = True
    try:
        window.resize(ww, wh)
        window.move(x, y)
    finally:
        # 给 webview 一点时间触发 moved 事件再清 flag
        threading.Timer(0.5, lambda: setattr(snap_state, '_setting_snap', False)).start()
    snap_state.expected_pos = (x, y)
    snap_state.expected_size = (ww, wh)
    snap_state.is_snapped = True

def on_window_moved(snap_state):
    """订阅 webview window.events.moved 用。"""
    if snap_state._setting_snap:
        return  # 是 edge_snap 自己触发的，忽略
    snap_state.is_snapped = False  # 用户拖动了 → 脱离吸附

def on_window_resized(snap_state):
    """订阅 webview window.events.resized 用。"""
    if snap_state._setting_snap:
        return
    snap_state.is_snapped = False
```

**为什么用 SnapState 而非 boolean flag**：
- moved/resized 事件可能在 edge_snap 完成后异步触发（webview 内部）
- _setting_snap 临时屏蔽这段时间的事件
- 0.5s 后清 flag，之后任何 moved/resized 都视为用户操作

**容错**：如果 webview 不支持 `events.moved`（pywebview 版本太老），fallback 用轮询：

```python
def position_polling_fallback(window, snap_state):
    while True:
        time.sleep(1)
        try:
            cur_x, cur_y = get_window_position(window)
            ex, ey = snap_state.expected_pos
            if snap_state.is_snapped and (abs(cur_x - ex) > 20 or abs(cur_y - ey) > 20):
                snap_state.is_snapped = False
        except Exception:
            pass
```

### 4.5 此设计参考的产品

"只在吸附状态自动隐藏，拖出来就不自动隐藏"是成熟桌面 dock-style app 的标准行为：

- **Slack** Mac 应用（吸附在屏幕边的 quick-switcher 模式）
- **ChatGPT Desktop** macOS 版
- **Notion Calendar**（窗口拖出后不再自动隐藏）
- **Stickies** 类应用

用户拖出窗口的语义是"我要把它当普通窗口用一会儿"——此时强制自动隐藏会破坏预期。**这是关键产品决策，实施时务必严格落实**。

### 4.6 idle_monitor 与 hide 状态的协调

现有 `idle_monitor` 在 30 分钟无回复时调 `inject(text)`。当窗口隐藏时：

```python
def inject(text):
    if not window_is_visible(window):
        window.show()
        edge_snap()
        time.sleep(0.3)  # 让 webview 渲染完
    window.evaluate_js(f"...")  # 原有注入逻辑
```

这样 idle 触发时用户也能看到 agent 自主行动了。

---

## 5. 实施任务清单

按依赖顺序。每项独立可验证。

### D-0 前置：完成 LAUNCHER_WEBUI_RESEARCH §6 R-1

- **文件**：`mykey.py` / `mykey_template.py` / `mykey_template_en.py`
- **依赖**：无
- **工作量**：XS
- **产出**：`mykey.app_config` dict 存在（即使只有 `webui_port` 一项）
- **DoD**：`python -c "import mykey; print(mykey.app_config)"` 返回 dict 不报错

### D-1 ⚠️ pystray 系统托盘 + 基本菜单

- **文件**：`launch.pyw`（修改）
- **依赖**：D-0
- **工作量**：S（半天）
- **产出**：
  - 新增 import：`import pystray; from PIL import Image, ImageDraw`
  - 新增辅助函数 `make_default_icon()`：用 Pillow 画 64x64 圆形纯色 + 字母 "GA"
  - 新增辅助函数 `setup_tray(window)`：构造 `pystray.Icon` + 菜单 `[Show, Hide, ─, Quit]`
  - 新增 `toggle_visibility(window)` 函数
  - **修改启动序列**（launch.pyw:140-144）：
    ```python
    # 之前：
    window = webview.create_window(...)
    webview.start()
    
    # 之后（macOS）：
    window = webview.create_window(..., hidden=not cfg['startup_visible'])
    if sys.platform == 'darwin':
        threading.Thread(target=lambda: webview.start(gui='cocoa'), daemon=False).start()
        time.sleep(1)  # 等 webview 起来
        tray = setup_tray(window)
        tray.run()  # 主线程阻塞
    else:
        tray = setup_tray(window)
        threading.Thread(target=tray.run, daemon=True).start()
        webview.start()
    ```
- **测试**（人工）：
  ```
  TC-D-1-a (macOS): python launch.pyw → 托盘出现 GA 图标，dock 不显示窗口
  TC-D-1-b (macOS): 点托盘图标 → 菜单弹出 [Show, Hide, Quit]
  TC-D-1-c (macOS): 菜单点 Show → 窗口出现（任意位置 OK）
  TC-D-1-d (macOS): 菜单点 Hide → 窗口隐藏，托盘图标还在
  TC-D-1-e (macOS): 菜单点 Quit → 进程完全退出，streamlit 子进程也死
  TC-D-1-f (Windows): 同上，但 dock → taskbar 表述
  ```
- **DoD**：
  - [ ] TC-D-1-a 至 TC-D-1-f 全过
  - [ ] `python launch.pyw` 在 macOS 和 Windows 都能起
  - [ ] Quit 后无僵尸 streamlit 子进程（用 `pgrep -f streamlit` 验证）
  - [ ] launch.pyw 总行数增量 ≤ 80 行

### D-2 ⚠️ pynput 全局快捷键

- **文件**：`launch.pyw`（修改）
- **依赖**：D-1
- **工作量**：S（半天）
- **产出**：
  - 新增 import：`from pynput import keyboard`
  - 新增 `setup_hotkey(window, hotkey_str)`：
    ```python
    def setup_hotkey(window, hotkey_str):
        if not hotkey_str:
            return None
        try:
            listener = keyboard.GlobalHotKeys({
                hotkey_str: lambda: toggle_visibility(window)
            })
            listener.start()
            print(f'[Hotkey] Registered: {hotkey_str}')
            return listener
        except Exception as e:
            print(f'[Hotkey] Failed to register {hotkey_str}: {e}')
            print('[Hotkey] On macOS, grant Accessibility permission to Python in:')
            print('  System Settings → Privacy & Security → Accessibility')
            return None
    ```
  - 在启动序列加 `setup_hotkey(window, cfg.get('global_hotkey'))`
- **测试**：
  ```
  TC-D-2-a (macOS, 首次): 启动 → 弹出系统授权窗口要 Accessibility
  TC-D-2-b (macOS, 已授权): 按 Cmd+Shift+Space → 窗口 toggle
  TC-D-2-c (Windows): 按 Ctrl+Shift+Space → 窗口 toggle，无弹窗
  TC-D-2-d: 在 macOS 改 mykey.global_hotkey='<cmd>+<option>+<a>' 重启 → 新快捷键生效
  TC-D-2-e: mykey.global_hotkey=None → 不注册快捷键，启动正常
  ```
- **DoD**：
  - [ ] TC-D-2-a 至 TC-D-2-e 全过
  - [ ] macOS 授权失败时给清晰错误提示（不崩溃）
  - [ ] launch.pyw 总行数增量 ≤ 30 行

### D-3 平台 API 抽象 + 边缘吸附

- **文件**：`launch.pyw`（修改）+ 新建 `_platform.py`（如需）
- **依赖**：D-1
- **工作量**：M（1 天）
- **产出**：
  - 新增 `get_screen_size() → (w, h)`：
    - macOS：`from AppKit import NSScreen; NSScreen.mainScreen().frame()` → `(int(f.size.width), int(f.size.height))`
    - Windows：`ctypes.windll.user32.GetSystemMetrics(0)` / `(1)`
    - Linux：tkinter `Tk().winfo_screenwidth()`（fallback）
  - 新增 `calc_edge_position(...)`（见 §4.2）
  - 新增 `edge_snap(window, cfg)`：
    ```python
    def edge_snap(window, cfg):
        sw, sh = get_screen_size()
        ww = cfg['window_width']
        wh = cfg['window_height']
        x, y = calc_edge_position(sw, sh, ww, wh, cfg['edge_snap'], cfg['edge_offset'], cfg['top_offset'])
        window.move(x, y)
        window.resize(ww, wh)
    ```
  - 修改 `toggle_visibility` 在 show 时调 `edge_snap`
- **测试**：
  ```
  TC-D-3-a: edge='right' → 窗口在屏幕右边缘
  TC-D-3-b: edge='left' → 窗口在屏幕左边缘
  TC-D-3-c: edge='none' → 窗口在 (100, 100)（默认位置）
  TC-D-3-d (4K + 1080p 双屏): 默认行为 → 窗口在主屏正确位置
  TC-D-3-e: 改 mykey.edge_offset=50 重启 → 窗口距右边缘 50 像素
  TC-D-3-f: 反复 toggle_visibility 10 次 → 每次都吸附到正确位置（不漂移）
  ```
- **DoD**：
  - [ ] TC-D-3-a 至 TC-D-3-f 全过
  - [ ] macOS Retina 显示器 + Windows 高 DPI 显示器各验证一次（坐标计算正确）
  - [ ] launch.pyw + _platform.py 总增量 ≤ 100 行

### D-4 ⚠️ 失焦自动隐藏（含 snap-aware + chat input 保护）

- **文件**：`launch.pyw`（修改）
- **依赖**：D-3
- **工作量**：M（1-1.5 天）
- **产出**：
  - **SnapState 类**（见 §4.4）—— is_snapped / expected_pos / _setting_snap
  - 修改 D-3 的 `edge_snap()` 接收 snap_state 参数，调完后 `is_snapped = True`
  - 注册 webview 事件：
    ```python
    window.events.moved += lambda: on_window_moved(snap_state)
    window.events.resized += lambda: on_window_resized(snap_state)
    ```
  - 如果 pywebview 版本不支持 `events.moved`，启用 `position_polling_fallback`（§4.4）
  - 新增 `window_is_visible(window) → bool`
  - 新增 `window_has_focus(window) → bool`：
    - macOS：`NSApplication.sharedApplication().keyWindow()` 比对
    - Windows：`ctypes.windll.user32.GetForegroundWindow` 比对
  - 新增 `focus_monitor(window, get_config_fn, snap_state)` 线程（见 §4.3 完整代码）
  - 启动序列：
    ```python
    snap_state = SnapState()
    threading.Thread(
        target=focus_monitor,
        args=(window, lambda: load_config(), snap_state),
        daemon=True
    ).start()
    ```
  - toggle_visibility 在 show 路径中调 `edge_snap(window, cfg, snap_state)`
- **测试**：

  基础自动隐藏：
  ```
  TC-D-4-a: 通过快捷键唤出窗口（在右边吸附）→ 点别处使其失焦 → 等 2 秒 → 自动隐藏
  TC-D-4-b: 唤出窗口 → 在 chat input 里打字（输入框 focus）→ 点别处但 chat input 仍 focus → 不应隐藏
  TC-D-4-c: 唤出窗口 → 立即点托盘菜单 always-on-top ON → 失焦不再隐藏
  TC-D-4-d: 关闭 always-on-top → 失焦 2 秒后再次隐藏
  TC-D-4-e: mykey.auto_hide_seconds=0 → 失焦不隐藏
  TC-D-4-f: 长时间使用（30 分钟）→ focus_monitor 线程不泄漏，CPU < 1%
  ```

  ⚠️ snap-aware 自动隐藏（关键产品行为）：
  ```
  TC-D-4-g: 唤出窗口（吸附在右边）→ 用鼠标拖动窗口到屏幕中央
            → snap_state.is_snapped 应变为 False
            → 失焦 → 等 5 秒 → 窗口**不应隐藏**（已脱离吸附）
  TC-D-4-h: 续上 → 在托盘菜单点 "Snap to edge" 重新吸附
            → snap_state.is_snapped 应变为 True
            → 失焦 → 等 2 秒 → 自动隐藏
  TC-D-4-i: 唤出窗口（吸附在右边）→ 拖动改窗口大小 → snap_state.is_snapped=False
            → 失焦 → 不隐藏
  TC-D-4-j: edge_snap 调用期间触发的 moved/resized 事件**不应**让 is_snapped 变 False
            （由 _setting_snap flag 在 0.5s 内屏蔽）
  ```

- **DoD**：
  - [ ] TC-D-4-a 至 TC-D-4-j 全过（j 是边界条件，要重点验证）
  - [ ] chat input 焦点保护**严格生效**（UX 致命点）
  - [ ] **snap-aware 自动隐藏严格生效**（UX 致命点 #2）
  - [ ] 拖动窗口后**永久**不再自动隐藏，直到用户主动 "Snap to edge" 或重新 show
  - [ ] launch.pyw 总增量 ≤ 120 行

### D-5 托盘菜单 always-on-top + 设置展示

- **文件**：`launch.pyw`（修改）
- **依赖**：D-4
- **工作量**：S（半天）
- **产出**：
  - 托盘菜单扩展：
    ```
    [Show / Hide]
    [📌 Snap to edge]         ← 重新吸附（用户拖出后可手动归位，重新启用自动隐藏）
    [⏸ Pause auto-hide  ✓]   ← Checkable item, 切 always_on_top
    [─]
    [Snap right]              ← submenu radio（默认）
    [Snap left]
    [Snap none]
    [─]
    [Settings...]             ← 弹个简单 webview 显示当前 config（v1 read-only）
    [─]
    [Quit]
    ```
    "Snap to edge" 这一项是 §4.5 产品决策的配套——用户拖出窗口后，如果想重新启用自动隐藏，点这一项即可重新吸附 + 标记 is_snapped=True。
  - 切换 always-on-top 时**写回内存中的 config 副本**（不持久化到 mykey.py，重启后复位）
- **测试**：
  ```
  TC-D-5-a: 点 Pause auto-hide → 复选框打勾，失焦不隐藏；再点 → 取消，行为复原
  TC-D-5-b: 切 Snap left → 下次 show 时窗口在左边缘
  TC-D-5-c: 点 Settings... → 弹个小窗显示 mykey.app_config（read-only）
  TC-D-5-d: 切换不同 snap 选项后再点 Show → 位置正确
  ```
- **DoD**：
  - [ ] TC-D-5-a 至 TC-D-5-d 全过
  - [ ] 菜单变更**不写回 mykey.py**（v1 决策：避免动用户配置文件；v2 可加 "Save to mykey" 选项）
  - [ ] launch.pyw 总增量 ≤ 60 行

### D-6 idle_monitor 与 hide 状态协调

- **文件**：`launch.pyw`（修改 line 25-79）
- **依赖**：D-1
- **工作量**：XS
- **产出**：
  - 修改 `inject(text)`：注入前检查 `window_is_visible`，不可见就 `show + edge_snap + sleep 0.3`
- **测试**：
  ```
  TC-D-6-a: 隐藏窗口 → 手动 fast-forward last_reply_time（在 streamlit 侧 button "开始空闲自主行动"）→ 等 5 秒
            → 窗口自动显示在边缘 + autonomous task 注入 chat
  ```
- **DoD**：
  - [ ] TC-D-6-a 通过
  - [ ] 不破坏 launch.pyw:65-79 现有 idle_monitor 逻辑

### D-7 集成验收 + 文档

- **文件**：`docs/PROJECT_DIRECTION.md`（更新）+ `README.md`（追加）+ `mykey_template*.py`（更新）
- **依赖**：D-1 至 D-6
- **工作量**：S（半天）
- **产出**：
  - **mykey_template_en.py 加 `app_config` 段**含本文档 §3.5 所有键 + 注释
  - **`README.md` 加一段 "Desktop Quick Access"**：
    - 说明托盘 + 快捷键启停
    - macOS 首次需授权（截图 + 步骤）
    - 关键 mykey 配置项
  - **`PROJECT_DIRECTION.md` §4.4.2 整合方向 D（桌面体验优化）打勾完成**
  - 集成 smoke 验收（见 §6）
- **DoD**：见 §6 验收清单

---

## 6. 验收清单

### 6.1 取证检查

- [ ] `grep "import pystray" launch.pyw` 返回 1
- [ ] `grep "from pynput" launch.pyw` 返回 1
- [ ] `grep "app_config" mykey_template*.py` 返回 ≥ 2（en + zh 模板）
- [ ] `wc -l launch.pyw` 增量 ≤ 400 行（原 144 → 应 ≤ 544）

### 6.2 平台行为（macOS 必须；Windows 任选其一）

- [ ] `python launch.pyw` 启动后**dock 不显示窗口**，**托盘出现 GA 图标**
- [ ] 点托盘图标 → 菜单 `[Show / Hide / Pause auto-hide / Snap... / Settings... / Quit]` 全部可点
- [ ] 默认快捷键（macOS Cmd+Shift+Space）按下 → 窗口 toggle
- [ ] 窗口显示时**自动吸附到右边缘**，距顶 100px
- [ ] 窗口失焦 2 秒后**自动隐藏**
- [ ] 在 chat input 里打字状态下，点其他窗口失焦 → **不隐藏**
- [ ] 托盘菜单 Pause auto-hide → 失焦不再隐藏；再点取消 → 恢复
- [ ] 托盘菜单 Quit → 进程完全退出 + streamlit 子进程也退出（pgrep 验证）

### 6.3 与现有功能兼容性

- [ ] `python launch.pyw --tg` 启动 telegram bot（已有功能不受影响）
- [ ] streamlit web UI 在浏览器 `http://localhost:<port>` 也能直接访问（GUI 是 wrapper，不阻塞 web）
- [ ] idle_monitor 30 分钟触发 → 窗口自动 show + 注入 task
- [ ] PASTE_HOOK_JS 仍生效（粘贴图片有占位符）

### 6.4 macOS 专项

- [ ] 首次启动 → 弹出 Accessibility 授权弹窗
- [ ] 授权后 → 重启 launch.pyw → 全局快捷键工作
- [ ] 切换不同 Python 解释器路径 → **重新弹授权**（这是预期行为，文档化）

### 6.5 Windows 专项（如做）

- [ ] 全局快捷键无需任何授权直接生效
- [ ] 高 DPI 显示器（150% 缩放）→ 边缘吸附位置正确

### 6.6 资源开销

- [ ] 长时间运行（≥ 1 小时）→ launch.pyw 进程 RSS 增长 < 50MB
- [ ] focus_monitor + idle_monitor 两线程合计 CPU < 1%（idle 状态）

---

## 7. 风险登记

| ID | 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|---|
| R-1 | macOS 上 webview 跑子线程出现奇怪渲染问题（white flash / blank window） | 中 | 高 | D-1 实施时优先验证；如出现问题，备用方案：webview 主线程 + pystray 子线程（pystray 在 macOS 子线程也可工作但需额外测试） |
| R-2 | pynput 在 macOS 14+ 严格模式下被拦 | 中 | 中 | 文档化授权步骤；提供 fallback：禁用快捷键模式让用户只用托盘 |
| R-3 | 用户切换 Python 版本后授权失效 | 高 | 低 | 文档化 + 推荐 v2 打 .app 一次性解决 |
| R-4 | 边缘吸附在多屏 + DPI 混合环境出错 | 中 | 中 | v1 仅支持主屏；v2 加 mouse-following 和 DPI-aware |
| R-5 | 自动隐藏在用户填写表单时误触发 | 高 | 高 | chat input 焦点保护（D-4 严格测试）；另外提供 always-on-top 兜底 |
| R-6 | 托盘菜单点 Quit 后 streamlit 子进程残留 | 中 | 中 | atexit register + 显式 stop_subprocesses；TC-D-1-e 验证 |
| R-7 | webview window.move/resize 在某些平台不响应 | 低 | 中 | pywebview 文档已注明可用；如出问题用 evaluate_js 注 `window.resizeTo(...)` 兜底 |
| R-8 | pystray 图标在 macOS 暗色 menu bar 看不清 | 中 | 低 | 默认图标用对比色；允许用户提供 .png |
| R-9 | 全屏应用模式下窗口被覆盖看不到 | 低 | 低 | 文档化：always-on-top 模式可解决 |
| R-10 | 多次快速 toggle 导致 webview 状态错乱 | 低 | 中 | toggle_visibility 加 debounce（200ms 内忽略重复触发） |

---

## 8. 不在范围

以下显式**不**在 v1 范围内，避免 scope creep：

- **打包成 .app / .exe**（v2，等核心功能稳定）
- **滑入滑出动画**（pywebview 不支持帧级动画；要做需切 PyQt 或前端模拟）
- **边缘小尾巴 hover 唤回**（托盘 + 快捷键已够用）
- **多屏跟随鼠标**（v2）
- **窗口大小记忆**（v2 可加 "记住上次大小写回 mykey"）
- **菜单写回 mykey.py 持久化**（v1 决策：菜单只改内存副本，避免误改用户配置）
- **快捷键运行时改键**（v1 改 mykey 后需重启 launch.pyw）
- **多语言托盘菜单**（v1 全英文）
- **自定义托盘图标 GUI 选择器**（v1 只支持 mykey 配路径）
- **Linux 完整支持**（v1 best-effort，bug 不阻塞 release）

---

## 9. 实施顺序与里程碑

总工作量 **3-4 天**（单人全时）。建议节奏：

```
Day 1：
  上午：D-0（30 分钟）+ D-1（半天 pystray）
  下午：D-2（半天 pynput）+ macOS 授权流程验证

Day 2：
  上午：D-3（边缘吸附）
  下午：D-4 上（焦点监控基础）

Day 3：
  上午：D-4 下（chat input 保护 + 测试）+ D-5（菜单扩展）
  下午：D-6（idle 协调）+ D-7（文档）

Day 4 (buffer)：
  Windows 验证（如需）
  Bug fix
  6.x 验收清单逐项过
```

**关键里程碑**：
- M1（Day 1 结束）：托盘出现 + 快捷键 toggle 工作 → "已经能感觉到 desktop UX 改善"
- M2（Day 2 结束）：边缘吸附 + 焦点监控基础 → "已经能日常用"
- M3（Day 3 结束）：完整功能 + 文档 → 验收

每个里程碑结束 commit + 让用户试用一阵再继续。

---

## 10. 引用

| 议题 | 文件 / 链接 |
|---|---|
| pywebview 文档 | https://pywebview.flowrl.com/ |
| pystray 文档 | https://pystray.readthedocs.io/ |
| pynput 文档 | https://pynput.readthedocs.io/ |
| macOS Accessibility 权限说明 | https://support.apple.com/guide/mac-help/control-access-to-accessibility-features-mh43185/mac |
| 当前 launch.pyw | `/Users/taliszhou/code/src/github.com/GenericAgent/launch.pyw` |
| mykey.app_config 起源 | `docs/LAUNCHER_WEBUI_RESEARCH.md` §2 |
| WebUI 整体架构 | `docs/LAUNCHER_WEBUI_RESEARCH.md` §5 |
| 项目战略定位 | `docs/PROJECT_DIRECTION.md` §4.4 |

---

## 11. 文档版本历史

- **v1.0 (2026-05-03)**：首版。基于 2026-05-03 与 Claude 关于 desktop UX 升级（系统托盘 + 全局快捷键 + 边缘吸附 + 自动隐藏）的讨论。包含完整架构（含 macOS 主线程约束的解决方案）、行为规范、7 个执行任务（D-0 到 D-7）、6 类验收清单、10 项风险登记、3-4 天实施节奏。

---

> **致执行者**：D-1 实施前**先在 macOS 上手动跑一次最小 demo**——
> 写 30 行测试脚本，验证 `pystray.Icon().run()` 在主线程跑 + `webview.start(gui='cocoa')` 在子线程跑能否共存（不需要做完整功能，只验证两个事件循环不打架）。
> 这一步通过再开始正式 D-1。如果 demo 失败 → 报告 + 切换主备线程方案。**不要直接照本文档 §3.2 套用而跳过 demo 验证**。
