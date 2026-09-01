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
    SS_HUB_PORT="$HUB_PORT" SS_FORCE=1 "$SHARE" hub stop >/dev/null 2>&1
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

# --- 20. 托管会话(自管 PTY,不依赖 tmux) ---
say "托管会话(免 tmux,生命周期绑定)"
if SS_HUB_PORT="$HUB_PORT" "$SHARE" hub start >/dev/null 2>&1; then
    ok "hub 重启成功(承载托管会话)"
else
    bad "hub 重启失败"
fi
sleep 1
PROBE="$REPO/tests/hub_ws_probe.py"
HUB_TOKEN="$(grep '^token=' "${STATE_DIR}/hub.state" 2>/dev/null | cut -d= -f2)"
MGMT_SID="$(python3 "$PROBE" new --cmd "bash -c 'echo MGMT_HELLO_WORLD; sleep 60'" 2>/dev/null)"
if [[ "$MGMT_SID" == m* ]]; then
    ok "托管会话已创建 (id=${MGMT_SID})"
else
    bad "托管会话创建失败: ${MGMT_SID}"
fi
code_w="$(curl -s -o /dev/null -w '%{http_code}' -u "ai:${HUB_TOKEN}" "http://127.0.0.1:${HUB_PORT}/w/${MGMT_SID}" 2>/dev/null || echo 000)"
if [[ "$code_w" == "200" ]]; then
    ok "托管会话网页终端页 200"
else
    bad "托管会话终端页应 200,实际 ${code_w}"
fi
if curl -s -u "ai:${HUB_TOKEN}" "http://127.0.0.1:${HUB_PORT}/api/state" | grep -q "\"${MGMT_SID}\""; then
    ok "面板列出托管会话"
else
    bad "面板未列出托管会话"
fi
if python3 "$PROBE" read --id "$MGMT_SID" --until MGMT_HELLO_WORLD --timeout 10 2>/dev/null; then
    ok "PTY 输出经 WebSocket 到达(含历史回放)"
else
    bad "WebSocket 未收到会话输出"
fi

# --- 21. WS 输入 → PTY 执行(双向,用交互式 bash) ---
MARKM="${TMPDIR:-/tmp}/ai-session-share-mgmt.mark"
rm -f "$MARKM"
IN_SID="$(python3 "$PROBE" new --cmd "bash" 2>/dev/null)"
if [[ "$IN_SID" == m* ]] \
    && python3 "$PROBE" write --id "$IN_SID" --text "echo MGMT_INPUT_OK > $MARKM"$'\n' 2>/dev/null; then
    sleep 1
    if [[ -f "$MARKM" ]] && grep -q MGMT_INPUT_OK "$MARKM"; then
        ok "浏览器输入到达 PTY 并执行(双向)"
    else
        bad "浏览器输入未在会话内执行"
    fi
else
    bad "WebSocket 写入失败"
fi
rm -f "$MARKM"
python3 "$REPO/hub_server.py" api kill "$IN_SID" >/dev/null 2>&1 || true

# --- 22. 进程退出 → 会话自动结束(核心生命周期) ---
say "托管会话生命周期(进程退出自动结束)"
EXIT_SID="$(python3 "$PROBE" new --cmd "bash -c 'echo BYE; exit 0'" 2>/dev/null)"
if python3 "$PROBE" ended --id "$EXIT_SID" --timeout 10 2>/dev/null; then
    ok "进程退出后会话自动结束"
else
    bad "会话未随进程退出而结束"
fi
sleep 0.5
if curl -s -u "ai:${HUB_TOKEN}" "http://127.0.0.1:${HUB_PORT}/w/${EXIT_SID}" | grep -q "已结束"; then
    ok "结束后页面显示'会话已结束'"
else
    bad "结束后页面未提示已结束"
fi

# --- 23. share attach 本机连接 ---
say "share attach 本机连接"
ATT_SID="$(python3 "$PROBE" new --cmd "bash" 2>/dev/null)"
ATT_MARK="${TMPDIR:-/tmp}/ai-session-share-attach.mark"
rm -f "$ATT_MARK"
python3 - "$ATT_SID" "$ATT_MARK" <<'PYEOF' 2>/dev/null
import os, pty, sys, time
sid, mark = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("python3", ["python3", "hub_attach.py", sid])
else:
    time.sleep(1.5)
    try:
        os.write(fd, b"echo ATTACH_OK > " + mark.encode() + b"\n")
    except OSError:
        pass
    for _ in range(40):
        time.sleep(0.25)
        if os.path.exists(mark):
            break
    try:
        os.write(fd, b"exit\n")   # 结束会话,attach 应自动退出
    except OSError:
        pass
    for _ in range(20):
        if os.waitpid(pid, os.WNOHANG)[0] != 0:
            break
        time.sleep(0.25)
    try:
        os.kill(pid, 9)
    except OSError:
        pass
