#!/usr/bin/env bash
#
# ai-session-share — 把本地终端会话共享成局域网 Web 服务
#
# 一条命令把命令（如 claude）跑进面板自管的 PTY 托管会话并输出局域网链接，
# 局域网内任何人在浏览器打开链接即可实时查看并继续同一个会话——
# 本机与所有浏览器共用同一个终端，会话上下文天然一致；
# 生命周期与会话进程严格绑定：进程退出（如 Claude 里 /exit）后网页会话自动结束。
#
# 用法：
#   share.sh new [opts] <命令...>  新建托管会话：起服务+打印链接+进入会话；
#                                  进程退出（如 Claude 里 /exit）后网页会话自动结束。
#                                  opts：--no-attach 不进入；--cwd <目录> 指定工作目录(默认当前目录)
#   share.sh attach <id>    本机终端连接到托管会话（关闭终端不会结束会话）
#   share.sh kill <id>      强制结束托管会话
#   share.sh sessions       全局查看所有活动中的会话与状态（托管/Claude/atomcode）
#   share.sh status         查看面板状态与认证信息
#   share.sh url            打印面板访问链接与认证信息
#   share.sh hub [action]   会话监控面板（start/stop/status/url，默认 start）
#   share.sh doctor         环境自检
#   share.sh help           显示帮助
#
# 环境变量（可选）：
#   SS_HUB_PORT  会话监控面板端口（默认 7690）
#   SS_HUB_URL   面板地址环境变量（install.sh 写入 shell rc，全局发现用）
#   SS_HUB_TOKEN 面板认证 token 的环境变量兜底（hub.state 不可用时）
#   SS_NO_AUTH   设 1 关闭登录认证（不推荐，见 README 安全章节）
#
# 依赖：openssl、python3（install.sh 可一键安装）；纯 Python 自管 PTY，不需要 tmux/ttyd
# 状态文件：~/.ai-session-share/hub.{pid,state,log}，本机自用，不入库。

set -euo pipefail

# ---------- 默认配置（环境变量可覆盖） ----------
AUTH_USER="ai"
STATE_DIR="${SS_STATE_DIR:-${HOME}/.ai-session-share}"

# 会话监控面板（hub）：单端口常驻服务，承载托管会话并监控 Claude / atomcode 会话
HUB_PORT="${SS_HUB_PORT:-7690}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 基础工具 ----------
_normal="\033[0m"; _red="\033[31m"; _green="\033[32m"; _yellow="\033[33m"; _cyan="\033[36m"

log()    { printf "${_cyan}[share]${_normal} %s\n" "$*"; }
log_ok() { printf "${_green}[share]${_normal} %s\n" "$*"; }
log_warn(){ printf "${_yellow}[share]${_normal} %s\n" "$*"; }
log_err(){ printf "${_red}[share]${_normal} %s\n" "$*" >&2; }

die() { log_err "$*"; exit 1; }

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

# ---------- 状态文件（hub） ----------
hub_state_path() { echo "${STATE_DIR}/hub.state"; }
hub_pid_path()   { echo "${STATE_DIR}/hub.pid"; }
hub_log_path()   { echo "${STATE_DIR}/hub.log"; }

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
            log "  免密登录链接（打开即自动登录，无需手输账号密码，30 天内有效）:"
            for ip in "${ips[@]}"; do
                log "    http://${ip}:${port}${path}?key=${token}"
            done
        fi
        log "  说明: 上面的免密链接用查询参数传递凭据(不是被浏览器禁用的\"URL 内嵌账号密码\"),"
        log "        打开一次后会写入 cookie；也可以直接输入用户名密码手动登录。"
        log "        分享免密链接等于分享密码，请仅在可信网络内使用。"
    else
        log_warn "  认证已关闭（SS_NO_AUTH=1）——任何局域网内的人都可直接操作你的终端，仅限可信网络！"
    fi
}

# ---------- 会话监控面板（hub）----------
# 常驻 Web 服务（hub_server.py）：承载托管会话（自管 PTY），
# 监控 Claude Code / atomcode 会话；所有共享能力都由它提供。
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
    chmod 700 "$STATE_DIR" 2>/dev/null || true
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
    log_ok "面板监控: 托管会话 / Claude Code 会话(实时网页视图) / atomcode 活动"
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

