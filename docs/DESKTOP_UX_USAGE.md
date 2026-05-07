# Desktop UX 使用指南

> launch.pyw 的桌面快捷使用方式：系统托盘 + 全局快捷键 + 边缘吸附 + 自动隐藏。
> 实施背景见 [`DESKTOP_UX_PLAN.md`](./DESKTOP_UX_PLAN.md)。

## 快速开始

```bash
# 1. 装依赖（首次）
pip install pywebview pystray Pillow pynput
# macOS 额外：
pip install pyobjc-framework-Cocoa pyobjc-framework-Quartz

# 2. 启动（默认隐藏到托盘，不弹窗）
python launch.pyw

# 3. 唤出窗口
#    方式 A：点 menu bar 的 GA 图标 → Show
#    方式 B：按 Cmd+Shift+Space (macOS) / Ctrl+Shift+Space (Windows)
```

## 默认行为

| 触发 | 效果 |
|---|---|
| 启动 | 隐藏到托盘，不弹窗 |
| 点击托盘图标 | 弹菜单（左键单击 = Show 默认动作） |
| 按全局快捷键 | toggle 显示/隐藏 |
| 窗口显示时 | 自动吸附到右边缘 |
| 窗口失焦 ≥ 2 秒**且处于吸附状态** | 自动隐藏 |
| 用户拖动窗口（脱离吸附） | **不再自动隐藏**，直到点 "📌 Snap to edge" 或重启 |
| 在 chat input 里打字 | **不会自动隐藏**（输入保护） |

## 托盘菜单

```
[Show / Hide]            ← 显隐切换
[📌 Snap to edge]        ← 重新吸附（拖出后想恢复自动隐藏用）
[Pause auto-hide]        ← 切 always-on-top（暂停自动隐藏）
─
[Snap right]  ●          ← 边缘位置（radio）
[Snap left]
[Snap none]              ← 选这个 = 不吸附 = 永不自动隐藏
─
[Quit]                   ← 完全退出，所有子进程一起死
```

## CLI 参数

```bash
python launch.pyw                  # 默认：隐藏到托盘
python launch.pyw --show           # 启动即显示窗口
python launch.pyw --no-tray        # 不要托盘（窗口模式）
python launch.pyw --tg             # 同时启 Telegram bot（沿用旧逻辑）
python launch.pyw --qq --feishu    # 多 bot 一起启
python launch.pyw --sched          # 启计划任务调度器
python launch.pyw 18888             # 指定端口（覆盖 mykey.app_config.webui_port）
```

## macOS 首次授权

第一次按全局快捷键时，macOS 会弹窗"<某 Python 路径> 想要监听键盘"。

**步骤**：
1. 弹窗点 "Open System Settings"（或自己进 系统设置 → 隐私与安全性 → 辅助功能）
2. 找到 Python 解释器（路径形如 `/usr/bin/python3` 或 `/opt/homebrew/bin/python3` 或你的 venv 路径），打开开关
3. 重启 launch.pyw

**坑**：不同 Python 解释器（系统 Python vs Homebrew vs venv）需要分别授权。换 Python 版本后要重做。

如果不想授权 → mykey.app_config 把 `'global_hotkey'` 改成 `None`，只用托盘点击。

## mykey.app_config 关键项

```python
app_config = {
    'webui_port': 18501,                        # 固定端口；0 = 自动找空闲
    'global_hotkey': '<cmd>+<shift>+<space>',   # None = 禁用全局快捷键
    'startup_visible': False,                    # True = 启动即显示
    'edge_snap': 'right',                        # right / left / top / bottom / none
    'window_width': 600,
    'window_height': 900,
    'auto_hide_seconds': 2,                      # 0 = 禁用自动隐藏
    'always_on_top': False,
    'tray_icon_path': 'assets/tray_icon.png',                    # 替换这个文件即可换图标
    'tray_icon_template_path': 'assets/tray_icon_template.png',  # macOS menu bar 用（自适应深浅色）
}
```

完整字段见 [`DESKTOP_UX_PLAN.md`](./DESKTOP_UX_PLAN.md) §3.5。

## 替换 logo