PYEOF
if [[ -f "$ATT_MARK" ]]; then
    ok "attach 输入直达会话(本机直通)"
else
    bad "attach 连接失败"
fi
rm -f "$ATT_MARK"
python3 "$REPO/hub_server.py" api kill "$ATT_SID" >/dev/null 2>&1 || true
python3 "$REPO/hub_server.py" api kill "$MGMT_SID" >/dev/null 2>&1 || true

# --- 24. hook 托管会话分支 ---
say "hook 托管会话分支"
HOOK_M="$(printf '{"prompt":"/share_session"}' | SS_MANAGED_ID="testmid01" SS_HUB_PORT="$HUB_PORT" SS_STATE_DIR="$STATE_DIR" python3 "$REPO/hooks/share_session_hook.py" 2>/dev/null)"
if echo "$HOOK_M" | grep -q "/w/testmid01"; then
    ok "hook 输出托管会话链接 (/w/testmid01)"
else
    bad "hook 未输出托管链接: $(echo "$HOOK_M" | head -c 200)"
fi
if echo "$HOOK_M" | grep -q "生命周期"; then
    ok "hook 说明生命周期绑定"
else
    bad "hook 缺生命周期说明"
fi

# --- 25. API 防 CSRF ---
say "API 防 CSRF"
code_csrf="$(curl -s -o /dev/null -w '%{http_code}' -X POST -u "ai:${HUB_TOKEN}" -H 'Content-Type: application/json' -d '{"cmd":"bash"}' "http://127.0.0.1:${HUB_PORT}/api/new" 2>/dev/null || echo 000)"
if [[ "$code_csrf" == "403" ]]; then
    ok "缺 X-Share-API 头的 POST 被拒 (403)"
else
    bad "缺防 CSRF 头应 403,实际 ${code_csrf}"
fi

# --- 26. hub stop 保护(有托管会话时拒绝) ---
say "hub stop 保护"
PROTECT_SID="$(python3 "$PROBE" new --cmd "sleep 60" 2>/dev/null)"
if SS_HUB_PORT="$HUB_PORT" "$SHARE" hub stop >/dev/null 2>&1; then
    bad "有存活托管会话时 hub stop 应拒绝"
else
    ok "有存活托管会话时 hub stop 被拒绝(SS_FORCE=1 可强制)"
fi
SS_HUB_PORT="$HUB_PORT" SS_FORCE=1 "$SHARE" hub stop >/dev/null 2>&1
sleep 0.5
if ! kill -0 "$(pgrep -f "hub_server.py" | head -1)" 2>/dev/null || ! pgrep -f "hub_server.py" >/dev/null 2>&1; then
    ok "SS_FORCE=1 强制停止成功"
else
    # 可能有真实面板在 7690(非测试端口),只确认测试端口已停
    if ! curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${HUB_PORT}/" 2>/dev/null; then
        ok "SS_FORCE=1 强制停止成功(测试端口已关闭)"
    else
        bad "强制停止失败"
    fi
fi

# --- 27. hub send/output/session 程序化 API ---
say "hub 程序化 API(send/output/session)"
# 26 的强制停止测试后需要重新拉起面板,后续 API/MCP/全局发现测试都依赖它
if SS_HUB_PORT="$HUB_PORT" "$SHARE" hub start >/dev/null 2>&1; then
    ok "hub 重启成功(承载程序化 API/MCP)"
else
    bad "hub 重启失败"