cmd_status() {
    hub_load_state
    echo "═══ ai-session-share 状态 ═══"
    if hub_is_running; then
        echo "  面板服务: 运行中 (PID $(cat "$(hub_pid_path)" 2>/dev/null))"
        echo "  端口:     ${HUB_STATE_PORT:-$HUB_PORT}"
        if [[ -n "$HUB_STATE_TOKEN" ]]; then
            echo "  认证:     用户名 ${AUTH_USER} / 密码 ${HUB_STATE_TOKEN}"
        else
            echo "  认证:     已关闭"
        fi
        echo "  活动会话一览: share sessions"
    else
        echo "  面板服务: 未运行（share.sh hub start 启动）"
    fi
}

cmd_url() {
    hub_load_state
    if ! hub_is_running; then
        die "会话监控面板未在运行，先执行: share.sh hub start"
    fi
    print_urls "${HUB_STATE_PORT:-$HUB_PORT}" "${HUB_STATE_TOKEN:-}"
}

# ---------- 托管会话(自管 PTY)----------
# 会话由 hub 进程托管:本机与所有浏览器共用同一个 PTY,双向操作;
# 生命周期与会话进程严格绑定 —— 进程退出(如 Claude 里 /exit)后网页会话自动结束。
cmd_new() {
    need_cmds python3 openssl
    local no_attach=0 cwd="" args=()
    # 已知 cmd_new 收到的是命令及参数(首个 "new" 已在 main 中 shift 掉)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-attach) no_attach=1 ;;
            --cwd) shift; cwd="${1:-}" ;;
            --) shift; args+=("$@"); break ;;
            *) args+=("$1") ;;
        esac
        shift
    done
    if [[ ${#args[@]} -eq 0 ]]; then
        args=("${SHELL:-/bin/bash}")
    fi
    if [[ -n "$cwd" && ! -d "$cwd" ]]; then
        log_warn "指定目录不存在: ${cwd}，改用当前目录 ${PWD}"
        cwd=""
    fi
    cwd="${cwd:-$PWD}"

    if ! hub_is_running; then
        if ! cmd_hub_start >/dev/null 2>&1; then
            log_err "会话监控面板启动失败，日志见: $(hub_log_path)"
            return 1
        fi
    fi
    hub_load_state

    local hub_json sid
    hub_json="$(python3 "${REPO_DIR}/hub_server.py" api new "$cwd" "${args[@]}")" \
        || { log_err "创建托管会话失败"; return 1; }
    sid="$(echo "$hub_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
    if [[ -z "$sid" ]]; then
        log_err "创建托管会话失败: ${hub_json}"
        return 1
    fi

    echo
    log "托管会话已创建: ${sid}"
    log "  命令: ${args[*]}   目录: ${cwd}"
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

# 全局活动会话视图:托管/Claude/atomcode 一屏尽览(格式化在 hub_server.py api sessions)
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
    for c in openssl python3; do
        if command -v "$c" >/dev/null 2>&1; then
            if [[ "$c" == "openssl" ]]; then
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
    if port_busy "$HUB_PORT"; then
        echo "  面板端口 ${HUB_PORT}: 被占用（可 SS_HUB_PORT=xxxx 换端口）"
    else
        echo "  面板端口 ${HUB_PORT}: 空闲"
    fi
    echo "  局域网 IP:"
    local ip
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && echo "    ${ip}"
    done < <(lan_ips)
}

cmd_help() {
    sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------- 入口 ----------
main() {
    local cmd="${1:-new}"
    if [[ $# -gt 0 ]]; then shift; fi

    case "$cmd" in
        new)    cmd_new "$@" ;;
        attach) cmd_attach "${1:-}" ;;
        kill)   cmd_kill "${1:-}" ;;
        sessions) cmd_sessions ;;
        status) cmd_status ;;
        url)    cmd_url ;;
        doctor) cmd_doctor ;;
        help|-h|--help) cmd_help ;;
        hub)
            local action="${1:-start}"
            case "$action" in
                start)  cmd_hub_start ;;
                stop)   cmd_hub_stop ;;
                status) cmd_status ;;
                url)    cmd_url ;;
                *) die "未知 hub 子命令: $action（可用 start/stop/status/url）" ;;
            esac
            ;;
        start|serve|here|stop)
            die "命令 '${cmd}' 已移除（旧版 tmux/ttyd 模式）。请使用: share new <命令>  或  share attach <id>"
            ;;
        *)
            die "未知命令: ${cmd}（可用 new/attach/kill/sessions/status/url/hub/doctor/help，详见 share help）"
            ;;
    esac
}

main "$@"
