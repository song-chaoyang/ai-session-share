#!/usr/bin/env bash
#
# ai-session-share — 依赖安装脚本
# 检测 tmux / ttyd / openssl / python3，缺失时提示或自动安装（-y）。
#
# 用法：
#   ./install.sh        检测并打印安装指引（不自动安装）
#   ./install.sh -y     检测并自动安装缺失依赖
#
# 支持平台：macOS（Homebrew）、Debian/Ubuntu（apt）、CentOS/RHEL/Fedora（yum/dnf）

set -euo pipefail

_normal="\033[0m"; _red="\033[31m"; _green="\033[32m"; _yellow="\033[33m"
log_ok()  { printf "${_green}[install]${_normal} %s\n" "$*"; }
log_warn(){ printf "${_yellow}[install]${_normal} %s\n" "$*"; }
log_err() { printf "${_red}[install]${_normal} %s\n" "$*" >&2; }

AUTO=0
[[ "${1:-}" == "-y" ]] && AUTO=1

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)  echo "linux" ;;
        *)      echo "unknown" ;;
    esac
}

# 输出某依赖的安装命令（按平台）
install_cmd_for() {
    local os="$1" pkg="$2"
    case "$os" in
        macos) echo "brew install ${pkg}" ;;
        linux)
            if command -v apt-get >/dev/null 2>&1; then
                echo "sudo apt-get install -y ${pkg}"
            elif command -v dnf >/dev/null 2>&1; then
                echo "sudo dnf install -y ${pkg}"
            elif command -v yum >/dev/null 2>&1; then
                echo "sudo yum install -y ${pkg}"
            else
                echo ""
            fi
            ;;
        *) echo "" ;;
    esac
}

# 安装 share 命令：在 ~/.local/bin 建软链指向 share.sh，任意目录/会话内直接调用
install_share_cmd() {
    local bin_dir="${HOME}/.local/bin"
    local target="${bin_dir}/share"
    mkdir -p "$bin_dir"
    if [[ -e "$target" ]] && [[ "$(readlink "$target" 2>/dev/null || true)" != "$REPO_DIR/share.sh" ]]; then
        log_warn "  ${target} 已存在且不是本仓库链接，跳过（可手动: ln -sf ${REPO_DIR}/share.sh ${target}）"
        return 0
    fi
    ln -sf "$REPO_DIR/share.sh" "$target"
    log_ok "  已安装 share 命令: ${target}"
    if ! echo ":$PATH:" | grep -q ":${bin_dir}:"; then
        log_warn "  ${bin_dir} 不在 PATH，添加到 shell 配置后即可在任意目录/会话内使用:"
        echo "    echo 'export PATH=\"${bin_dir}:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
    fi
}

# 安装 /share_session 斜杠命令：动态检测本机已安装的 AI 工具（atomcode / claude / codex），
# 把共享命令模板软链到各工具的全局命令目录。之后在任意 AI 工具里直接输入斜杠命令即可一键共享会话。
# 各工具约定：atomcode/claude 用 ~/.xxx/commands/<名>.md（输入 /share_session）；
#             codex 用 ~/.codex/prompts/<名>.md（输入 /prompts:share_session）。
install_agent_commands() {
    local tmpl="${REPO_DIR}/commands/share_session.md"
    if [[ ! -f "$tmpl" ]]; then
        log_warn "  缺少模板文件 ${tmpl}，跳过 AI 工具斜杠命令安装"
        return 0
    fi
    local found=0
    local bin dir usage target
    # 条目：工具命令|命令目录|调用方式
    while IFS='|' read -r bin dir usage; do
        [[ -z "$bin" ]] && continue
        if command -v "$bin" >/dev/null 2>&1; then
            mkdir -p "$dir"
            target="${dir}/share_session.md"
            if [[ -e "$target" ]] && [[ "$(readlink "$target" 2>/dev/null || true)" != "$tmpl" ]]; then
                log_warn "  ${target} 已存在且不是本仓库链接，跳过（可手动: ln -sf ${tmpl} ${target}）"
                continue
            fi
            ln -sf "$tmpl" "$target"
            log_ok "  已为 ${bin} 安装命令 ${usage} → ${target}"
            found=1
        fi
    done <<EOF
atomcode|${HOME}/.atomcode/commands|/share_session
claude|${HOME}/.claude/commands|/share_session
codex|${HOME}/.codex/prompts|/prompts:share_session
EOF
    if [[ $found -eq 0 ]]; then
        log_warn "  未检测到已安装的 AI 工具（atomcode/claude/codex），跳过斜杠命令安装"
    fi
}

# 安装 /share_session 的 UserPromptSubmit hook：让 AI 工具在【模型介入前】直接执行
# share 命令并返回链接，LLM 完全不参与 —— 不消耗推理 token。
install_agent_hooks() {
    if ! command -v python3 >/dev/null 2>&1; then
        log_warn "  python3 缺失，跳过 AI 工具 hook 安装（只安装斜杠命令模板）"
        return 0
    fi
    if [[ ! -f "${REPO_DIR}/hooks/install_hooks.py" ]]; then
        log_warn "  缺少 ${REPO_DIR}/hooks/install_hooks.py，跳过 hook 安装"
        return 0
    fi
    log_ok "安装 UserPromptSubmit hook（/share_session 零 token 直接执行）..."
    python3 "${REPO_DIR}/hooks/install_hooks.py" || {
        log_warn "  hook 安装脚本执行失败（不影响 share 命令使用）"
        return 0
    }
}

