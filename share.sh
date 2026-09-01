#!/usr/bin/env bash
#
# ai-session-share — 把本地终端会话共享成局域网 Web 服务
#
# 一条命令把当前终端的 AI 会话（tmux 会话）起成 ttyd Web 服务并输出局域网链接，
# 局域网内任何人在浏览器打开链接即可实时查看并继续同一个会话——
# 浏览器用户与本机共享同一个 tmux 终端，会话上下文天然一致。
#
# 用法：
#   share.sh                启动：创建/复用 tmux 会话 → 起 Web 服务 → 打印链接 → 进入会话
#   share.sh start [name]   同上（可指定会话名，默认 ai）
#   share.sh serve [name]   仅启动 Web 服务（共享一个已存在的 tmux 会话，适合已在会话里干活时另开终端调用）
#   share.sh here [name]    在会话内一键共享：自动识别"当前所在的" tmux 会话并起服务（无需另开终端、无需记会话名）
#   share.sh new [opts] <命令...>  新建托管会话（不依赖 tmux）：起服务+打印链接+进入会话；
#                                  进程退出（如 Claude 里 /exit）后网页会话自动结束。opts：--no-attach 不进入
#   share.sh attach <id>    本机终端连接到托管会话（关闭终端不会结束会话）
#   share.sh kill <id>      强制结束托管会话
#   share.sh sessions       全局查看所有活动中的会话与状态（托管/ttyd/Claude/atomcode）
#   share.sh stop [name]    停止 Web 服务（tmux 会话保留，可再 serve 恢复）
#   share.sh status [name]  查看服务状态
#   share.sh url [name]     打印当前访问链接与认证信息
#   share.sh hub [action]   会话监控面板（start/stop/status/url，默认 start）
#   share.sh doctor         环境自检
#   share.sh help           显示帮助
#
# 环境变量（可选）：
#   SS_SESSION   默认会话名（默认 ai）
#   SS_PORT      服务端口（默认 7681；被占用且未显式指定时自动顺延）
#   SS_HOST      监听地址（默认 0.0.0.0）
#   SS_HUB_PORT  会话监控面板端口（默认 7690）
#   SS_HUB_URL   面板地址环境变量（install.sh 写入 shell rc，全局发现用）
#   SS_HUB_TOKEN 面板认证 token 的环境变量兜底（hub.state 不可用时）
#   SS_NO_AUTH   设 1 关闭登录认证（不推荐，见 README 安全章节）
#
# 依赖：tmux、ttyd、openssl、python3（install.sh 可一键安装）
# 状态文件：~/.ai-session-share/<session>.{pid,state,log} 与 hub.{pid,state,log}，本机自用，不入库。

set -euo pipefail

# ---------- 默认配置（环境变量可覆盖） ----------
DEFAULT_SESSION="${SS_SESSION:-ai}"
PORT="${SS_PORT:-7681}"
HOST="${SS_HOST:-0.0.0.0}"
AUTH_USER="ai"
STATE_DIR="${SS_STATE_DIR:-${HOME}/.ai-session-share}"

# 会话监控面板（hub）：单端口常驻服务，监控 tmux / claude / atomcode 会话
HUB_PORT="${SS_HUB_PORT:-7690}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 基础工具 ----------
_normal="\033[0m"; _red="\033[31m"; _green="\033[32m"; _yellow="\033[33m"; _cyan="\033[36m"

log()    { printf "${_cyan}[share]${_normal} %s\n" "$*"; }
log_ok() { printf "${_green}[share]${_normal} %s\n" "$*"; }
log_warn(){ printf "${_yellow}[share]${_normal} %s\n" "$*"; }
log_err(){ printf "${_red}[share]${_normal} %s\n" "$*" >&2; }

die() { log_err "$*"; exit 1; }

# 校验会话名只含安全字符
valid_session() {
    [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]
}

need_cmds() {
    local missing=()
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "缺少依赖: ${missing[*]} —— 请先运行 ./install.sh 安装"
    fi
}

