#!/usr/bin/env bash
#
# ai-session-share 冒烟测试
# 覆盖：语法检查 / 子命令行为 / 面板生命周期与认证 / 托管会话(PTY/生命周期/attach) /
#       Claude 会话视图 / hook 会话感知 / MCP / 免密登录 / 全局发现
#
# 用法：
#   ./tests/test.sh                  # 全部测试
#   TEST_HUB_PORT=17691 ./tests/test.sh  # 指定测试端口（默认 17690）

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARE="$REPO/share.sh"
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
    # 无论成功失败，停面板(会连带结束托管会话)、清测试状态
    SS_HUB_PORT="$HUB_PORT" SS_FORCE=1 "$SHARE" hub stop >/dev/null 2>&1
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

# --- 5. 依赖缺失时的提示（不实际卸载，跳过） ---
say "依赖检测逻辑"
if grep -q "install.sh" "$SHARE"; then ok "脚本内提示 install.sh"; else bad "未引用 install.sh"; fi

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
if curl -s -u "ai:${HUB_TOKEN}" "http://127.0.0.1:${HUB_PORT}/t/${FAKE_SID}" 2>/dev/null | grep -q "bubble"; then
    ok "会话视图为左右气泡聊天样式"
else
    bad "会话视图缺气泡样式"
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
# SS_HOOK_VIEW_ONLY=1:确定性测只读视图分支(默认行为会 spawn claude --resume 托管会话,真实跑)
HOOK_OUT="$(printf '{"prompt":"/share_session","session_id":"%s","transcript_path":"%s/%s.jsonl"}' \
    "$FAKE_SID" "$FAKE_PROJ" "$FAKE_SID" \
    | SS_HOOK_VIEW_ONLY=1 SS_HUB_PORT="$HUB_PORT" SS_CLAUDE_DIR="$FAKE_CLAUDE" SS_STATE_DIR="$STATE_DIR" \
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
if echo "$HOOK_OUT" | grep -q "在网页继续此会话"; then
    ok "hook 提示可在网页继续会话"
else
    bad "hook 缺少继续会话提示"
fi
if echo "$HOOK_OUT" | grep -qE "http://ai:[0-9a-f]+@"; then
    bad "hook 仍输出内嵌凭据链接(浏览器已禁用)"
else
    ok "无内嵌凭据链接(纯地址+密码)"
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

# --- 20. 托管会话(自管 PTY,生命周期绑定) ---
say "托管会话(生命周期绑定)"
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
# (SS_CLAUDE_DIR 必须继续指向伪造目录,resume-cwd 兜底测试依赖它)
if SS_HUB_PORT="$HUB_PORT" SS_CLAUDE_DIR="$FAKE_CLAUDE" "$SHARE" hub start >/dev/null 2>&1; then
    ok "hub 重启成功(承载程序化 API/MCP)"
else
    bad "hub 重启失败"
fi
sleep 1
HUB_TOKEN="$(grep '^token=' "${STATE_DIR}/hub.state" 2>/dev/null | cut -d= -f2)"
# claude --resume 服务端 cwd 兜底:伪造带 cwd 的会话 jsonl,POST 不带 cwd,应落 /tmp 而非 $HOME
FAKE_PROJ2="${FAKE_CLAUDE}/-private-tmp-fakeproj2"
mkdir -p "$FAKE_PROJ2"
FAKE_SID2="99999999-8888-7777-6666-555555555555"
printf '{"type":"user","message":{"role":"user","content":"probe"},"cwd":"/tmp","timestamp":"2026-09-01T10:00:00.000Z"}\n' \
    > "${FAKE_PROJ2}/${FAKE_SID2}.jsonl"
if curl -s -X POST -H 'Content-Type: application/json' -H 'X-Share-API: 1' \
        -u "ai:${HUB_TOKEN}" -d '{"argv":["claude","--resume","'"${FAKE_SID2}"'"]}' \
        "http://127.0.0.1:${HUB_PORT}/api/new" | grep -q '"ok": *true'; then
    sleep 1
    RESUME_SID="$(python3 "$REPO/hub_server.py" api state | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(next((x['id'] for x in d['managed'] if '--resume ${FAKE_SID2}' in x['cmd'] and not x['exited']), ''))")"
    if [[ -n "$RESUME_SID" ]]; then
        RPID="$(python3 "$REPO/hub_server.py" api session "$RESUME_SID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])')"
        RCWD="$(lsof -p "$RPID" 2>/dev/null | awk '$4=="cwd" {print $NF; exit}')"
        # /tmp 在 macOS 上是 /private/tmp 的软链,按真实路径归一后比较
        RCWD_REAL="$(cd "$RCWD" 2>/dev/null && pwd -P)"
        TMP_REAL="$(cd /tmp && pwd -P)"
        if [[ "$RCWD_REAL" == "$TMP_REAL" ]]; then
            ok "claude --resume 服务端兜底解析出原会话 cwd(/tmp)"
        else
            bad "resume cwd 兜底失败,实际: ${RCWD:-未知}"
        fi
        python3 "$REPO/hub_server.py" api kill "$RESUME_SID" >/dev/null 2>&1
    else
        bad "resume 测试会话未找到"
    fi
