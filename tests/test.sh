#!/usr/bin/env bash
#
# ai-session-share 冒烟测试
# 覆盖：语法检查 / 子命令行为 / 认证 / 真实起停 Web 服务 / 会话监控面板 /
#       Claude 会话视图 / hook 会话感知 / serve 幂等与自动选端口
#
# 用法：
#   ./tests/test.sh                 # 全部测试
#   TEST_PORT=19000 ./tests/test.sh # 指定测试端口（另可用 TEST_HUB_PORT，默认 17690）

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARE="$REPO/share.sh"
SESSION="testshare"
PORT="${TEST_PORT:-17681}"
HUB_PORT="${TEST_HUB_PORT:-17690}"
# 测试用独立状态目录（不污染真实 ~/.ai-session-share），share.sh / hook / hub 均读该变量
export SS_STATE_DIR="${SS_STATE_DIR:-${TMPDIR:-/tmp}/ai-session-share-test-state}"
STATE_DIR="$SS_STATE_DIR"
mkdir -p "$STATE_DIR"
FAKE_CLAUDE="${TMPDIR:-/tmp}/ai-session-share-fake-claude"
FAKE_SID="11111111-2222-3333-4444-555555555555"

PASS=0
FAIL=0

say()  { printf "\033[36m[test]\033[0m %s\n" "$*"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; PASS=$((PASS + 1)); }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$*"; FAIL=$((FAIL + 1)); }

cleanup() {
    # 无论成功失败，停服务、删测试会话、清测试状态
    SS_PORT="$PORT" "$SHARE" stop "$SESSION" >/dev/null 2>&1
    SS_PORT="$PORT" "$SHARE" stop herex >/dev/null 2>&1
    SS_PORT="$PORT" "$SHARE" stop hereauto >/dev/null 2>&1
    "$SHARE" stop idemtest >/dev/null 2>&1
    "$SHARE" stop autoport >/dev/null 2>&1
    "$SHARE" stop busyx >/dev/null 2>&1
    SS_HUB_PORT="$HUB_PORT" "$SHARE" hub stop >/dev/null 2>&1
    tmux kill-session -t "$SESSION" >/dev/null 2>&1
    tmux kill-session -t herex >/dev/null 2>&1
    tmux kill-session -t hereauto >/dev/null 2>&1
    tmux kill-session -t idemtest >/dev/null 2>&1
    tmux kill-session -t autoport >/dev/null 2>&1
    tmux kill-session -t busyx >/dev/null 2>&1
    rm -f "${STATE_DIR}/${SESSION}".{pid,state,log}
    rm -f "${STATE_DIR}/herex".{pid,state,log}
    rm -f "${STATE_DIR}/hereauto".{pid,state,log}
    rm -f "${STATE_DIR}/idemtest".{pid,state,log}
    rm -f "${STATE_DIR}/autoport".{pid,state,log}
    rm -f "${STATE_DIR}/busyx".{pid,state,log}
    rm -f "${STATE_DIR}/hub".{pid,state,log}
    rm -rf "$FAKE_CLAUDE" "$STATE_DIR"
    say "清理完成"
}
trap cleanup EXIT

# --- 1. 语法检查 ---
say "语法检查"
if bash -n "$SHARE" && bash -n "$REPO/install.sh"; then ok "share.sh / install.sh 语法通过"; else bad "语法错误"; fi

# --- 2. help ---
say "help 输出"
if "$SHARE" help | grep -q "用法"; then ok "help 包含用法"; else bad "help 缺少用法"; fi

# --- 3. doctor ---
say "doctor 环境自检"
if "$SHARE" doctor >/dev/null 2>&1; then ok "doctor 退出码 0"; else bad "doctor 失败"; fi

# --- 4. 非法会话名拒绝 ---
say "非法会话名校验"
if "$SHARE" "bad name" >/dev/null 2>&1; then bad "应拒绝含空格的会话名"; else ok "拒绝非法会话名"; fi

# --- 5. 依赖缺失时的提示（不实际卸载，跳过） ---
say "依赖检测逻辑"
if grep -q "install.sh" "$SHARE"; then ok "脚本内提示 install.sh"; else bad "未引用 install.sh"; fi

# --- 6. serve 启动 ---
say "启动 Web 服务 (会话=$SESSION 端口=$PORT)"
if SS_PORT="$PORT" "$SHARE" serve "$SESSION" >/tmp/ai-session-share-serve.log 2>&1; then
    ok "serve 启动成功"