# ---------- 局域网 IP 检测（macOS / Linux） ----------
lan_ips() {
    local ips=""
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local iface ip
        for iface in en0 en1 en2 en3 en4 en5 en6 en7 en8 en9 bridge0 bridge1; do
            ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
            [[ -n "$ip" ]] && ips="$ips $ip"
        done
    else
        if command -v hostname >/dev/null 2>&1 && hostname -I >/dev/null 2>&1; then
            ips="$(hostname -I 2>/dev/null || true)"
        else
            local iface ip
            for iface in eth0 eth1 wlan0 ens3 ens4 ens5; do
                ip="$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 || true)"
                [[ -n "$ip" ]] && ips="$ips $ip"
            done
        fi
    fi
    # 只保留 IPv4，过滤回环与链路本地地址，去重排序
    echo "$ips" | tr ' ' '\n' \
        | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/' \
        | grep -v '^127\.' | grep -v '^169\.254\.' | sort -u
}

# ---------- 认证 token ----------
gen_token() {
    openssl rand -hex 16
}

# ---------- 端口占用检测 ----------
port_busy() {
    command -v lsof >/dev/null 2>&1 || return 1
    lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

# ---------- 状态文件读写（~/.ai-session-share/<session>.state，key=value 每行） ----------
state_path() { echo "${STATE_DIR}/${SESSION}.state"; }
pid_path()   { echo "${STATE_DIR}/${SESSION}.pid"; }
log_path()   { echo "${STATE_DIR}/${SESSION}.log"; }

hub_state_path() { echo "${STATE_DIR}/hub.state"; }
hub_pid_path()   { echo "${STATE_DIR}/hub.pid"; }
hub_log_path()   { echo "${STATE_DIR}/hub.log"; }

save_state() {
    mkdir -p "$STATE_DIR"
    cat > "$(state_path)" <<EOF
session=${SESSION}
pid=${TTYD_PID}
port=${PORT}
token=${TOKEN:-}
started=$(date '+%Y-%m-%d %H:%M:%S')
EOF
}

# 读取状态文件到全局变量：SESSION_PID / SESSION_PORT / SESSION_TOKEN
load_state() {
    local f="$(state_path)"
    SESSION_PID=""; SESSION_PORT=""; SESSION_TOKEN=""
    [[ -f "$f" ]] || return 0
    local k v
    while IFS='=' read -r k v; do
        [[ -z "$k" ]] && continue
        case "$k" in
            pid)   SESSION_PID="$v" ;;
            port)  SESSION_PORT="$v" ;;
            token) SESSION_TOKEN="$v" ;;
        esac
    done < "$f"
}

# ---------- tmux 会话管理 ----------
# 确保 tmux 会话存在（不存在则以 detached 方式创建，供浏览器端 ttyd attach-or-create）
ensure_session() {
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
        tmux new-session -d -s "$SESSION"
        log_ok "已创建 tmux 会话 '$SESSION'"
    else
        log "复用已有 tmux 会话 '$SESSION'"
    fi
}

# ---------- Web 服务启动/停止 ----------
# ttyd ≥1.7.4 默认只读（浏览器端无法输入），必须加 -W 显式开启可写；
# ttyd <1.7 没有 -W 参数（1.6 及更早默认即可写），按版本判断。
ttyd_needs_writable() {
    local ver
    ver="$(ttyd --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1)"
    [[ -z "$ver" ]] && return 0                     # 版本解析失败按新版本处理（加 -W 更安全）
    [[ "$(printf '%s\n%s\n' '1.7.0' "$ver" | sort -V | tail -n1)" == "$ver" ]]
}

ttyd_is_running() {
    [[ -n "${SESSION_PID:-}" ]] && kill -0 "$SESSION_PID" 2>/dev/null
}

# 端口被占时的处理：显式指定 SS_PORT → 严格报错；未指定 → 自动顺延到下一个空闲端口
# （同时共享多个会话时,从 7681 起依次使用 7682/7683…,面板/hook 依赖此行为）
resolve_port() {
    if ! port_busy "$PORT"; then
        return 0
    fi
    if [[ -n "${SS_PORT:-}" ]]; then
        die "端口 ${PORT} 已被其他进程占用，可用 SS_PORT=xxxx ./share.sh 换端口"
    fi
    local p="$PORT" tries=0
    while port_busy "$p" && [[ $tries -lt 50 ]]; do
        p=$((p + 1))
        tries=$((tries + 1))
    done
    if port_busy "$p"; then
        die "从 ${PORT} 起连续 50 个端口都被占用，请用 SS_PORT=xxxx 显式指定"
    fi
    log "默认端口 ${PORT} 被占用，自动改用 ${p}"
    PORT="$p"
}

