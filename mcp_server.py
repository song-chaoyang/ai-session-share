#!/usr/bin/env python3
"""ai-session-share MCP 服务器 —— 让任何支持 MCP 的 AI 客户端查看与操作共享会话。

一个 AI 客户端(claude / atomcode / codex / 任何 MCP 客户端)连上本服务器后,
即可在不离开对话的情况下:

  - list_sessions   列出所有活动会话(托管/Claude/atomcode/共享服务)与状态
  - session_status  查看单个托管会话详情(含最近输出预览)
  - spawn_session   新建托管会话(如 claude / bash),返回网页链接
  - send_input      向托管会话发送键盘输入(操作会话,与网页同一 PTY 通路)
  - read_output     读取托管会话最近输出(可指定字节数)
  - kill_session    结束托管会话

协议:stdio 传输,行分帧 JSON-RPC 2.0(标准 MCP stdio);只用 Python 标准库。
鉴权:复用 hub 的 Basic Auth token(从 SS_STATE_DIR/hub.state 读取,
端口缺失时回退 SS_HUB_URL 环境变量)。

用法(手动测试):
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | python3 mcp_server.py
"""
import base64
import json
import os
import re
import shlex
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent
STATE_DIR = Path(os.environ.get("SS_STATE_DIR", str(Path.home() / ".ai-session-share")))
AUTH_USER = "ai"
SERVER_NAME = "ai-session-share"
SERVER_VERSION = "1.0.0"
PROTOCOL_VERSION = "2024-11-05"


def load_hub():
    """返回 (port, token);hub.state 优先,SS_HUB_URL/SS_HUB_TOKEN 兜底。"""
    cfg = {}
    try:
        for line in (STATE_DIR / "hub.state").read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                cfg[k] = v
    except OSError:
        pass
    port, token = cfg.get("port", ""), cfg.get("token", "")
    if not port or not token:
        hub_url = os.environ.get("SS_HUB_URL", "").rstrip("/")
        if not port and hub_url and ":" in hub_url:
            port = hub_url.rsplit(":", 1)[1]
        if not token:
            token = os.environ.get("SS_HUB_TOKEN", "")
    return port, token


def api(method, path, body=None):
    """调 hub HTTP API;成功返回 dict,失败抛 RuntimeError(带 hub 侧错误信息)。"""
    port, token = load_hub()
    if not port:
        raise RuntimeError("会话监控面板未运行:先执行 share hub start")
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=json.dumps(body).encode() if body is not None else None, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Share-API", "1")
    if token:
        req.add_header("Authorization", "Basic " + base64.b64encode(f"{AUTH_USER}:{token}".encode()).decode())
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try:
            err = json.load(e)
            raise RuntimeError(err.get("error", f"HTTP {e.code}"))
        except (ValueError, OSError):
            raise RuntimeError(f"HTTP {e.code}")
    except OSError as e:
        raise RuntimeError(f"面板连接失败: {e}")


def hub_base_url():
    ip = "127.0.0.1"
    port, _ = load_hub()
    return f"http://{ip}:{port}"


# ---------------------------------------------------------------- 工具实现
def t_list_sessions(args):
    s = api("GET", "/api/state")
    lines = []
    mg = s.get("managed", [])
    if mg:
        lines.append("托管会话(网页 /w/<id>,生命周期随进程):")
        for x in mg:
            state = "■ 已结束" if x["exited"] else "● 运行中"
            lines.append(f"  {x['id']}  {state}  客户端 {x['clients']}  {x['cmd']}")
    sh = s.get("shared", [])
    if sh:
        lines.append("共享终端服务(ttyd):")
        for x in sh:
            lines.append(f"  {x['session']}  端口 {x['port']}")
    cl = s.get("claude", [])
    if cl:
        live = [x for x in cl if x.get("live")]
        lines.append(f"Claude Code 会话: 共 {len(cl)} 个(活跃 {len(live)}),面板可查看实时视图")
    at = s.get("atomcode", [])
    if at:
        lines.append(f"atomcode 活动: {len(at)} 个项目")
    if not lines:
        lines.append("暂无活动会话")
    lines.append(f"\n面板: {hub_base_url()}/   (托管会话操作: spawn/send/read/kill)")
    return "\n".join(lines)


def t_session_status(args):
    sid = str(args.get("session_id", "")).strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]+", sid):
        raise RuntimeError("session_id 不合法")
    d = api("GET", f"/api/session/{sid}")
    out = {
        "id": d["id"], "cmd": d["cmd"], "pid": d["pid"],
        "state": "已结束" if d["exited"] else "运行中",
        "clients": d["clients"],
        "url": f"{hub_base_url()}/w/{d['id']}",
        "output_preview": (d.get("output_preview") or "")[-800:],
    }
    return json.dumps(out, ensure_ascii=False, indent=1)


def t_spawn_session(args):
    cmd = str(args.get("command", "")).strip()
    if not cmd or len(cmd) > 512:
        raise RuntimeError("command 不合法(1-512 字符)")
    cwd = str(args.get("cwd", "")).strip() or str(Path.home())
    d = api("POST", "/api/new", {"argv": shlex.split(cmd), "cwd": cwd})
    if not d.get("ok"):
        raise RuntimeError(d.get("error", "创建失败"))
    return (f"托管会话已创建: {d['id']}\n"
            f"网页终端: {hub_base_url()}/w/{d['id']}\n"
            f"本机连接: share attach {d['id']}\n"
            f"提示: 会话进程退出(如 /exit)后网页会话自动结束。")