else
    bad "serve 启动失败"
    tail -n 10 /tmp/ai-session-share-serve.log >&2
    exit 1
fi
sleep 1

# --- 7. 进程与状态文件 ---
say "进程与状态文件"
local_pid="$(cat "${STATE_DIR}/${SESSION}.pid" 2>/dev/null || echo '')"
if [[ -n "$local_pid" ]] && kill -0 "$local_pid" 2>/dev/null; then
    ok "ttyd 进程存活 (PID ${local_pid})"
else
    bad "ttyd 进程不存在"
    exit 1
fi
if [[ -f "${STATE_DIR}/${SESSION}.state" ]]; then ok "状态文件存在"; else bad "状态文件缺失"; fi

# --- 8. HTTP 访问与认证 ---
say "HTTP 认证检查"
TOKEN="$(grep '^token=' "${STATE_DIR}/${SESSION}.state" | cut -d= -f2)"
if [[ -z "$TOKEN" ]]; then bad "未生成 token"; else ok "token 已生成"; fi
code_noauth="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" 2>/dev/null || echo 000)"
if [[ "$code_noauth" == "401" ]]; then
    ok "无凭据访问被拒绝 (401)"
else
    bad "无凭据访问应返回 401，实际 ${code_noauth}"
fi
code_auth="$(curl -s -o /dev/null -w '%{http_code}' -u "ai:${TOKEN}" "http://127.0.0.1:${PORT}/" 2>/dev/null || echo 000)"
if [[ "$code_auth" == "200" ]]; then
    ok "带认证访问成功 (200)"
else
    bad "带认证访问应返回 200，实际 ${code_auth}"
fi

# --- 8.5 WebSocket 写入链路（浏览器输入 → tmux 会话） ---
# ttyd ≥1.7.4 默认只读，若未加 -W 则浏览器端无法输入，双向共享失效。
# 探针通过 /token + WebSocket 发送命令，检查命令是否真的在会话里执行。
say "WebSocket 写入链路"
MARK="${TMPDIR:-/tmp}/ai-session-share-ws-${SESSION}.mark"
rm -f "$MARK"
if command -v python3 >/dev/null 2>&1; then
    if python3 "$REPO/tests/ws_probe.py" \
        --port "$PORT" --user ai --state-file "${STATE_DIR}/${SESSION}.state" \
        --command "echo WSWRITE_OK > $MARK" >/dev/null 2>&1; then
        ok "ws 升级并发送命令成功"
    else
        bad "ws 升级/发送失败（见 ws_probe.py 输出）"
    fi
    sleep 1
    if [[ -f "$MARK" ]] && grep -q WSWRITE_OK "$MARK"; then
        ok "浏览器端输入已到达 tmux 会话（-W 可写生效）"
    else
        bad "浏览器端输入未到达终端（ttyd 只读，需加 -W）"
    fi
    rm -f "$MARK"
else
    say "  python3 缺失，跳过 WebSocket 写入测试"
fi

# --- 9. url / status 子命令 ---
say "url / status 子命令"
if SS_PORT="$PORT" "$SHARE" url "$SESSION" | grep -q ":${PORT}"; then ok "url 输出链接"; else bad "url 输出异常"; fi
if SS_PORT="$PORT" "$SHARE" status "$SESSION" | grep -q "运行中"; then ok "status 显示运行中"; else bad "status 输出异常"; fi

# --- 10. stop ---
say "停止服务"
if SS_PORT="$PORT" "$SHARE" stop "$SESSION" >/dev/null 2>&1; then ok "stop 成功"; else bad "stop 失败"; fi
sleep 0.5
if ! kill -0 "$local_pid" 2>/dev/null; then ok "ttyd 进程已退出"; else bad "ttyd 进程仍存活"; fi
if SS_PORT="$PORT" "$SHARE" status "$SESSION" | grep -q "未运行"; then ok "status 显示未运行"; else bad "status 仍显示运行"; fi

# --- 11. here 子命令（显式会话名） ---
say "here 子命令（显式会话名）"
if SS_PORT="$PORT" "$SHARE" here herex >/tmp/ai-session-share-here.log 2>&1; then
    ok "here <name> 启动成功"
else
    bad "here <name> 启动失败"
    tail -n 10 /tmp/ai-session-share-here.log >&2
    exit 1