start_ttyd() {
    load_state
    if ttyd_is_running; then
        # 幂等：同一会话已在共享时复用现有服务与密码（重复 /share_session 场景）
        log_ok "Web 服务已在运行（PID ${SESSION_PID}），复用现有链接"
        PORT="${SESSION_PORT:-$PORT}"
        TOKEN="${SESSION_TOKEN:-}"
        return 0
    fi
    resolve_port

    mkdir -p "$STATE_DIR"
    TTYD_PID=""
    TOKEN=""
    # 注意：ttyd 默认即监听 0.0.0.0；实测 1.7.7 中 -a/--address 与 -c/--credential
    # 同用时 Basic Auth 会失效（无凭据直接 200），故默认不传绑定参数，
    # 仅在显式指定其他监听地址时用 -i（interface，支持 IP 或网卡名）传递。
    local args=(-p "$PORT")
    if ttyd_needs_writable; then
        args+=(-W)   # 关键：ttyd ≥1.7.4 默认只读，不加 -W 浏览器端无法输入（双向共享失效）
    else
        log_warn "ttyd 版本过旧（<1.7），无 -W 参数；旧版默认可写，但建议升级到 1.7+"
    fi
    if [[ "$HOST" != "0.0.0.0" ]]; then
        args+=(-i "$HOST")
    fi
    if [[ "${SS_NO_AUTH:-0}" != "1" ]]; then
        TOKEN="$(gen_token)"
        args+=(-c "${AUTH_USER}:${TOKEN}")
    fi

    nohup ttyd "${args[@]}" tmux new -A -s "$SESSION" \
        >"$(log_path)" 2>&1 &
    TTYD_PID=$!

    # 等待 1 秒确认进程存活（端口冲突/参数错误会立刻退出）
    sleep 1
    if ! kill -0 "$TTYD_PID" 2>/dev/null; then
        log_err "ttyd 启动失败，日志见: $(log_path)"
        log_err "--- 最近日志 ---"
        tail -n 5 "$(log_path)" >&2 || true
        return 1
    fi
    echo "$TTYD_PID" > "$(pid_path)"
    save_state
    log_ok "Web 服务已启动（PID ${TTYD_PID}）"
}

stop_ttyd() {
    load_state
    if ttyd_is_running; then
        kill "$SESSION_PID" 2>/dev/null || true
        # 等待进程真正退出
        for _ in 1 2 3 4 5; do
            kill -0 "$SESSION_PID" 2>/dev/null || break
            sleep 0.3
        done
        log_ok "已停止 Web 服务（PID ${SESSION_PID}）"
    else
        log_warn "没有在运行的 Web 服务"
    fi
    rm -f "$(pid_path)"
    rm -f "$(state_path)"
}

