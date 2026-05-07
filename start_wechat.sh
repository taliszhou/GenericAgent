#!/usr/bin/env bash
# GenericAgent 个人微信 Bot 管理脚本
# 用法:
#   ./start_wechat.sh              # 启动 (后台)
#   ./start_wechat.sh start        # 启动 (后台)
#   ./start_wechat.sh stop         # 停止
#   ./start_wechat.sh restart      # 重启
#   ./start_wechat.sh status       # 查看状态
#   ./start_wechat.sh log          # 实时追日志 (Ctrl+C 退出)
#   ./start_wechat.sh fg           # 前台启动 (看扫码二维码 ID / 状态用)
#   ./start_wechat.sh relogin      # 清除登录态 + 重新扫码登录
#   ./start_wechat.sh deps         # 检查/安装依赖

set -e

# ── 路径 ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PY="${PYTHON:-python3}"          # 允许外部覆盖：PYTHON=/path/to/python ./start_wechat.sh
APP="frontends/wechatapp.py"
PID_FILE="$SCRIPT_DIR/temp/wechatapp.pid"
LOG_FILE="$SCRIPT_DIR/temp/wechatapp.log"
BOOT_LOG="$SCRIPT_DIR/temp/wechatapp.boot.log"
LOCK_PORT=19531

mkdir -p "$SCRIPT_DIR/temp"

# ── 颜色输出 ────────────────────────────────────────
c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yell()  { printf '\033[33m%s\033[0m\n' "$*"; }
c_blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