fi
sleep 1
if [[ -f "${STATE_DIR}/herex.state" ]] && grep -q "session=herex" "${STATE_DIR}/herex.state"; then
    ok "here 状态文件记录会话 herex"
else
    bad "here 状态文件异常"
fi
# here 起的服务同样支持浏览器写入（-W 生效）
MARKH="${TMPDIR:-/tmp}/ai-session-share-ws-here.mark"
rm -f "$MARKH"
if command -v python3 >/dev/null 2>&1; then
    if python3 "$REPO/tests/ws_probe.py" \
        --port "$PORT" --user ai --state-file "${STATE_DIR}/herex.state" \
        --command "echo HERE_WRITE_OK > $MARKH" >/dev/null 2>&1 \
        && [[ -f "$MARKH" ]] && grep -q HERE_WRITE_OK "$MARKH"; then
        ok "here 服务的 WS 写入链路正常"
    else
        bad "here 服务的 WS 写入链路异常"
    fi
    rm -f "$MARKH"
fi
SS_PORT="$PORT" "$SHARE" stop herex >/dev/null 2>&1
tmux kill-session -t herex >/dev/null 2>&1

# --- 12. here 自动识别当前 tmux 会话 ---
say "here 自动识别会话（在 tmux 会话内执行）"
# 注意：tmux new-session 的命令不继承本脚本的导出变量（tmux server 环境独立），必须显式传
tmux new-session -d -s hereauto "SS_STATE_DIR='${STATE_DIR}' SS_PORT=$PORT $SHARE here >/tmp/ai-session-share-hereauto.log 2>&1; exec sleep 30"
sleep 2
if [[ -f "${STATE_DIR}/hereauto.state" ]] && grep -q "session=hereauto" "${STATE_DIR}/hereauto.state"; then
    ok "here 自动识别 tmux 会话 hereauto"
else
    bad "here 未自动识别会话"
    tail -n 10 /tmp/ai-session-share-hereauto.log >&2
fi
SS_PORT="$PORT" "$SHARE" stop hereauto >/dev/null 2>&1
tmux kill-session -t hereauto >/dev/null 2>&1

# --- 13. 会话监控面板（hub）生命周期 ---
say "hub 会话监控面板"
if SS_HUB_PORT="$HUB_PORT" "$SHARE" hub start >/tmp/ai-session-share-hub.log 2>&1; then
    ok "hub start 启动成功"
else
    bad "hub start 失败"
    tail -n 10 /tmp/ai-session-share-hub.log >&2
fi
sleep 1
HUB_PID="$(cat "${STATE_DIR}/hub.pid" 2>/dev/null || echo '')"
if [[ -n "$HUB_PID" ]] && kill -0 "$HUB_PID" 2>/dev/null; then
    ok "hub 进程存活 (PID ${HUB_PID})"
else
    bad "hub 进程不存在"
fi
if SS_HUB_PORT="$HUB_PORT" "$SHARE" hub start 2>/dev/null | grep -q "已在运行"; then
    ok "hub start 幂等（已运行时复用）"
else
    bad "hub start 幂等失败"
fi
if SS_HUB_PORT="$HUB_PORT" "$SHARE" hub status | grep -q "运行中"; then
    ok "hub status 显示运行中"
else
    bad "hub status 异常"
fi

# --- 14. hub 认证 ---
say "hub HTTP 认证"
HUB_TOKEN="$(grep '^token=' "${STATE_DIR}/hub.state" 2>/dev/null | cut -d= -f2)"
if [[ -n "$HUB_TOKEN" ]]; then ok "hub token 已生成"; else bad "hub token 缺失"; fi
code_noauth="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HUB_PORT}/" 2>/dev/null || echo 000)"
if [[ "$code_noauth" == "401" ]]; then
    ok "hub 无凭据访问被拒绝 (401)"
else
    bad "hub 无凭据应 401，实际 ${code_noauth}"
fi
code_auth="$(curl -s -o /dev/null -w '%{http_code}' -u "ai:${HUB_TOKEN}" "http://127.0.0.1:${HUB_PORT}/" 2>/dev/null || echo 000)"
if [[ "$code_auth" == "200" ]]; then
    ok "hub 带认证访问成功 (200)"
else
    bad "hub 带认证应 200，实际 ${code_auth}"
fi