# 全局环境变量:SS_HUB_URL —— 任何终端 / AI 客户端都能据此发现监控面板
# (share attach 兜底、MCP 服务器兜底、hook 面板兜底都读它)。
# 幂等:已存在本仓库写入的同名行则跳过;SS_RC_FILE 可覆盖目标文件(测试用)。
install_env_var() {
    local rc_file="${SS_RC_FILE:-}"
    if [[ -z "$rc_file" ]]; then
        case "$(basename "${SHELL:-/bin/bash}")" in
            zsh)  rc_file="${HOME}/.zshrc" ;;
            bash) rc_file="${HOME}/.bashrc" ;;
            *)    rc_file="${HOME}/.profile" ;;
        esac
    fi
    local marker="# ai-session-share (auto-added)"
    if [[ -f "$rc_file" ]] && grep -q "export SS_HUB_URL=" "$rc_file" 2>/dev/null; then
        # 已有同名导出:仅更新为本仓库建议值不合适(可能被用户改过),保持不动
        log_ok "  SS_HUB_URL 已在 ${rc_file} 中配置,跳过"
        return 0
    fi
    {
        echo ""
        echo "${marker}"
        echo "export SS_HUB_URL=\"http://127.0.0.1:${SS_HUB_PORT:-7690}\""
    } >> "$rc_file"
    log_ok "  已写入 ${rc_file}: export SS_HUB_URL(新终端生效;当前终端可手动 source)"
}

# MCP 服务器注册:让任何支持 MCP 的 AI 客户端直接查看/操作会话
install_mcp() {
    if ! command -v python3 >/dev/null 2>&1; then
        log_warn "  python3 缺失，跳过 MCP 服务器注册"
        return 0
    fi
    if [[ ! -f "${REPO_DIR}/mcp_register.py" ]]; then
        log_warn "  缺少 ${REPO_DIR}/mcp_register.py，跳过 MCP 注册"
        return 0
    fi
    log_ok "注册 MCP 服务器（AI 客户端可 list/spawn/send/read/kill 会话）..."
    python3 "${REPO_DIR}/mcp_register.py" || {
        log_warn "  MCP 注册部分失败（不影响其他功能）"
        return 0
    }
}

main() {
    local os
    os="$(detect_os)"
    log_ok "检测到平台: ${os}"

    # 缺失依赖检测（命令名即包名：tmux / ttyd / openssl / python3 在各包管理器一致）
    local missing=()
    local cmd cmdline

    for cmd in tmux ttyd openssl python3; do
        if command -v "$cmd" >/dev/null 2>&1; then
            log_ok "  ${cmd}: 已安装"
        else
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_ok "所有依赖已就绪 ✓"
        echo
        if [[ $AUTO -eq 1 ]]; then
            log_ok "安装 share 命令（会话内一键共享）..."
            install_share_cmd
            install_agent_commands
            install_agent_hooks
            install_env_var
            install_mcp
        else
            log_ok "下一步：把入口加入 PATH 或设置别名（或运行 ./install.sh -y 自动安装 share 命令）："
            echo "  echo \"alias share='${REPO_DIR}/share.sh'\" >> ~/.zshrc && source ~/.zshrc"
            echo "  # 然后:  share            # 一条命令共享当前会话"
            echo "  # 或:   share here       # 在会话内一键共享当前 tmux 会话"
            echo "  # 或:   share doctor     # 环境自检"
        fi
        exit 0
    fi

    echo
    log_warn "缺失依赖: ${missing[*]}"
    echo

    local failed=0
    for cmd in "${missing[@]}"; do
        pkg="$cmd"   # 命令名即包名
        if [[ "$os" == "unknown" ]]; then
            log_err "不支持的平台，请手动安装 ${pkg}"
            failed=1
            continue
        fi
        cmdline="$(install_cmd_for "$os" "$pkg")"
        if [[ -z "$cmdline" ]]; then
            log_err "未找到包管理器，请手动安装 ${pkg}"
            failed=1
            continue
        fi
        if [[ $AUTO -eq 1 ]]; then
            log_ok "安装 ${pkg}: ${cmdline}"
            if eval "$cmdline"; then
                log_ok "  ${pkg} 安装完成"
            else
                log_err "  ${pkg} 安装失败（exit=$?），请手动执行: ${cmdline}"
                failed=1
            fi
        else
            log_warn "  ${pkg} 缺失，安装命令:"
            echo "    ${cmdline}"
        fi
    done

    echo
    if [[ $failed -eq 0 && $AUTO -eq 1 ]]; then
        log_ok "全部安装完成 ✓"
        log_ok "安装 share 命令..."
        install_share_cmd
        install_agent_commands
        install_agent_hooks
        echo
        log_ok "重新运行 ./share.sh doctor 验证"
    elif [[ $failed -eq 0 ]]; then
        log_ok "按上面命令安装后，重新运行 ./install.sh 确认"
    else
        log_err "存在失败的安装项，请手动处理后重试"
        exit 1
    fi
}

main