# ── 依赖检查 ────────────────────────────────────────
check_python() {
    if ! command -v "$PY" >/dev/null 2>&1; then
        c_red "[ERR] 找不到 $PY，请先装 Python 3.10+ 或指定 PYTHON 环境变量"
        exit 1
    fi
    local ver
    ver=$("$PY" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    c_blue "[INFO] Python: $($PY -c 'import sys; print(sys.executable)') (v$ver)"
}

ensure_pip() {
    # 有 pip 就直接返回
    if "$PY" -m pip --version >/dev/null 2>&1; then return 0; fi
    c_yell "[WARN] 当前 Python 没有 pip，尝试用 ensurepip 引导 ..."
    if "$PY" -m ensurepip --upgrade >/dev/null 2>&1; then
        c_green "[OK] pip 已引导安装"
        return 0
    fi
    c_red "[ERR] ensurepip 失败"
    c_red "       手动修复: $PY -m ensurepip --upgrade"
    c_red "       或换个 Python: PYTHON=/opt/anaconda3/bin/python3 ./start_wechat.sh"
    exit 1
}

check_deps() {
    check_python
    if ! "$PY" -c "import qrcode, Crypto.Cipher.AES, PIL.Image, requests" 2>/dev/null; then
        c_yell "[WARN] 缺依赖，自动安装中 ..."
        ensure_pip
        "$PY" -m pip install --quiet qrcode pycryptodome pillow requests \
            || { c_red "[ERR] 依赖安装失败"; exit 1; }
        c_green "[OK] 依赖安装完成"
    else
        c_green "[OK] 依赖就位"
    fi
    # mykey.py 存在性检查
    if [ ! -f "$SCRIPT_DIR/mykey.py" ] && [ ! -f "$SCRIPT_DIR/mykey.json" ]; then
        c_red "[ERR] 未找到 mykey.py — 请先 cp mykey_template.py mykey.py 并填入 LLM apikey"
        exit 1
    fi
}

# ── 进程管理 ────────────────────────────────────────
get_pid() {
    # 优先 PID 文件，再尝试按命令行匹配
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"; return 0
        fi
    fi
    pgrep -f "[p]ython.*wechatapp.py" | head -1
}

is_running() {
    local pid; pid=$(get_pid)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

check_port() {
    # 端口冲突检测：wechatapp 和 wecomapp 都占 19531
    local holder
    holder=$(lsof -ti :$LOCK_PORT 2>/dev/null || true)
    if [ -n "$holder" ] && ! is_running; then
        c_red "[ERR] 端口 $LOCK_PORT 被占用 (PID=$holder)，可能是企业微信 bot 在跑"
        c_red "       用 'lsof -i :$LOCK_PORT' 看详情；或先 kill $holder"
        exit 1
    fi
}

# ── 命令 ────────────────────────────────────────────
cmd_start() {
    check_deps
    if is_running; then
        c_yell "[SKIP] Bot 已在运行 (PID=$(get_pid))"
        cmd_status
        return 0
    fi
    check_port
    c_blue "[INFO] 启动微信 Bot ..."
    # nohup 后台，boot log 捕获首次扫码时 stdout 的二维码 ID（会被还原到终端/pipe）
    nohup "$PY" "$APP" >"$BOOT_LOG" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    c_green "[OK] 已后台启动, PID=$pid"
    c_blue "[INFO] boot log: $BOOT_LOG"
    c_blue "[INFO] 运行日志: $LOG_FILE"

    # 等 4 秒看是否正常起来
    sleep 4
    if ! is_running; then
        c_red "[ERR] 进程已退出，最后的输出:"
        tail -20 "$BOOT_LOG" "$LOG_FILE" 2>/dev/null
        rm -f "$PID_FILE"
        exit 1
    fi

    # 首次登录：二维码可能已生成
    if [ -f "$HOME/.wxbot/wx_qr.png" ] && [ ! -s "$HOME/.wxbot/token.json" ] 2>/dev/null; then
        c_yell "[QR] 首次登录，二维码已生成，正在打开 ..."
        open "$HOME/.wxbot/wx_qr.png" 2>/dev/null || xdg-open "$HOME/.wxbot/wx_qr.png" 2>/dev/null || true
        c_yell "[QR] 请用微信扫码并在手机上确认登录"
    fi
    cmd_status
}

cmd_stop() {
    if ! is_running; then
        c_yell "[SKIP] Bot 未在运行"
        rm -f "$PID_FILE"
        return 0
    fi
    local pid; pid=$(get_pid)
    c_blue "[INFO] 正在停止 PID=$pid ..."
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        if ! kill -0 "$pid" 2>/dev/null; then break; fi
        sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
        c_yell "[WARN] 5 秒未退出，SIGKILL"
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    c_green "[OK] 已停止"
}

cmd_restart() {
    cmd_stop
    sleep 1
    cmd_start
}

cmd_status() {
    if is_running; then
        local pid; pid=$(get_pid)
        local etime
        etime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ' || echo "?")
        c_green "[RUNNING] PID=$pid  运行时长=$etime"
        # 从日志提取 bot_id
        local bot_id
        bot_id=$(grep -o 'bot_id=[^ )]*' "$LOG_FILE" 2>/dev/null | tail -1 || true)
        [ -n "$bot_id" ] && c_blue "          $bot_id"
        c_blue "[LOG]  $LOG_FILE"
    else
        c_yell "[STOPPED] Bot 未在运行"
    fi
    # Token 状态
    if [ -f "$HOME/.wxbot/token.json" ]; then
        local saved
        saved=$("$PY" -c "import json;d=json.load(open('$HOME/.wxbot/token.json'));print('yes' if d.get('bot_token') else 'no')" 2>/dev/null || echo "?")
        if [ "$saved" = "yes" ]; then
            c_green "[LOGIN] 已登录 ($HOME/.wxbot/token.json)"
        else
            c_yell "[LOGIN] token.json 存在但无 bot_token — 未完成登录"
        fi
    else
        c_yell "[LOGIN] 未登录 (运行后会弹出二维码)"
    fi
}

cmd_log() {
    [ -f "$LOG_FILE" ] || { c_red "[ERR] 日志不存在，先 start"; exit 1; }
    c_blue "[INFO] 追尾 $LOG_FILE (Ctrl+C 退出)"
    tail -n 50 -f "$LOG_FILE"
}

cmd_fg() {
    check_deps
    if is_running; then
        c_yell "[STOP] 先停止后台进程"
        cmd_stop
    fi
    check_port
    c_blue "[INFO] 前台启动 — 扫码状态会直接显示在这里，Ctrl+C 退出"
    exec "$PY" "$APP"
}

cmd_relogin() {
    cmd_stop
    if [ -d "$HOME/.wxbot" ]; then
        c_yell "[CLEAN] 清除 $HOME/.wxbot/"
        rm -rf "$HOME/.wxbot/token.json" "$HOME/.wxbot/wx_qr.png"
    fi
    cmd_start
}

usage() {
    cat <<EOF
用法: $(basename "$0") <command>

Commands:
  start      后台启动 (默认)
  stop       停止
  restart    重启
  status     查看状态 + token 是否就位
  log        实时追日志
  fg         前台启动 (第一次扫码时推荐用这个能看到二维码 ID)
  relogin    清除登录态 + 重新扫码
  deps       只检查/安装依赖, 不启动

环境变量:
  PYTHON     指定 python 可执行文件路径 (默认 python3)
             示例: PYTHON=/opt/anaconda3/bin/python3 ./start_wechat.sh

端口: $LOCK_PORT (与企业微信 bot 冲突, 不可同时运行)
EOF
}

# ── 入口 ────────────────────────────────────────────
case "${1:-start}" in
    start)    cmd_start   ;;
    stop)     cmd_stop    ;;
    restart)  cmd_restart ;;
    status)   cmd_status  ;;
    log)      cmd_log     ;;
    fg)       cmd_fg      ;;
    relogin)  cmd_relogin ;;
    deps)     check_deps  ;;
    -h|--help|help) usage ;;
    *) c_red "未知命令: $1"; usage; exit 1 ;;
esac