def t_send_input(args):
    sid = str(args.get("session_id", "")).strip()
    text = str(args.get("text", ""))
    if not re.fullmatch(r"[A-Za-z0-9_-]+", sid):
        raise RuntimeError("session_id 不合法")
    if not (1 <= len(text) <= 4096):
        raise RuntimeError("text 长度须在 1-4096 字符")
    d = api("POST", f"/api/send/{sid}", {"text": text})
    if not d.get("ok"):
        raise RuntimeError(d.get("error", "发送失败"))
    return f"已发送到 {sid}(与网页/本机 attach 同一 PTY,生效即时)。"


def t_read_output(args):
    sid = str(args.get("session_id", "")).strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]+", sid):
        raise RuntimeError("session_id 不合法")
    try:
        tail = min(max(int(args.get("tail_bytes", 4096)), 64), 262144)
    except (TypeError, ValueError):
        tail = 4096
    d = api("GET", f"/api/output/{sid}?tail={tail}")
    if not d.get("ok"):
        raise RuntimeError(d.get("error", "读取失败"))
    return f"[{sid}] 最近 {d['len']} 字节输出:\n{d['text']}"


def t_kill_session(args):
    sid = str(args.get("session_id", "")).strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]+", sid):
        raise RuntimeError("session_id 不合法")
    d = api("POST", f"/api/kill/{sid}")
    if not d.get("ok"):
        raise RuntimeError(d.get("error", "结束失败"))
    return f"已请求结束托管会话 {sid}(网页端将同步显示已结束)。"


TOOLS = [
    {
        "name": "list_sessions",
        "description": "列出本机所有活动会话与状态:托管会话、共享终端服务、Claude Code 会话、atomcode 活动。",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "session_status",
        "description": "查看一个托管会话的详情:命令/PID/状态/连接数/网页链接/最近输出预览。",
        "inputSchema": {
            "type": "object",
            "properties": {"session_id": {"type": "string", "description": "托管会话 id(list_sessions 可见)"}},
            "required": ["session_id"],
        },
    },
    {
        "name": "spawn_session",
        "description": "新建托管会话(如 claude / bash),返回网页链接;进程退出后会话自动结束。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "完整命令行,如 'claude' 或 'bash -c \"长任务\"'"},
                "cwd": {"type": "string", "description": "工作目录(默认家目录)"},
            },
            "required": ["command"],
        },
    },
    {
        "name": "send_input",
        "description": "向托管会话发送键盘输入(操作会话)。与网页端/本机 attach 是同一个 PTY,输入即时生效。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "session_id": {"type": "string"},
                "text": {"type": "string", "description": "要输入的文本,可含换行;TUI 按 Enter 需用 \\r"},
            },
            "required": ["session_id", "text"],
        },
    },
    {
        "name": "read_output",
        "description": "读取托管会话最近输出(含 ANSI 转义,可指定字节数)。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "session_id": {"type": "string"},
                "tail_bytes": {"type": "integer", "description": "读取最近 N 字节(64-262144,默认 4096)"},
            },
            "required": ["session_id"],
        },
    },
    {
        "name": "kill_session",
        "description": "强制结束一个托管会话(SIGHUP/SIGTERM;网页端将同步显示已结束)。",
        "inputSchema": {
            "type": "object",
            "properties": {"session_id": {"type": "string"}},
            "required": ["session_id"],
        },
    },
]

TOOL_FUNCS = {
    "list_sessions": t_list_sessions,
    "session_status": t_session_status,
    "spawn_session": t_spawn_session,
    "send_input": t_send_input,
    "read_output": t_read_output,
    "kill_session": t_kill_session,
}


# ---------------------------------------------------------------- JSON-RPC 分发
def handle(msg):
    """处理一条 JSON-RPC 消息,返回响应 dict 或 None(通知无响应)。"""
    method = msg.get("method", "")
    msg_id = msg.get("id")
    params = msg.get("params") or {}

    if method == "initialize":
        return {
            "jsonrpc": "2.0", "id": msg_id,
            "result": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            },
        }
    if method == "notifications/initialized" or method.startswith("notifications/"):
        return None
    if method == "ping":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {"tools": TOOLS}}
    if method == "tools/call":
        name = params.get("name", "")
        fn = TOOL_FUNCS.get(name)
        if fn is None:
            return {"jsonrpc": "2.0", "id": msg_id,
                    "error": {"code": -32602, "message": f"未知工具: {name}"}}
        try:
            text = fn(params.get("arguments") or {})
            return {"jsonrpc": "2.0", "id": msg_id,
                    "result": {"content": [{"type": "text", "text": text}]}}
        except RuntimeError as e:
            # 工具级错误:isError=true 正常返回,客户端可见原因
            return {"jsonrpc": "2.0", "id": msg_id,
                    "result": {"content": [{"type": "text", "text": f"错误: {e}"}], "isError": True}}
        except Exception as e:  # noqa: BLE001 —— 兜底不让服务器崩
            return {"jsonrpc": "2.0", "id": msg_id,
                    "error": {"code": -32603, "message": f"内部错误: {e}"}}
    if msg_id is not None:
        return {"jsonrpc": "2.0", "id": msg_id,
                "error": {"code": -32601, "message": f"未知方法: {method}"}}
    return None


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            resp = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "解析错误"}}
        else:
            resp = handle(msg)
        if resp is not None:
            sys.stdout.write(json.dumps(resp, ensure_ascii=False) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