fi
sleep 1
HUB_TOKEN="$(grep '^token=' "${STATE_DIR}/hub.state" 2>/dev/null | cut -d= -f2)"
API_SID="$(python3 "$PROBE" new --cmd "bash" 2>/dev/null)"
if [[ "$API_SID" == m* ]]; then
    sleep 0.5
    curl -s -u "ai:${HUB_TOKEN}" -X POST -H 'Content-Type: application/json' -H 'X-Share-API: 1' \
        -d "{\"text\":\"echo API_EP_OK$RANDOM\\n\"}" "http://127.0.0.1:${HUB_PORT}/api/send/${API_SID}" >/dev/null
    sleep 0.8
    if curl -s -u "ai:${HUB_TOKEN}" "http://127.0.0.1:${HUB_PORT}/api/output/${API_SID}?tail=4096" \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["ok"] and "API_EP_OK" in d["text"] else 1)' 2>/dev/null; then
        ok "/api/send → /api/output 往返一致"
    else
        bad "/api/send 或 /api/output 异常"
    fi
    if curl -s -u "ai:${HUB_TOKEN}" "http://127.0.0.1:${HUB_PORT}/api/session/${API_SID}" \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["ok"] and "output_preview" in d else 1)' 2>/dev/null; then
        ok "/api/session 详情(含输出预览)"
    else
        bad "/api/session 异常"
    fi
else
    bad "API 测试会话创建失败"
fi
python3 "$REPO/hub_server.py" api kill "$API_SID" >/dev/null 2>&1 || true

# --- 28. 交互式 bash 的 kill 升级(TERM 忽略 → KILL 兜底) ---
say "kill 对交互式 bash 的升级"
KILLB_SID="$(python3 "$PROBE" new --cmd "bash" 2>/dev/null)"
sleep 0.3
if python3 "$REPO/hub_server.py" api kill "$KILLB_SID" 2>/dev/null \
    | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("exited") else 1)' 2>/dev/null; then
    ok "交互式 bash 被可靠结束(进程组 TERM→KILL)"
else
    bad "交互式 bash 未被结束(SIGTERM 被忽略?)"
fi

# --- 29. MCP 服务器(piped JSON-RPC 全六工具) ---
say "MCP 服务器 roundtrip"
MCP_OUT="$(python3 - <<'PYEOF'
import json, subprocess, time

def rpc(msgs):
    stdin = "\n".join(json.dumps(m) for m in msgs) + "\n"
    r = subprocess.run(["python3", "mcp_server.py"], input=stdin,
                       capture_output=True, text=True, timeout=60)
    return [json.loads(l) for l in r.stdout.strip().splitlines()]

fails = []
rs = rpc([
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}},
    {"jsonrpc":"2.0","id":2,"method":"tools/list"},
])
if rs[0]["result"]["serverInfo"]["name"] != "ai-session-share":
    fails.append("initialize")
tools = [t["name"] for t in rs[1]["result"]["tools"]]
if tools != ["list_sessions","session_status","spawn_session","send_input","read_output","kill_session"]:
    fails.append("tools/list: " + ",".join(tools))

r = rpc([{"jsonrpc":"2.0","id":3,"method":"tools/call",
          "params":{"name":"spawn_session","arguments":{"command":"bash","cwd":"/tmp"}}}])
text = r[0]["result"]["content"][0]["text"]
if "托管会话已创建" not in text:
    fails.append("spawn: " + text[:80])
sid = text.split("托管会话已创建: ")[1].split("\n")[0]

time.sleep(0.6)
r = rpc([{"jsonrpc":"2.0","id":4,"method":"tools/call",
          "params":{"name":"send_input","arguments":{"session_id":sid,"text":"echo MCP_T_OK\r"}}}])
time.sleep(0.8)
r = rpc([{"jsonrpc":"2.0","id":5,"method":"tools/call",
          "params":{"name":"read_output","arguments":{"session_id":sid}}}])
if "MCP_T_OK" not in r[0]["result"]["content"][0]["text"]:
    fails.append("send/read roundtrip")

r = rpc([{"jsonrpc":"2.0","id":6,"method":"tools/call",
          "params":{"name":"session_status","arguments":{"session_id":sid}}}])
if json.loads(r[0]["result"]["content"][0]["text"])["state"] != "运行中":
    fails.append("session_status")

r = rpc([{"jsonrpc":"2.0","id":7,"method":"tools/call",
          "params":{"name":"list_sessions","arguments":{}}}])
if sid not in r[0]["result"]["content"][0]["text"]:
    fails.append("list_sessions")

r = rpc([{"jsonrpc":"2.0","id":8,"method":"tools/call",
          "params":{"name":"kill_session","arguments":{"session_id":sid}}}])
if "已请求结束" not in r[0]["result"]["content"][0]["text"]:
    fails.append("kill_session")
time.sleep(0.4)
r = rpc([{"jsonrpc":"2.0","id":9,"method":"tools/call",
          "params":{"name":"session_status","arguments":{"session_id":sid}}}])