else
    bad "resume cwd 测试创建失败"
fi
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

# --- 31. 终端页自包含资源 + 看板去 tmux ---
say "终端页自包含与看板措辞"
PAGE_TMP="${TMPDIR:-/tmp}/ai-session-share-w-page.html"
SELF_SID="$(python3 "$PROBE" new --cmd "bash" 2>/dev/null)"
if [[ "$SELF_SID" == m* ]] \
    && curl -s -u "ai:${HUB_TOKEN}" "http://127.0.0.1:${HUB_PORT}/w/${SELF_SID}" -o "$PAGE_TMP" 2>/dev/null; then
    if grep -q "/assets/xterm.js" "$PAGE_TMP" && ! grep -q "cdn.jsdelivr" "$PAGE_TMP"; then
        ok "终端页引用本地资源(零外部 CDN)"
    else
        bad "终端页仍含外部 CDN 引用"
    fi
    # JS 字符串字面量必须含字面反斜杠(\\n),而不是被 Python 展开的真实换行(会致 SyntaxError)
    if grep -qF "value+'\\n'" "$PAGE_TMP"; then
        ok "JS 转义正确(无跨行字符串字面量)"
    else
        bad "JS 转义异常(SyntaxError 风险)"
    fi
else
    bad "终端页获取失败"
fi
code_asset="$(curl -s -o /dev/null -w '%{http_code}' -u "ai:${HUB_TOKEN}" "http://127.0.0.1:${HUB_PORT}/assets/xterm.js" 2>/dev/null || echo 000)"
if [[ "$code_asset" == "200" ]]; then
    ok "xterm 组件已本地缓存并服务"
elif ! curl -s -m 6 -o /dev/null "https://cdn.jsdelivr.net" 2>/dev/null; then
    say "  外网不可达,跳过组件缓存检查"
else
    bad "xterm 组件应 200,实际 ${code_asset}"
fi
if ! curl -s -u "ai:${HUB_TOKEN}" "http://127.0.0.1:${HUB_PORT}/" 2>/dev/null | grep -qi "tmux" \
    && ! curl -s -u "ai:${HUB_TOKEN}" "http://127.0.0.1:${HUB_PORT}/api/state" 2>/dev/null | grep -q '"tmux"'; then
    ok "看板与状态接口不再出现 tmux 字样"
else
    bad "看板/状态接口仍含 tmux"
fi
rm -f "$PAGE_TMP"
python3 "$REPO/hub_server.py" api kill "$SELF_SID" >/dev/null 2>&1 || true

# --- 32. 免密登录链接(?key=) + TERM 彩色输出 + fit 调用顺序/主题色 ---
say "免密登录链接(cookie)"
COOKIE_JAR="${TMPDIR:-/tmp}/ai-session-share-cookies.txt"
rm -f "$COOKIE_JAR"
code_badkey="$(curl -s -o /dev/null -w '%{http_code}' -c "$COOKIE_JAR" "http://127.0.0.1:${HUB_PORT}/?key=wrong-token-xyz" 2>/dev/null)"
if [[ "$code_badkey" == "401" ]]; then
    ok "错误 key 不授权(401)"
else
    bad "错误 key 应 401,实际 ${code_badkey}"
fi
rm -f "$COOKIE_JAR"
code_goodkey="$(curl -s -o /dev/null -w '%{http_code}' -c "$COOKIE_JAR" "http://127.0.0.1:${HUB_PORT}/?key=${HUB_TOKEN}" 2>/dev/null)"
if [[ "$code_goodkey" == "200" ]] && grep -q "ss_auth" "$COOKIE_JAR" 2>/dev/null; then
    ok "正确 key 授权(200)并种下 cookie"
else
    bad "正确 key 应 200 并种 cookie,实际状态码 ${code_goodkey}"
fi
code_cookie_only="$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" "http://127.0.0.1:${HUB_PORT}/" 2>/dev/null)"
if [[ "$code_cookie_only" == "200" ]]; then
    ok "凭 cookie 免密访问(无需再传 key/账号密码)"