# ---------- 输出访问信息 ----------
print_urls() {
    local port="$1" token="${2:-}" path="${3:-}"
    local ips=() ip
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && ips+=("$ip")
    done < <(lan_ips)

    if [[ ${#ips[@]} -eq 0 ]]; then
        log_warn "  未检测到局域网 IP，请手动确认本机 IP 后用 http://<IP>:${port}${path} 访问"
    else
        for ip in "${ips[@]}"; do
            log "  局域网访问: http://${ip}:${port}${path}"
        done
    fi

    if [[ -n "$token" ]]; then
        log "  浏览器登录: 用户名 ${AUTH_USER}，密码 ${token}"
        if [[ ${#ips[@]} -gt 0 ]]; then
            log "  一键登录（点击即用，无需手输密码）:"
            for ip in "${ips[@]}"; do
                log "    http://${AUTH_USER}:${token}@${ip}:${port}${path}"
            done
        fi
        log "  提示: 密码在每次 start/serve 时都会重新生成；若提示密码错误，"
        log "        请换无痕窗口或清除该地址的缓存凭据（服务重启后浏览器常缓存旧密码）"
    else
        log_warn "  认证已关闭（SS_NO_AUTH=1）——任何局域网内的人都可直接操作你的终端，仅限可信网络！"
    fi
}

# ---------- 子命令 ----------
cmd_start() {
    need_cmds ttyd tmux openssl
    ensure_session
    start_ttyd
    echo
    log "浏览器访问（手机也可）："
    print_urls "$PORT" "$TOKEN"
    echo
    log "本机进入会话（在里面运行你的 AI 工具，比如 atomcode / claude / 任意命令）："
    log "  tmux attach -t ${SESSION}"
    echo
    log_ok "会话已在后台保持，可随时用 'share.sh stop ${SESSION}' 关闭 Web 服务。"
    log_ok "现在进入会话:"
    # 附加到会话（不存在则创建），退出会话不终止 Web 服务
    if [[ -t 0 ]]; then
        exec tmux new -A -s "$SESSION"
    else
        log_warn "非交互终端，跳过自动进入；请另行执行: tmux attach -t ${SESSION}"
    fi
}

cmd_serve() {
    need_cmds ttyd tmux openssl
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
        log_warn "tmux 会话 '$SESSION' 不存在，先创建（可在会话里跑你的 AI 工具）..."
        ensure_session
    fi
    start_ttyd
    echo
    log "浏览器访问（手机也可）："
    print_urls "$PORT" "$TOKEN"
    echo
    log_ok "服务已后台运行。注意：本命令不进入会话；要操作会话请: tmux attach -t ${SESSION}"
}

cmd_here() {
    need_cmds ttyd tmux openssl
    # 未显式指定会话名时，自动识别"当前所在的" tmux 会话
    if [[ "${HERE_EXPLICIT:-0}" != "1" ]]; then
        local cur
        cur="$(tmux display-message -p '#S' 2>/dev/null || true)"
        if [[ -n "$cur" ]]; then
            SESSION="$cur"
            valid_session "$SESSION" || die "会话名 '$SESSION' 不合法（仅允许字母/数字/_-）"
            log_ok "检测到当前 tmux 会话 '$SESSION'，将共享该会话"
        else
            log_warn "当前不在 tmux 会话内，使用默认会话 '$SESSION'（可用: share.sh here <name> 指定）"
        fi
    fi
    ensure_session
    start_ttyd
    echo
    log "浏览器访问（手机也可）："
    print_urls "$PORT" "$TOKEN"
    echo
    log_ok "服务已后台运行。注意：本命令不进入会话；停止共享: share.sh stop ${SESSION}"
}

cmd_stop() {
    need_cmds tmux
    stop_ttyd
    log "tmux 会话 '$SESSION' 保留未动，需要时可用 'tmux attach -t ${SESSION}' 重新进入。"
}

cmd_status() {
    need_cmds tmux
    load_state
    echo "═══ ai-session-share 状态 ═══"
    if ttyd_is_running; then
        echo "  Web 服务: 运行中 (PID ${SESSION_PID})"
        echo "  端口:     ${SESSION_PORT:-${PORT}}"
        if [[ -n "${SESSION_TOKEN:-}" ]]; then
            echo "  认证:     用户名 ${AUTH_USER} / 密码 ${SESSION_TOKEN}"
        else
            echo "  认证:     已关闭"
        fi
    else
        echo "  Web 服务: 未运行"
    fi
    if tmux has-session -t "$SESSION" 2>/dev/null; then
        echo "  tmux 会话 '$SESSION': 存在 ($(tmux list-clients -t "$SESSION" 2>/dev/null | wc -l | tr -d ' ') 个连接)"
    else
        echo "  tmux 会话 '$SESSION': 不存在"
    fi
}

cmd_url() {
    load_state
    if ! ttyd_is_running; then
        die "Web 服务未在运行，先执行: share.sh start ${SESSION} 或 share.sh serve ${SESSION}"
    fi
    print_urls "${SESSION_PORT:-$PORT}" "${SESSION_TOKEN:-}"
}

# ---------- 会话监控面板（hub）----------
# 常驻 Web 服务（hub_server.py）：监控 tmux / Claude Code / atomcode 会话，
# Claude 不在 tmux 内时 /share_session 输出的就是面板里该会话的实时视图链接。
hub_load_state() {
    HUB_STATE_PORT=""; HUB_STATE_TOKEN=""
    local f k v
    f="$(hub_state_path)"
    [[ -f "$f" ]] || return 0
    while IFS='=' read -r k v; do
        case "$k" in
            port)  HUB_STATE_PORT="$v" ;;
            token) HUB_STATE_TOKEN="$v" ;;
        esac
    done < "$f"
}

hub_is_running() {
    [[ -f "$(hub_pid_path)" ]] && kill -0 "$(cat "$(hub_pid_path)" 2>/dev/null)" 2>/dev/null
}

cmd_hub_start() {
    need_cmds python3 openssl
    if hub_is_running; then
        hub_load_state
        log_ok "会话监控面板已在运行（PID $(cat "$(hub_pid_path)" 2>/dev/null)），复用现有链接"
        echo
        log "浏览器访问（可查看所有运行中的会话）："
        print_urls "${HUB_STATE_PORT:-$HUB_PORT}" "${HUB_STATE_TOKEN:-}"
        return 0
    fi
    if port_busy "$HUB_PORT"; then
        die "监控面板端口 ${HUB_PORT} 已被占用，可用 SS_HUB_PORT=xxxx ./share.sh hub start 换端口"
    fi
    mkdir -p "$STATE_DIR"
    local hub_token=""
    if [[ "${SS_NO_AUTH:-0}" != "1" ]]; then
        hub_token="$(gen_token)"
    fi
    # SS_HUB_DAEMON=1:hub_server.py 双 fork+setsid 自守护,状态文件(hub.pid/hub.state)
    # 由最终守护进程在绑定成功后自己写 —— 启动方只需轮询等待,不再代写(避免 pid 不符)。
    SS_HUB_DAEMON=1 SS_HUB_PORT="$HUB_PORT" SS_HUB_TOKEN="$hub_token" \
        nohup python3 "${REPO_DIR}/hub_server.py" >"$(hub_log_path)" 2>&1 &
    # 等待守护进程就绪(最长 5s:pid 文件出现且进程存活)
    local waited=0
    while ! hub_is_running && [[ $waited -lt 50 ]]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    if ! hub_is_running; then
        log_err "监控面板启动失败，日志见: $(hub_log_path)"
        log_err "--- 最近日志 ---"
        tail -n 5 "$(hub_log_path)" >&2 || true
        return 1
    fi
    hub_load_state
    log_ok "会话监控面板已启动（PID $(cat "$(hub_pid_path)" 2>/dev/null)）"
    echo
    log "浏览器访问（可查看所有运行中的会话）："
    print_urls "$HUB_PORT" "$hub_token"
    echo
    log_ok "全局环境变量（新终端自动生效，见 install.sh）: SS_HUB_URL=http://127.0.0.1:${HUB_PORT}"
    log_ok "活动会话一览: share sessions    本机 MCP 接入: python3 ${REPO_DIR}/mcp_server.py"
    log_ok "面板监控: tmux 会话 / 托管会话(免 tmux) / Claude Code 会话(实时网页视图) / atomcode 活动"
    log_ok "停止面板: share.sh hub stop"
}

cmd_hub_stop() {
    if hub_is_running; then
        # 托管会话存活于面板进程内:面板退出会一并结束它们,有存活会话时阻止误停
        local running=0
        if command -v python3 >/dev/null 2>&1; then
            running="$(python3 "${REPO_DIR}/hub_server.py" api state 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(sum(1 for x in d.get("managed", []) if not x.get("exited")))
except Exception:
    print(0)' 2>/dev/null)" || running=""
            [[ "$running" =~ ^[0-9]+$ ]] || running=0
        fi
        if [[ "$running" -gt 0 && "${SS_FORCE:-0}" != "1" ]]; then
            die "还有 ${running} 个运行中的托管会话,停止面板会一并结束它们;确认请用: SS_FORCE=1 share.sh hub stop"
        fi
        local pid
        pid="$(cat "$(hub_pid_path)" 2>/dev/null)"
        kill "$pid" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.3
        done
        log_ok "已停止会话监控面板（PID ${pid}）"
    else
        log_warn "会话监控面板未在运行"
    fi
    rm -f "$(hub_pid_path)"
    rm -f "$(hub_state_path)"
}

cmd_hub_status() {
    hub_load_state
    echo "═══ ai-session-share 会话监控面板 ═══"
    if hub_is_running; then
        echo "  面板服务: 运行中 (PID $(cat "$(hub_pid_path)" 2>/dev/null))"
        echo "  端口:     ${HUB_STATE_PORT:-$HUB_PORT}"
        if [[ -n "$HUB_STATE_TOKEN" ]]; then
            echo "  认证:     用户名 ${AUTH_USER} / 密码 ${HUB_STATE_TOKEN}"
        else
            echo "  认证:     已关闭"
        fi
    else
        echo "  面板服务: 未运行（share.sh hub start 启动）"
    fi
}

cmd_hub_url() {
    hub_load_state
    if ! hub_is_running; then
        die "会话监控面板未在运行，先执行: share.sh hub start"
    fi
    print_urls "${HUB_STATE_PORT:-$HUB_PORT}" "${HUB_STATE_TOKEN:-}"
}

# ---------- 托管会话(自管 PTY,不依赖 tmux/ttyd)----------
# 会话由 hub 进程托管:本机与所有浏览器共用同一个 PTY,双向操作;
# 生命周期与会话进程严格绑定 —— 进程退出(如 Claude 里 /exit)后网页会话自动结束。
cmd_new() {
    need_cmds python3
    local no_attach=0 args=()
    # 已知 cmd_new 收到的是命令及参数(首个 "new" 已在 main 中 shift 掉)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-attach) no_attach=1 ;;
            --) shift; args+=("$@"); break ;;
            *) args+=("$1") ;;
        esac
        shift
    done
    if [[ ${#args[@]} -eq 0 ]]; then
        args=("${SHELL:-/bin/bash}")
    fi

    if ! hub_is_running; then
        if ! cmd_hub_start >/dev/null 2>&1; then
            log_err "会话监控面板启动失败，日志见: $(hub_log_path)"
            return 1
        fi
    fi
    hub_load_state

    local hub_json sid
    hub_json="$(python3 "${REPO_DIR}/hub_server.py" api new "$PWD" "${args[@]}")" \
        || { log_err "创建托管会话失败"; return 1; }
    sid="$(echo "$hub_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
    if [[ -z "$sid" ]]; then
        log_err "创建托管会话失败: ${hub_json}"
        return 1
    fi

    echo
    log "托管会话已创建: ${sid}"
    log "  命令: ${args[*]}"
    echo
    log "浏览器访问（手机也可，双向操作同一会话）:"
    print_urls "${HUB_STATE_PORT:-$HUB_PORT}" "${HUB_STATE_TOKEN:-}" "/w/${sid}"
    echo
    log_ok "生命周期: 会话内 /exit 或进程退出后，网页会话自动结束（无需 stop）。"
    log_ok "本机再次进入: share attach ${sid}    强制结束: share kill ${sid}"
    if [[ $no_attach -eq 0 && -t 0 ]]; then
        echo
        log_ok "进入会话（直接关闭本终端不会结束会话，浏览器仍可继续）..."
        exec python3 "${REPO_DIR}/hub_attach.py" "$sid"
    else
        log "本地连接: share attach ${sid}"
    fi
}

cmd_attach() {
    need_cmds python3
    local sid="${1:-}"
    [[ -n "$sid" ]] || die "用法: share attach <托管会话id>  (id 来自 share new 输出或监控面板)"
    exec python3 "${REPO_DIR}/hub_attach.py" "$sid"
}

cmd_kill() {
    need_cmds python3
    local sid="${1:-}"
    [[ -n "$sid" ]] || die "用法: share kill <托管会话id>"
    if ! hub_is_running; then
        die "会话监控面板未在运行"
    fi
    python3 "${REPO_DIR}/hub_server.py" api kill "$sid" >/dev/null \
        || { log_err "结束失败（会话可能已结束）"; return 1; }
    log_ok "已请求结束托管会话 ${sid}（网页端将同步显示已结束）"
}

# 全局活动会话视图:托管/ttyd/Claude/atomcode 一屏尽览(格式化在 hub_server.py api sessions)
cmd_sessions() {
    need_cmds python3
    if ! hub_is_running; then
        log_warn "会话监控面板未在运行（仅显示提示），建议: share hub start"
        return 1
    fi
    python3 "${REPO_DIR}/hub_server.py" api sessions
}

cmd_doctor() {
    echo "═══ 环境自检 ═══"
    local c ver
    for c in tmux ttyd openssl python3; do
        if command -v "$c" >/dev/null 2>&1; then
            # 版本参数各不相同：ttyd 用 --version，openssl 用 version，其余用 -V
            if [[ "$c" == "ttyd" ]]; then
                ver="$("$c" --version 2>/dev/null | head -n 1 || echo '')"
            elif [[ "$c" == "openssl" ]]; then
                ver="$("$c" version 2>/dev/null | head -n 1 || echo '')"
            else
                ver="$("$c" -V 2>/dev/null | head -n 1 || echo '')"
            fi
            printf "  %-9s 已安装  %s\n" "$c" "${ver}"
        else
            printf "  %-9s 缺失!   请运行 ./install.sh 安装\n" "$c"
        fi
    done
    echo
    if port_busy "$PORT"; then
        echo "  端口 ${PORT}: 被占用（可 SS_PORT=xxxx ./share.sh 换端口）"
    else
        echo "  端口 ${PORT}: 空闲"
    fi
    if port_busy "$HUB_PORT"; then
        echo "  面板端口 ${HUB_PORT}: 被占用（可 SS_HUB_PORT=xxxx 换端口）"
    else
        echo "  面板端口 ${HUB_PORT}: 空闲"
    fi
    echo "  会话名: ${SESSION}（SS_SESSION 可改）"
    echo "  局域网 IP:"
    local ip
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && echo "    ${ip}"
    done < <(lan_ips)
}

cmd_help() {
    sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------- 入口 ----------
# 参数约定：首参若是已知子命令名，则次参（可选）为会话名；否则首参即会话名，走 start。
main() {
    local cmd="${1:-start}"
    SESSION="$DEFAULT_SESSION"

    case "$cmd" in
        start|serve|stop|status|url|doctor|help|-h|--help|sessions)
            if [[ -n "${2:-}" ]]; then
                SESSION="$2"
            fi
            ;;
        here)
            if [[ -n "${2:-}" ]]; then
                SESSION="$2"
                HERE_EXPLICIT=1
            fi
            ;;
        hub|new|attach|kill)
            ;;  # 次参不是会话名:hub→动作、new→命令、attach/kill→托管会话 id
        *)
            cmd="start"
            SESSION="$1"
            ;;
    esac

    valid_session "$SESSION" || die "会话名 '$SESSION' 不合法（仅允许字母/数字/_-）"

    if [[ "$cmd" == "hub" ]]; then
        local action="${2:-start}"
        case "$action" in
            start)  cmd_hub_start ;;
            stop)   cmd_hub_stop ;;
            status) cmd_hub_status ;;
            url)    cmd_hub_url ;;
            *) die "未知 hub 子命令: $action（可用 start/stop/status/url）" ;;
        esac
        exit 0
    fi

    case "$cmd" in
        start)  cmd_start ;;
        serve)  cmd_serve ;;
        here)   cmd_here ;;
        stop)   cmd_stop ;;
        status) cmd_status ;;
        url)    cmd_url ;;
        new)    shift; cmd_new "$@" ;;
        attach) cmd_attach "${2:-}" ;;
        kill)   cmd_kill "${2:-}" ;;
        sessions) cmd_sessions ;;
        doctor) cmd_doctor ;;
        help|-h|--help) cmd_help ;;
        *) die "未知命令: $cmd" ;;
    esac
}

main "$@"