# --- 15. Claude 会话实时视图（伪造一个会话验证 /t/ 端点） ---
say "hub Claude 会话视图"
FAKE_PROJ="${FAKE_CLAUDE}/-private-tmp-fakeproj"
mkdir -p "$FAKE_PROJ"
cat > "${FAKE_PROJ}/${FAKE_SID}.jsonl" <<'JSONL'
{"type":"user","message":{"role":"user","content":"FAKE_USER_MARKER 你好，请查看这个文件"},"cwd":"/tmp/fakeproj","timestamp":"2026-09-01T10:00:00.000Z","sessionId":"11111111-2222-3333-4444-555555555555"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"FAKE_ASSISTANT_MARKER 收到，我来查看"},{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/fakeproj/a.txt"}}]},"timestamp":"2026-09-01T10:00:05.000Z"}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"FAKE_RESULT_MARKER 文件内容在这里"}]},"timestamp":"2026-09-01T10:00:06.000Z"}
JSONL
# 重启 hub 使 SS_CLAUDE_DIR 生效
SS_HUB_PORT="$HUB_PORT" "$SHARE" hub stop >/dev/null 2>&1
if SS_HUB_PORT="$HUB_PORT" SS_CLAUDE_DIR="$FAKE_CLAUDE" "$SHARE" hub start >/dev/null 2>&1; then
    ok "hub 以伪造 Claude 目录重启成功"
else
    bad "hub 重启失败"
fi
sleep 1
HUB_TOKEN="$(grep '^token=' "${STATE_DIR}/hub.state" 2>/dev/null | cut -d= -f2)"
if curl -s -u "ai:${HUB_TOKEN}" "http://127.0.0.1:${HUB_PORT}/api/state" | grep -q "$FAKE_SID"; then
    ok "面板会话列表包含伪造 Claude 会话"
else
    bad "面板未列出伪造 Claude 会话"
fi
code_t="$(curl -s -o /dev/null -w '%{http_code}' -u "ai:${HUB_TOKEN}" "http://127.0.0.1:${HUB_PORT}/t/${FAKE_SID}" 2>/dev/null || echo 000)"
if [[ "$code_t" == "200" ]]; then
    ok "会话视图页面返回 200"
else
    bad "会话视图页面应 200，实际 ${code_t}"
fi
if curl -s -u "ai:${HUB_TOKEN}" "http://127.0.0.1:${HUB_PORT}/t/${FAKE_SID}/data" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d["msgs"]; sys.exit(0 if len(m)>=2 and any("FAKE_USER_MARKER" in p["x"] for p in m[0]["parts"]) and any("FAKE_ASSISTANT_MARKER" in p["x"] for x in [m[1]] for p in x["parts"]) else 1)' 2>/dev/null; then
    ok "会话消息解析正确（用户/助手内容齐全）"
else
    bad "会话消息解析异常"
fi
code_404="$(curl -s -o /dev/null -w '%{http_code}' -u "ai:${HUB_TOKEN}" "http://127.0.0.1:${HUB_PORT}/t/00000000-0000-0000-0000-000000000000" 2>/dev/null || echo 000)"
if [[ "$code_404" == "404" ]]; then
    ok "不存在的会话返回 404"
else
    bad "不存在的会话应 404，实际 ${code_404}"
fi

# --- 16. hook：不在 tmux 内 → 输出当前 Claude 会话的实时视图链接 ---
say "hook 会话感知（非 tmux）"
HOOK_OUT="$(printf '{"prompt":"/share_session","session_id":"%s"}' "$FAKE_SID" \
    | SS_HUB_PORT="$HUB_PORT" SS_CLAUDE_DIR="$FAKE_CLAUDE" SS_STATE_DIR="$STATE_DIR" \
      python3 "$REPO/hooks/share_session_hook.py" 2>/dev/null)"
if echo "$HOOK_OUT" | grep -q "decision.*block"; then
    ok "hook 返回 block 决策（零 token）"
else
    bad "hook 未返回 block"
fi
if echo "$HOOK_OUT" | grep -q ":${HUB_PORT}/t/${FAKE_SID}"; then
    ok "hook 输出当前会话实时视图链接 (/t/${FAKE_SID})"
else
    bad "hook 未输出当前会话链接，输出: $(echo "$HOOK_OUT" | head -c 300)"
fi
if echo "$HOOK_OUT" | grep -q ":7681"; then
    bad "hook 错误地输出了其他会话(7681)的链接"
else
    ok "未混入无关会话链接"
fi

# --- 17. hook：无关 prompt 放行 ---
say "hook 无关 prompt 放行"
if [[ -z "$(printf '{"prompt":"帮我写个函数"}' | SS_STATE_DIR="$STATE_DIR" python3 "$REPO/hooks/share_session_hook.py" 2>/dev/null)" ]]; then
    ok "无关 prompt 空输出放行"
else
    bad "无关 prompt 被误拦截"
fi

# --- 18. serve 幂等 + 自动选端口 ---
say "serve 幂等与自动选端口"
tmux new-session -d -s idemtest
if SS_STATE_DIR="$STATE_DIR" "$SHARE" serve idemtest >/dev/null 2>&1; then
    ok "serve 首次启动成功"
else
    bad "serve 首次启动失败"
fi
IDEM_OUT="$(SS_STATE_DIR="$STATE_DIR" "$SHARE" serve idemtest 2>&1 || true)"
if echo "$IDEM_OUT" | grep -q "复用现有链接"; then
    ok "serve 重复执行幂等（复用现有链接）"
else
    bad "serve 重复执行未复用: $(echo "$IDEM_OUT" | head -c 200)"
fi
IDEM_PORT="$(grep '^port=' "${STATE_DIR}/idemtest.state" 2>/dev/null | cut -d= -f2)"
if [[ -n "$IDEM_PORT" ]] && curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${IDEM_PORT}/" 2>/dev/null | grep -q "401"; then
    ok "幂等服务端口 ${IDEM_PORT} 仍正常响应"
else
    bad "幂等服务端口 ${IDEM_PORT} 无响应"
fi
# 自动选端口：默认 7681 被占时应顺延（本机有正在共享的服务或 CI 空闲则用 7681 本身）
tmux new-session -d -s autoport
BASE_BUSY=0
if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:7681 -sTCP:LISTEN >/dev/null 2>&1; then
    BASE_BUSY=1
fi
if SS_STATE_DIR="$STATE_DIR" "$SHARE" serve autoport >/dev/null 2>&1; then
    AUTO_PORT="$(grep '^port=' "${STATE_DIR}/autoport.state" 2>/dev/null | cut -d= -f2)"
    if [[ $BASE_BUSY -eq 1 ]]; then
        if [[ -n "$AUTO_PORT" && "$AUTO_PORT" != "7681" ]]; then
            ok "端口被占时自动顺延 (7681 → ${AUTO_PORT})"
        else
            bad "端口被占时未顺延，仍为 ${AUTO_PORT}"
        fi
    else
        if [[ "$AUTO_PORT" == "7681" ]]; then
            ok "默认端口空闲时直接使用 (${AUTO_PORT})"
        else
            bad "端口空闲时不应顺延，实际 ${AUTO_PORT}"
        fi
    fi
else
    bad "autoport serve 启动失败"
fi
# 显式指定 SS_PORT 且被占 → 应报错拒绝（用另一个会话，避免命中幂等路径）
tmux new-session -d -s busyx
if SS_STATE_DIR="$STATE_DIR" SS_PORT="$AUTO_PORT" "$SHARE" serve busyx >/dev/null 2>&1; then
    bad "显式端口被占时应拒绝"
else
    ok "显式端口被占时报错拒绝"
fi
SS_STATE_DIR="$STATE_DIR" "$SHARE" stop idemtest >/dev/null 2>&1
SS_STATE_DIR="$STATE_DIR" "$SHARE" stop autoport >/dev/null 2>&1
SS_STATE_DIR="$STATE_DIR" "$SHARE" stop busyx >/dev/null 2>&1
tmux kill-session -t idemtest >/dev/null 2>&1
tmux kill-session -t autoport >/dev/null 2>&1
tmux kill-session -t busyx >/dev/null 2>&1

# --- 19. hub stop ---
say "hub 停止"
if SS_HUB_PORT="$HUB_PORT" "$SHARE" hub stop >/dev/null 2>&1; then ok "hub stop 成功"; else bad "hub stop 失败"; fi
sleep 0.5
if [[ -n "$HUB_PID" ]] && ! kill -0 "$HUB_PID" 2>/dev/null; then
    ok "hub 进程已退出"
else
    bad "hub 进程仍存活"
fi
if SS_HUB_PORT="$HUB_PORT" "$SHARE" hub status | grep -q "未运行"; then
    ok "hub status 显示未运行"
else
    bad "hub status 仍显示运行"
fi

# --- 汇总 ---
echo
say "结果: ${PASS} 通过, ${FAIL} 失败"
[[ $FAIL -eq 0 ]]