if json.loads(r[0]["result"]["content"][0]["text"])["state"] != "已结束":
    fails.append("kill 后状态")

r = rpc([{"jsonrpc":"2.0","id":10,"method":"tools/call",
          "params":{"name":"nope","arguments":{}}}])
if r[0].get("error", {}).get("code") != -32602:
    fails.append("未知工具错误码")

r = rpc([{"jsonrpc":"2.0","id":11,"method":"tools/call",
          "params":{"name":"session_status","arguments":{"session_id":"nonexistent99"}}}])
if not r[0]["result"].get("isError"):
    fails.append("不存在会话应 isError")

print("FAIL:" + ";".join(fails) if fails else "MCP_ALL_OK")
PYEOF
)" 2>/dev/null
if [[ "$MCP_OUT" == "MCP_ALL_OK" ]]; then
    ok "MCP 六工具 roundtrip + 错误路径全过"
else
    bad "MCP 测试失败: ${MCP_OUT:-无输出}"
fi

# --- 30. 全局发现:share sessions / SS_HUB_URL / 注册器幂等 ---
say "全局发现与注册"
if SS_HUB_PORT="$HUB_PORT" "$SHARE" sessions 2>/dev/null | grep -q "ai-session-share 活动会话"; then
    ok "share sessions 全局视图输出正常"
else
    bad "share sessions 输出异常"
fi
# SS_HUB_URL/SS_HUB_TOKEN 兜底:清掉 hub.state 模拟"仅靠环境变量发现"
mv "${STATE_DIR}/hub.state" "${STATE_DIR}/hub.state.bak"
if SS_HUB_URL="http://127.0.0.1:${HUB_PORT}" SS_HUB_TOKEN="${HUB_TOKEN}" \
    python3 "$REPO/hub_server.py" api sessions 2>/dev/null | grep -q "活动会话"; then
    ok "SS_HUB_URL+SS_HUB_TOKEN 兜底发现 hub(无 hub.state 时)"
else
    bad "SS_HUB_URL 兜底失败"
fi
mv "${STATE_DIR}/hub.state.bak" "${STATE_DIR}/hub.state"
# install_env_var 幂等(临时 rc)
TMPRC="${TMPDIR:-/tmp}/ai-session-share-rc-test.txt"
rm -f "$TMPRC"
sed -n '/^install_env_var()/,/^}/p' "$REPO/install.sh" > "${TMPDIR:-/tmp}/ie.sh"
(
    REPO_DIR="$REPO"
    log_ok() { :; }
    export SS_RC_FILE="$TMPRC" SS_HUB_PORT="$HUB_PORT"
    # shellcheck disable=SC1090
    source "${TMPDIR:-/tmp}/ie.sh"
    install_env_var
    install_env_var
) 
if [[ "$(grep -c "export SS_HUB_URL=" "$TMPRC")" == "1" ]]; then
    ok "install_env_var 幂等写入(仅 1 条)"
else
    bad "install_env_var 重复写入: $(grep -c 'export SS_HUB_URL=' "$TMPRC") 条"
fi
rm -f "$TMPRC" "${TMPDIR:-/tmp}/ie.sh"
# mcp_register 幂等(假 HOME)
FAKEH="${TMPDIR:-/tmp}/ai-session-share-fake-home"
mkdir -p "$FAKEH/bin"
for c in claude atomcode codex; do
    printf '#!/bin/sh\nexit 0\n' > "$FAKEH/bin/$c"
    chmod +x "$FAKEH/bin/$c"
done
PATH="$FAKEH/bin:$PATH" python3 "$REPO/mcp_register.py" --home "$FAKEH" >/dev/null 2>&1
PATH="$FAKEH/bin:$PATH" python3 "$REPO/mcp_register.py" --home "$FAKEH" >/dev/null 2>&1
TOML_N="$(grep -c "mcp_servers.ai-session-share" "$FAKEH/.codex/config.toml" 2>/dev/null || echo 0)"
if [[ "$TOML_N" == "1" ]] && python3 -c "import json,sys; json.load(open('$FAKEH/.claude.json'))" 2>/dev/null; then
    ok "mcp_register 三客户端幂等注册(JSON 合法/TOML 不重复)"
else
    bad "mcp_register 幂等失败(TOML 段数: ${TOML_N})"
fi
rm -rf "$FAKEH"

# --- 汇总 ---
echo
say "结果: ${PASS} 通过, ${FAIL} 失败"
[[ $FAIL -eq 0 ]]