直接替换 `assets/tray_icon.png` 和 `assets/tray_icon_template.png` 两个文件即可，不需要改代码。

- **彩色版** `tray_icon.png`：建议 64×64 或 128×128 PNG，带 alpha
- **模板版** `tray_icon_template.png`：macOS menu bar 推荐用纯黑/纯白单色，自动适配深浅色模式
  - 文件名带 `Template` 是 macOS 约定，pystray 不强制但建议保留这个文件分版本
- 想用其他路径 → mykey.app_config 改 `tray_icon_path`

## 与 wechat / 其他 bot 的关系

- `start_wechat.sh` 启动的 wechat bot 完全独立，**不受 launch.pyw 影响**
- 反之 launch.pyw quit 也不影响 wechat
- 多 frontend 共享 `memory/` 但**不共享当前对话历史**——详见 [`LAUNCHER_WEBUI_RESEARCH.md`](./LAUNCHER_WEBUI_RESEARCH.md) §3
- 想跨 frontend 接续对话 → 在新 frontend 输入 `/continue` 列表选择

## 浏览器直接访问

launch.pyw GUI 是 webview 包装，但 streamlit 本身就是个 HTTP 服务，浏览器直接访问也行：

```
http://localhost:18501  # 你 mykey.webui_port 配的端口
```

GUI 关闭后 streamlit 子进程也会退出（atexit hook），如果你想后台跑只用浏览器：

```bash
# 单独跑 streamlit（不要 launch.pyw 的 GUI）
streamlit run frontends/stapp.py --server.port 18501 --server.address localhost --server.headless true
```

或用 `start_wechat.sh web start`（如果你完成了 LAUNCHER_WEBUI_RESEARCH §4 的 wechat-web 整合）。

## 排错

### 托盘图标不出现（macOS）

可能原因：pystray 在 macOS 主线程跑，但 webview 抢占了。检查 launch 输出：
```
[Launch] WebUI port = ...
```
如果之后没有任何输出，且 dock 没有窗口图标 → 可能 webview subthread 启动失败。试试：
```bash
python launch.pyw --no-tray --show   # 跳过托盘，直接弹窗确认 webview 能起
```

### 全局快捷键不响应（macOS）

```
[hotkey] FAILED to register <cmd>+<shift>+<space>: ...
[hotkey] On macOS, grant Accessibility permission to Python:
  System Settings → Privacy & Security → Accessibility → enable Python
```

按提示授权，重启 launch.pyw。

### 自动隐藏没生效

**自查清单**：
- 窗口是不是从托盘/快捷键唤出的？（手动 `python launch.pyw --show` 启动后窗口位置可能不在 snapped 位置）
  - 解决：点托盘菜单 "📌 Snap to edge" 重新吸附
- 是不是开了 always-on-top？托盘菜单看 "Pause auto-hide" 是否打勾
- mykey.auto_hide_seconds 是不是设了 0？
- chat input 是不是有焦点？光标在输入框里时不会自动隐藏（这是有意保护）
- 是不是把窗口拖动过？拖出后会标 un-snapped → 永不自动隐藏，需点 "Snap to edge" 恢复

### 窗口位置不对（多屏 / 高 DPI）

v1 仅支持主显示器吸附。多屏支持在 v2 路线图。

如果坐标偏移：
```bash
# 检查屏幕尺寸读取是否正确
python3 -c "from AppKit import NSScreen; print(NSScreen.mainScreen().frame())"
```

如果数字异常 → 在 mykey.app_config 加 `edge_offset` 微调像素偏移。

### Quit 后子进程残留

```bash
# 查看是否有残留
pgrep -f streamlit
pgrep -f tgapp.py
```

如果有 → kill 它们。这是 bug 应该报告（菜单 Quit 应该 atexit kill 所有子进程）。

## 开发参考

- 实施细节：[`DESKTOP_UX_PLAN.md`](./DESKTOP_UX_PLAN.md)
- 架构上下文：[`PROJECT_DIRECTION.md`](./PROJECT_DIRECTION.md) §4.4
- WebUI 整体：[`LAUNCHER_WEBUI_RESEARCH.md`](./LAUNCHER_WEBUI_RESEARCH.md)