else
    bad "cookie 免密访问失败,实际 ${code_cookie_only}"
fi
code_nocreds="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HUB_PORT}/" 2>/dev/null)"
if [[ "$code_nocreds" == "401" ]]; then
    ok "无任何凭据仍拒绝(未削弱默认安全性)"
else
    bad "无凭据应 401,实际 ${code_nocreds}"
fi
rm -f "$COOKIE_JAR"

say "托管会话 TERM 彩色输出与网页终端样式"
TERM_SID="$(python3 "$PROBE" new --cmd "bash" 2>/dev/null)"
if [[ "$TERM_SID" == m* ]]; then
    sleep 0.5
    curl -s -u "ai:${HUB_TOKEN}" -X POST -H 'Content-Type: application/json' -H 'X-Share-API: 1' \
        -d '{"text":"echo TERM_IS_$TERM\n"}' "http://127.0.0.1:${HUB_PORT}/api/send/${TERM_SID}" >/dev/null
    sleep 0.8
    if curl -s -u "ai:${HUB_TOKEN}" "http://127.0.0.1:${HUB_PORT}/api/output/${TERM_SID}?tail=4096" \
        | grep -q "TERM_IS_xterm-256color"; then
        ok "托管会话默认 TERM=xterm-256color(下游 CLI 会输出彩色)"
    else
        bad "托管会话 TERM 未正确设置"
    fi
    # 关键回归:宿主环境常见的 NO_COLOR/FORCE_COLOR=0 不能被子进程原样继承,
    # 否则遵循 no-color.org 规范的 CLI(如 claude)会整体不发颜色码,TERM 设对也没用
    curl -s -u "ai:${HUB_TOKEN}" -X POST -H 'Content-Type: application/json' -H 'X-Share-API: 1' \
        -d '{"text":"echo NOCOLOR=[$NO_COLOR] FORCECOLOR=[$FORCE_COLOR]\n"}' \
        "http://127.0.0.1:${HUB_PORT}/api/send/${TERM_SID}" >/dev/null
    sleep 0.8
    OUT_ENV="$(curl -s -u "ai:${HUB_TOKEN}" "http://127.0.0.1:${HUB_PORT}/api/output/${TERM_SID}?tail=4096")"
    if echo "$OUT_ENV" | grep -q "NOCOLOR=\[\] FORCECOLOR=\[1\]"; then
        ok "宿主的 NO_COLOR 已清除、FORCE_COLOR 已强制为 1(不再被宿主环境否决颜色)"
    else
        bad "NO_COLOR/FORCE_COLOR 未按预期覆盖: $(echo "$OUT_ENV" | grep -o 'NOCOLOR=.*FORCECOLOR=\[[^]]*\]' | tail -1)"
    fi
    python3 "$REPO/hub_server.py" api kill "$TERM_SID" >/dev/null 2>&1
else
    bad "TERM 测试会话创建失败"
fi
WPAGE_TMP="${TMPDIR:-/tmp}/ai-session-share-w-fit.html"
FIT_SID="$(python3 "$PROBE" new --cmd "bash" 2>/dev/null)"
if [[ "$FIT_SID" == m* ]] \
    && curl -s -u "ai:${HUB_TOKEN}" "http://127.0.0.1:${HUB_PORT}/w/${FIT_SID}" -o "$WPAGE_TMP" 2>/dev/null; then
    OPEN_LINE="$(grep -n "term.open(document" "$WPAGE_TMP" | head -1 | cut -d: -f1)"
    FIT_LINE="$(grep -n "fit.fit();" "$WPAGE_TMP" | head -1 | cut -d: -f1)"
    if [[ -n "$OPEN_LINE" && -n "$FIT_LINE" && "$OPEN_LINE" -lt "$FIT_LINE" ]]; then
        ok "xterm term.open() 在 fit() 之前调用(否则量不到容器尺寸,显示区域会很小)"
    else
        bad "fit 调用顺序错误(open=${OPEN_LINE:-无} fit=${FIT_LINE:-无})"
    fi
    if grep -q "brightGreen" "$WPAGE_TMP" && grep -q "foreground:" "$WPAGE_TMP"; then
        ok "终端主题含完整 ANSI 配色(不再是单一白色前景)"
    else
        bad "终端主题缺少 ANSI 配色"
    fi
    python3 "$REPO/hub_server.py" api kill "$FIT_SID" >/dev/null 2>&1
else
    bad "fit 顺序测试会话创建失败"
fi
rm -f "$WPAGE_TMP"

# --- 汇总 ---
echo
say "结果: ${PASS} 通过, ${FAIL} 失败"
[[ $FAIL -eq 0 ]]
