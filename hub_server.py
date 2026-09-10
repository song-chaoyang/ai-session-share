#!/usr/bin/env python3
"""ai-session-share 会话监控面板 —— 本地常驻 Web 服务。

监控本机正在运行的 AI 会话与终端会话,并输出统一的网页入口:

  - 托管会话(自管 PTY;进程退出网页会话自动结束,双向操作)
  - Claude Code 会话列表(~/.claude/projects/**/**.jsonl,实时网页视图)
  - atomcode 会话活动(~/.atomcode/datalog/**,原始日志尾部视图)

设计原则:只用 Python 标准库,无任何第三方依赖;
Basic Auth 与 share.sh 同一套随机 token 机制(用户名 ai,密码每次启动重新生成);
终端组件(xterm.js)自托管于 /assets/,浏览器零外部 CDN 依赖。

路由:
  GET  /                       仪表盘(5s 自动刷新)
  GET  /api/state             仪表盘数据 JSON
  GET  /api/ticket            申请 WebSocket 一次性票据(替代无法带 Basic Auth 的 WS)
  GET  /api/session/<id>      托管会话详情(状态+输出预览)
  GET  /api/output/<id>?tail= 托管会话最近输出(程序化读取)
  GET  /assets/<xterm 文件>   终端组件(本地缓存自托管)
  POST /api/send/<id>         向托管会话发送键盘输入(程序化操作)
  GET  /w/<managed-id>        托管会话网页终端(xterm.js,双向)
  GET  /ws/<managed-id>?t=..  托管会话 WebSocket(PTY 直通)
  POST /api/new               新建托管会话 {argv:[...], cwd} 或 {cmd:"bash"}
  POST /api/kill/<managed-id> 强制结束托管会话
  GET  /t/<claude-session-id> Claude 会话实时视图(2s 轮询)
  GET  /t/<id>/data           Claude 会话消息 JSON
  GET  /t/a-<atomcode-slug>   atomcode 会话原始日志尾部(5s meta 刷新)

环境变量:
  SS_HUB_PORT    监听端口(默认 7690)
  SS_HUB_TOKEN   认证 token(share.sh 启动时生成传入;直接运行时自生成)
  SS_NO_AUTH     设 1 关闭认证(不推荐)
  SS_CLAUDE_DIR  Claude projects 目录(默认 ~/.claude/projects,测试用)
  SS_ATOM_DIR    atomcode 根目录(默认 ~/.atomcode,测试用)
  SS_STATE_DIR   状态目录(默认 ~/.ai-session-share)
"""
import base64
import fcntl
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

try:
    import pty
except ImportError:  # 仅 POSIX;Windows 原生不支持(WSL 下可用)
    pty = None

HOME = Path.home()
HUB_PORT = int(os.environ.get("SS_HUB_PORT", "7690"))
CLAUDE_DIR = Path(os.environ.get("SS_CLAUDE_DIR", str(HOME / ".claude" / "projects")))
ATOM_DIR = Path(os.environ.get("SS_ATOM_DIR", str(HOME / ".atomcode")))
STATE_DIR = Path(os.environ.get("SS_STATE_DIR", str(HOME / ".ai-session-share")))
SHARE_SH = Path(__file__).resolve().parent / "share.sh"
AUTH_USER = "ai"
NO_AUTH = os.environ.get("SS_NO_AUTH", "") == "1"
LIVE_SEC = 15 * 60          # 会话最后活动在 15 分钟内视为「活跃」
MAX_MSGS = 400              # 会话视图最多渲染的消息条数
MAX_PART = 4000              # 单条消息文本截断
TAIL_BYTES = 96 * 1024      # atomcode 原始日志尾部读取量
MAX_MANAGED = 32            # 托管会话数量上限(防 API 滥用)

TOKEN = os.environ.get("SS_HUB_TOKEN", "")


# ---------------------------------------------------------------- 工具函数
def sh(cmd, timeout=10):
    """执行外部命令,返回 stdout(失败返回空串)。"""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout if r.returncode == 0 else ""
    except (subprocess.TimeoutExpired, OSError):
        return ""


def lan_ip():
    """探测局域网 IP(与 share.sh lan_ips 同策略,取第一个)。"""
    if sys.platform == "darwin":
        for i in range(10):
            ip = sh(["ipconfig", "getifaddr", f"en{i}"], timeout=3).strip()
            if ip:
                return ip
    else:
        out = sh(["hostname", "-I"], timeout=3).strip()
        for ip in out.split():
            if re.match(r"^\d+\.\d+\.\d+\.\d+$", ip) and not ip.startswith(("127.", "169.254.")):
                return ip
    return "127.0.0.1"


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (ValueError, ProcessLookupError, PermissionError):
        return False


def claude_sessions():
    """Claude Code 会话列表:每个 projects/<slug>/<uuid>.jsonl 是一个会话。"""
    rows = []
    if not CLAUDE_DIR.is_dir():
        return rows
    for proj_dir in CLAUDE_DIR.iterdir():
        if not proj_dir.is_dir():
            continue
        for jf in proj_dir.glob("*.jsonl"):
            try:
                st = jf.stat()
            except OSError:
                continue
            age = time.time() - st.st_mtime
            rows.append({
                "id": jf.stem,
                "project": proj_dir.name,
                "cwd": _jsonl_last_cwd(jf),
                "size": st.st_size,
                "mtime": st.st_mtime,
                "live": age < LIVE_SEC,
                "url": f"/t/{jf.stem}",
            })
    rows.sort(key=lambda r: r["mtime"], reverse=True)
    return rows[:60]


def _jsonl_last_cwd(jf):
    """从 jsonl 尾部读几 KB 提取最后的 cwd(仅用于展示,失败返回空)。"""
    try:
        with open(jf, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 8192))
            tail = f.read().decode("utf-8", "replace")
        hits = re.findall(r'"cwd":"([^"]+)"', tail)
        return hits[-1] if hits else ""
    except OSError:
        return ""


def _slug_to_path(slug):
    """projects 目录名 slug → 真实路径('-Users-foo-bar' → '/Users/foo/bar' 等)。

    slug 里连字符既可能是路径分隔也可能属于目录名本身(如 ai-session-share),
    无歧义解析不可能;按位掩码枚举所有相邻段合并组合,返回第一个存在的目录,
    失败返回空串(调用方自行兜底)。段数上限 16,枚举量 2^15 可接受。
    """
    parts = slug.split("-")
    if not parts or parts[0]:
        return ""
    parts = parts[1:]
    n = len(parts)
    if n == 0 or n > 16:
        return ""
    # mask 的第 i 位(0-based,对应 parts[i] 与 parts[i+1] 之间)为 1 → 两段不分隔
    # 全 1(全部合并成一个目录名)往往不是目标;全 0(全拆开)是默认路径形态。
    # 优先级:先试"全拆开",再逐个引入合并 —— 真实项目目录两种都常见。
    for mask in range(0, 1 << (n - 1)):
        groups, cur = [], [parts[0]]
        for i in range(1, n):
            if mask & (1 << (i - 1)):
                cur.append(parts[i])
            else:
                groups.append(cur)
                cur = [parts[i]]
        groups.append(cur)
        cand = "/" + "/".join("-".join(g) for g in groups)
        if os.path.isdir(cand):
            return cand
    return ""


def atomcode_sessions():
    """atomcode 会话活动:~/.atomcode/datalog/<project>-<hash>/ 下按 mtime 判断活跃。"""
    rows = []
    dl = ATOM_DIR / "datalog"
    if not dl.is_dir():
        return rows
    for d in dl.iterdir():
        if not d.is_dir():
            continue
        try:
            files = [f for f in d.iterdir() if f.is_file() and f.suffix == ".jsonl"]
        except OSError:
            continue
        if not files:
            continue
        newest = max(files, key=lambda f: f.stat().st_mtime)
        try:
            mtime = newest.stat().st_mtime
        except OSError:
            continue
        rows.append({
            "slug": d.name,
            "project": d.name.rsplit("-", 1)[0],
            "mtime": mtime,
            "live": time.time() - mtime < LIVE_SEC,
            "size": sum(f.stat().st_size for f in files),
            "url": f"/t/a-{d.name}",
        })
    rows.sort(key=lambda r: r["mtime"], reverse=True)
    return rows[:40]


# ------------------------------------------------- Claude 会话 JSONL 解析
def parse_claude_jsonl(path):
    """把 Claude Code 会话 jsonl 解析为消息列表(用于网页实时视图)。"""
    msgs = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                typ = obj.get("type")
                if typ not in ("user", "assistant") or obj.get("isSidechain"):
                    continue
                content = obj.get("message", {}).get("content")
                parts = []
                if isinstance(content, str):
                    parts.append({"t": "text", "x": content[:MAX_PART]})
                elif isinstance(content, list):
                    for c in content:
                        if not isinstance(c, dict):
                            continue
                        ct = c.get("type")
                        if ct == "text":
                            parts.append({"t": "text", "x": str(c.get("text", ""))[:MAX_PART]})
                        elif ct == "thinking":
                            parts.append({"t": "think", "x": str(c.get("thinking", ""))[:600]})
                        elif ct == "tool_use":
                            args = json.dumps(c.get("input", {}), ensure_ascii=False)
                            parts.append({"t": "tool", "n": str(c.get("name", "tool")), "x": args[:800]})
                        elif ct == "tool_result":
                            rc = c.get("content", "")
                            txt = rc if isinstance(rc, str) else json.dumps(rc, ensure_ascii=False)
                            mark = "❌ " if c.get("is_error") else "↳ "
                            parts.append({"t": "result", "x": mark + txt[:1000]})
                if parts:
                    msgs.append({"role": typ, "ts": obj.get("timestamp", ""), "parts": parts})
    except OSError:
        pass
    return msgs[-MAX_MSGS:]


def find_claude_jsonl(session_id):
    """按 session id 在 claude projects 目录里定位 jsonl 文件。"""
    if not re.fullmatch(r"[A-Za-z0-9-]+", session_id or ""):
        return None
    if not CLAUDE_DIR.is_dir():
        return None
    for proj_dir in CLAUDE_DIR.iterdir():
        cand = proj_dir / f"{session_id}.jsonl"
        if cand.is_file():
            return cand
    return None


# ------------------------------------------------- WebSocket(标准库最小实现)
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
# TIOCSWINSZ:macOS 0x80087467 / Linux 0x5414
TIOCSWINSZ = 0x80087467 if sys.platform == "darwin" else 0x5414


class WSConn:
    """服务端 WebSocket 连接(仅实现本协议所需的最小子集)。

    协议(与 hub_attach / /w 页面 / tests/hub_ws_probe 一致):
      客户端 → 服务端: 文本帧 = 键盘输入;二进制帧 = 控制JSON(init/resize)
      服务端 → 客户端: 二进制帧 = 终端原始输出;文本帧 = 控制JSON(ended)
    """

    def __init__(self, sock, rfile):
        self.sock = sock
        self.rfile = rfile
        self.wlock = threading.Lock()
        self.closed = False

    def send(self, opcode, payload: bytes):
        if self.closed:
            return
        n = len(payload)
        header = bytearray([0x80 | opcode])
        if n < 126:
            header.append(n)
        elif n < 65536:
            header.append(126)
            header += struct.pack(">H", n)
        else:
            header.append(127)
            header += struct.pack(">Q", n)
        try:
            with self.wlock:
                self.sock.sendall(bytes(header) + payload)
        except OSError:
            self.closed = True

    def send_binary(self, data: bytes):
        self.send(0x2, data)

    def send_text(self, s: str):
        self.send(0x1, s.encode())

    def close(self):
        if not self.closed:
            self.send(0x8, b"")
        self.closed = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass

    def _read_exact(self, n):
        if n == 0:
            return b""
        data = self.rfile.read(n)
        if data is None or len(data) < n:
            return None
        return data

    def recv(self):
        """返回 (opcode, payload);连接关闭/出错返回 None。自动应答 ping。"""
        while True:
            hdr = self._read_exact(2)
            if hdr is None:
                return None
            b1, b2 = hdr[0], hdr[1]
            opcode = b1 & 0x0F
            masked = b2 & 0x80
            ln = b2 & 0x7F
            off = 2
            if ln == 126:
                ext = self._read_exact(2)
                if ext is None:
                    return None
                ln = struct.unpack(">H", ext)[0]
                off = 4
            elif ln == 127:
                ext = self._read_exact(8)
                if ext is None:
                    return None
                ln = struct.unpack(">Q", ext)[0]
                off = 10
            if ln > (1 << 20):
                return None
            mask = self._read_exact(4) if masked else b""
            data = self._read_exact(ln)
            if data is None:
                return None
            if mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if opcode == 0x8:      # close
                return None
            if opcode == 0x9:      # ping → pong
                self.send(0xA, data)
                continue
            if opcode == 0xA:       # pong
                continue
            return opcode, data


# ------------------------------------------------- 托管会话(自管 PTY)
class ManagedSession:
    """一个由本服务托管的 PTY 会话。

    生命周期与会话进程严格绑定:进程退出(如 Claude 里 /exit)→
    会话自动结束、网页端同步收到 ended、入口页变为"已结束",无需任何 stop。
    关闭本地终端/浏览器不会结束会话 —— 会话存活于 hub 进程中。
    """

    REPLAY_MAX = 256 * 1024     # 新连接可回放的最近输出量(浏览器/attach 晚到也能看到历史)

    def __init__(self, sid, argv, cwd=None):
        self.id = sid
        self.argv = list(argv)
        self.conns = set()
        self.lock = threading.Lock()
        self.started = time.time()
        self.exited = None       # 退出时间戳;None = 运行中
        self.buf = []            # 输出回放缓存(新连接可见此前输出)
        self.buf_bytes = 0
        env = dict(os.environ)
        env["SS_MANAGED_ID"] = sid   # hook 据此识别:AI 工具运行在托管会话里
        # 面板daemon 化后可能没有合适的 TERM(甚至没有),下游 CLI 会因此关闭彩色输出
        # 导致网页终端里全是单色文字;强制设成 xterm.js 认得的 256 色终端类型
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        # 宿主(启动 hub 的那个终端/工具)环境里若带 NO_COLOR / FORCE_COLOR=0(常见于
        # CI、自动化壳、部分终端外壳的"纯净输出"约定),会被子进程原样继承,导致下游
        # CLI(如遵循 no-color.org 规范的工具)彻底不发颜色码 —— TERM 设对了也没用,
        # 这两个变量优先级更高。网页终端(xterm.js)明确支持全彩,这里强制覆盖。
        env.pop("NO_COLOR", None)
        env["FORCE_COLOR"] = "1"
        pid, fd = pty.fork()
        if pid == 0:
            # 子进程:切到指定目录;关闭继承的其他 fd(hub 监听 socket、其他会话的
            # PTY master 等 —— 否则其他进程持有 master 会导致会话退出时收不到 EOF)
            try:
                if cwd:
                    os.chdir(cwd)
            except OSError:
                pass
            try:
                os.closerange(3, 1 << 16)
            except OSError:
                pass
            try:
                os.execvpe(self.argv[0], self.argv, env)
            except OSError:
                pass
            os._exit(127)
        self.pid = pid
        self.fd = fd
        self.set_winsize(80, 24)
        threading.Thread(target=self._reader, daemon=True).start()

    def info(self):
        return {
            "id": self.id,
            "cmd": " ".join(self.argv),
            "pid": self.pid,
            "started": self.started,
            "clients": len(self.conns),
            "exited": self.exited is not None,
        }

    def set_winsize(self, cols, rows):
        try:
            fcntl.ioctl(self.fd, TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        except OSError:
            pass

    def write(self, data: bytes):
        if self.exited is None:
            try:
                os.write(self.fd, data)
            except OSError:
                pass

    def add_conn(self, ws):
        with self.lock:
            self.conns.add(ws)
            replay = b"".join(self.buf)
        if replay:
            ws.send_binary(replay)   # 晚到的浏览器/attach 也能看到之前的输出

    def remove_conn(self, ws):
        with self.lock:
            self.conns.discard(ws)

    def tail(self, n=4096):
        """最近 n 字节的终端输出(含 ANSI 转义),供 HTTP/MCP 读取。"""
        with self.lock:
            data = b"".join(self.buf)
        return data[-n:]

    def terminate(self, grace=1.5):
        """可靠结束会话进程树:SIGTERM 进程组 → 宽限等待 → SIGKILL 进程组。

        必须按进程组杀(pty.fork 的子进程经 setsid 是组长):交互式 bash 会忽略
        SIGTERM,只杀主进程会留下孤儿;组杀可连带其派生的所有子进程。
        """
        if self.exited is not None:
            return
        for sig, wait in ((signal.SIGTERM, grace), (signal.SIGKILL, 1.0)):
            try:
                os.killpg(self.pid, sig)
            except OSError:
                try:
                    os.kill(self.pid, sig)
                except OSError:
                    return
            deadline = time.time() + wait
            while time.time() < deadline:
                if self.exited is not None:
                    return
                time.sleep(0.05)

    def _broadcast(self, data: bytes):
        with self.lock:
            self.buf.append(data)
            self.buf_bytes += len(data)
            while self.buf_bytes > self.REPLAY_MAX and len(self.buf) > 1:
                self.buf_bytes -= len(self.buf[0])
                self.buf.pop(0)
            conns = list(self.conns)
        for c in conns:
            c.send_binary(data)

    def _broadcast_control(self, obj):
        payload = json.dumps(obj, ensure_ascii=False)
        with self.lock:
            conns = list(self.conns)
        for c in conns:
            c.send_text(payload)

    def _reader(self):
        """PTY 读线程:输出广播给所有连接;EOF(进程退出)→ 会话自动结束。"""
        try:
            while True:
                try:
                    data = os.read(self.fd, 65536)
                except OSError:
                    break          # Linux: 子进程退出后 read 返回 EIO
                if not data:
                    break           # macOS: EOF
                self._broadcast(data)
        finally:
            self.exited = time.time()
            try:
                os.close(self.fd)
            except OSError:
                pass
            self._broadcast_control({"type": "ended"})
            with self.lock:
                conns = list(self.conns)
            for c in conns:
                c.close()


class ManagedSessions:
    """托管会话注册表;结束后保留 120s 供查看,再自动清理。"""

    RETAIN_ENDED_SEC = 120

    def __init__(self):
        self.sessions = {}
        self.lock = threading.Lock()

    def spawn(self, argv, cwd=None):
        if pty is None:
            raise RuntimeError("当前平台不支持 pty,无法创建托管会话")
        sid = "m" + secrets.token_hex(5)
        sess = ManagedSession(sid, argv, cwd)
        with self.lock:
            self.sessions[sid] = sess
        return sess

    def get(self, sid):
        self._gc()
        return self.sessions.get(sid)

    def _gc(self):
        now = time.time()
        with self.lock:
            dead = [k for k, s in self.sessions.items()
                    if s.exited is not None and now - s.exited > self.RETAIN_ENDED_SEC]
            for k in dead:
                del self.sessions[k]

    def list(self):
        self._gc()
        with self.lock:
            return [s.info() for s in self.sessions.values()]

    def running_count(self):
        return sum(1 for s in self.list() if not s["exited"])

    def kill_all(self):
        for s in self.list():
            if not s["exited"]:
                sess = self.sessions.get(s["id"])
                if sess:
                    sess.terminate(grace=0.5)


MANAGED = ManagedSessions()
TICKETS = {}   # 一次性 WS 票据:{token: 签发时间}



# ---------------------------------------------------------------- HTML 模板
CSS = """
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0d1117;color:#c9d1d9;font:14px/1.6 -apple-system,'PingFang SC','Microsoft YaHei',sans-serif;padding:24px}
h1{font-size:20px;margin-bottom:4px} .sub{color:#8b949e;font-size:12px;margin-bottom:20px}
.card{background:#161b22;border:1px solid #30363d;border-radius:8px;margin-bottom:20px;overflow:hidden}
.card h2{font-size:14px;padding:10px 16px;border-bottom:1px solid #30363d;background:#1c2129;color:#58a6ff}
table{width:100%;border-collapse:collapse;font-size:13px}
th{color:#8b949e;text-align:left;font-weight:normal;padding:6px 16px;border-bottom:1px solid #21262d}
td{padding:7px 16px;border-bottom:1px solid #21262d;white-space:nowrap}
tr:last-child td{border-bottom:none} tr:hover td{background:#1c2129}
.mono{font-family:ui-monospace,Menlo,monospace;font-size:12px;color:#79c0ff}
.dim{color:#8b949e} .ok{color:#3fb950} .off{color:#484f58}
a{color:#58a6ff;text-decoration:none} a:hover{text-decoration:underline}
button{background:#21262d;border:1px solid #30363d;color:#58a6ff;border-radius:6px;padding:3px 10px;cursor:pointer;font-size:12px}
button:disabled{opacity:.5;cursor:wait}
.empty{color:#484f58;padding:14px 16px}
#foot{color:#484f58;font-size:12px;text-align:center;margin-top:8px}
"""


def _esc(s):
    return html.escape(str(s), quote=True)


def page(title, body, refresh=None):
    meta = f'<meta http-equiv="refresh" content="{refresh}">' if refresh else ""
    return f"""<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">{meta}
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{_esc(title)} · ai-session-share</title><style>{CSS}</style></head>
<body>{body}<div id="foot">ai-session-share hub · 局域网会话监控</div></body></html>"""


def hub_page():
    body = """
<h1>🖥 会话监控面板</h1>
<div class="sub">本机正在运行的终端 / AI 会话 · 5s 自动刷新</div>
<div id="app">加载中…</div>
<script>
async function load(){
  try{
    const r = await fetch('/api/state');
    const s = await r.json();
    let h = '';
    if(s.managed && s.managed.length){
      h += `<div class="card"><h2>🎮 托管会话 — 进程退出(如 /exit)自动结束</h2><table>
        <tr><th>会话</th><th>命令</th><th>PID</th><th>客户端</th><th>状态</th><th></th></tr>` +
        s.managed.map(x=>`<tr><td class="mono">${x.id}</td><td class="mono">${_esc_js(x.cmd)}</td>
          <td class="dim">${x.pid}</td><td>${x.clients}</td>
          <td>${x.exited?'<span class="off">■ 已结束</span>':'<span class="ok">● 运行中</span>'}</td>
          <td>${x.exited?'':`<a href="/w/${x.id}" target="_blank">打开终端 ↗</a>
            <button onclick="killS('${x.id}',this)">结束</button>`}</td></tr>`).join('') +
        `</table></div>`;
    }
    if(s.presets && s.presets.length){
      h += `<div class="card"><h2>➕ 新建托管会话</h2><div style="padding:12px 16px">
        <select id="newcmd" style="background:#161b22;color:#c9d1d9;border:1px solid #30363d;
border-radius:6px;padding:5px 8px;font:13px ui-monospace,monospace">` +
        s.presets.map(c=>`<option>${c}</option>`).join('') + `</select>
        <button onclick="newS(this)">新建并打开</button>
        <span class="dim" style="font-size:12px">进程退出后会话自动结束;本机连接用 share attach &lt;id&gt;</span>
        </div></div>`;
    }
    if(s.claude.length){
      h += `<div class="card"><h2>🤖 Claude Code 会话(实时网页视图)</h2><table>
        <tr><th>项目</th><th>会话</th><th>大小</th><th>最近活动</th><th></th></tr>` +
        s.claude.map(x=>`<tr><td class="mono" style="max-width:280px;overflow:hidden;text-overflow:ellipsis" title="${(x.cwd||x.project).replace(/"/g,'&quot;')}">${_esc_js(x.cwd||x.project)}</td>
          <td class="mono">${x.id.slice(0,8)}…</td><td class="dim">${fmtSize(x.size)}</td>
          <td>${x.live?'<span class="ok">● 活跃</span>':'<span class="off">○ '+ago(x.mtime)+'</span>'}</td>
          <td><a href="${x.url}" target="_blank">查看会话 ↗</a></td></tr>`).join('') +
        `</table><div class="sub" style="padding:8px 16px">在托管会话里运行的 Claude 可双向操作;普通终端里的 Claude 为只读实时视图。</div></div>`;
    }
    if(s.atomcode.length){
      h += `<div class="card"><h2>⚛ atomcode 会话(原始日志)</h2><table>
        <tr><th>项目</th><th>日志量</th><th>最近活动</th><th></th></tr>` +
        s.atomcode.map(x=>`<tr><td class="mono">${x.project}</td><td class="dim">${fmtSize(x.size)}</td>
          <td>${x.live?'<span class="ok">● 活跃</span>':'<span class="off">○ '+ago(x.mtime)+'</span>'}</td>
          <td><a href="${x.url}" target="_blank">查看日志 ↗</a></td></tr>`).join('') +
        `</table></div>`;
    }
    if(!h) h = '<div class="card"><div class="empty">暂无检测到的会话</div></div>';
    document.getElementById('app').innerHTML = h;
  }catch(e){ document.getElementById('app').innerHTML = '<div class="card"><div class="empty">加载失败: '+e+'</div></div>'; }
}
async function newS(btn){
  btn.disabled = true; btn.textContent = '创建中…';
  try{
    const cmd = document.getElementById('newcmd').value;
    const r = await fetch('/api/new', {method:'POST', headers:{'X-Share-API':'1'},
      body: JSON.stringify({cmd: cmd})});
    const j = await r.json();
    if (j.ok){ window.open(j.url, '_blank'); setTimeout(load, 600); }
    else alert('创建失败: ' + (j.error||''));
  }catch(e){ alert('创建失败: '+e); }
  btn.disabled = false; btn.textContent = '新建并打开';
}
async function killS(id, btn){
  if (!confirm('结束该托管会话?')) return;
  btn.disabled = true;
  try{ await fetch('/api/kill/'+id, {method:'POST', headers:{'X-Share-API':'1'}}); }catch(e){}
  setTimeout(load, 500);
}
function fmtSize(n){ return n>1048576 ? (n/1048576).toFixed(1)+' MB' : n>1024 ? (n/1024).toFixed(0)+' KB' : n+' B'; }
function ago(ts){ const s=Math.floor(Date.now()/1000-ts); return s<3600?Math.floor(s/60)+' 分钟前':s<86400?Math.floor(s/3600)+' 小时前':Math.floor(s/86400)+' 天前'; }
function _esc_js(s){ const d=document.createElement('div'); d.textContent=s||''; return d.innerHTML; }
load(); setInterval(load, 5000);
</script>"""
    return page("会话监控", body)


# Claude 会话实时视图:左右聊天气泡样式(用户右、Claude 左,头像+时间戳,
# 工具调用/思考/结果折叠展示,轻量 Markdown 渲染,2s 轮询)。
# 注意:模板为普通字符串(非 f-string),JS 正则里的反斜杠必须写成 \\(见 _TERMINAL_TPL 注释)。
_TRANSCRIPT_TPL = """<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>__SID8__ · Claude 会话</title>
<style>__CSS__
body{padding:0}
header{position:sticky;top:0;z-index:9;background:#0d1117ee;backdrop-filter:blur(6px);
border-bottom:1px solid #30363d;padding:12px 20px;display:flex;justify-content:space-between;align-items:center;gap:12px}
header h1{font-size:15px;margin:0;display:flex;align-items:center;gap:8px;white-space:nowrap;overflow:hidden}
.dot{width:8px;height:8px;border-radius:50%;background:#484f58;flex:0 0 8px}
.dot.live{background:#3fb950;box-shadow:0 0 8px #3fb95088}
#meta{font-size:12px;color:#8b949e;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#log{max-width:860px;margin:0 auto;padding:24px 16px 96px;display:flex;flex-direction:column;gap:18px}
.row{display:flex;gap:10px;align-items:flex-start}
.row.user{flex-direction:row-reverse}
.av{flex:0 0 32px;width:32px;height:32px;border-radius:50%;display:flex;align-items:center;justify-content:center;
font-size:16px;background:#1c2129;border:1px solid #30363d}
.col{min-width:0;max-width:82%;display:flex;flex-direction:column;gap:4px}
.row.user .col{align-items:flex-end}
.who{font-size:11px;color:#8b949e;padding:0 6px}
.bubble{border-radius:14px;padding:10px 14px;line-height:1.7;word-break:break-word;white-space:pre-wrap}
.row.user .bubble{background:#1c2d4a;border:1px solid #2d4d78;border-top-right-radius:4px;color:#dbe7f7}
.row.asst .bubble{background:#161b22;border:1px solid #30363d;border-top-left-radius:4px}
.bubble .code{background:#0d1117;border:1px solid #21262d;border-radius:8px;padding:10px 12px;overflow:auto;
font:12px/1.5 ui-monospace,Menlo,monospace;margin:8px 0;white-space:pre}
code.ic{background:#0d1117;border:1px solid #21262d;border-radius:4px;padding:1px 6px;
font:12px ui-monospace,Menlo,monospace}
details{background:#10151c;border:1px solid #21262d;border-radius:10px;margin:6px 0 0;overflow:hidden;min-width:220px;max-width:100%}
summary{cursor:pointer;padding:7px 12px;font-size:12px;color:#8b949e;user-select:none;list-style:none;
white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
summary::before{content:'▸ '}
details[open] summary::before{content:'▾ '}
summary:hover{color:#c9d1d9;background:#161b22}
.dbody{padding:2px 12px 10px;font:11.5px/1.55 ui-monospace,Menlo,monospace;
white-space:pre-wrap;word-break:break-word;color:#9aa7b8;max-height:420px;overflow:auto}
.dbody.err{color:#f87272}
details.think summary{color:#8b7ec8}
#newbar{position:fixed;bottom:56px;left:50%;transform:translateX(-50%);background:#238636;color:#fff;
border-radius:16px;padding:6px 18px;font-size:12px;cursor:pointer;display:none;box-shadow:0 2px 10px #0009}
#cnt{position:fixed;bottom:0;left:0;right:0;background:#0d1117dd;backdrop-filter:blur(4px);
border-top:1px solid #21262d;padding:7px 16px;font-size:11px;color:#58a6ff;text-align:center}
</style></head><body>
<header>
  <h1><span class="dot" id="dot"></span>🤖 Claude 会话 <span class="mono dim" style="font-size:12px">__SID8__…</span></h1>
  <div style="display:flex;gap:10px;align-items:center">
    <button id="resume" title="以 claude --resume 从当前上下文继续,打开双向网页终端">🔄 在网页继续此会话</button>
    <div id="meta">加载中…</div>
  </div>
</header>
<div id="log"></div>
<div id="newbar">↓ 有新消息</div>
<div id="cnt">实时视图 · 2s 自动刷新 · 只读(要双向操作请点右上按钮)</div>
<script>
const SID = "__SID__";
const log = document.getElementById('log');
const bar = document.getElementById('newbar');
document.getElementById('resume').onclick = async ()=>{
  const b = document.getElementById('resume');
  b.disabled = true; b.textContent = '创建中…';
  try{
    // cwd 用原会话的项目目录(取自 /t/<id>/data 的 project 字段),保证 resume
    // 出的 Claude 落在目标运行路径而不是 $HOME
    const d = await (await fetch('/t/'+SID+'/data')).json();
    const r = await fetch('/api/new', {method:'POST', headers:{'Content-Type':'application/json','X-Share-API':'1'},
      body: JSON.stringify({argv:['claude','--resume', SID], cwd: d.project})});
    const j = await r.json();
    if (j.ok){ location.href = j.url; return; }
    alert('创建失败: ' + (j.error||''));
  }catch(e){ alert('创建失败: '+e); }
  b.disabled = false; b.textContent = '🔄 在网页继续此会话';
};
let stick = true, last = '';
window.addEventListener('scroll', ()=>{ stick = innerHeight+scrollY >= document.body.scrollHeight-90;
  if(stick) bar.style.display='none'; });
bar.onclick = ()=>{ stick=true; bar.style.display='none'; scrollTo(0, document.body.scrollHeight); };
function esc(s){ const d=document.createElement('div'); d.textContent = s==null ? '' : String(s); return d.innerHTML; }
function md(s){
  let e = String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  e = e.replace(/```[a-zA-Z0-9+#-]*\\n?([\\s\\S]*?)```/g, (m,c)=>'<div class="code">'+c+'</div>');
  e = e.replace(/`([^`\\n]+)`/g, '<code class="ic">$1</code>');
  e = e.replace(/\\*\\*([^*\\n]+)\\*\\*/g, '<b>$1</b>');
  e = e.replace(/\\[([^\\]]+)\\]\\((https?:\\/\\/[^)\\s]+)\\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
  e = e.replace(/\\n/g, '<br>');
  return e;
}
function part(p){
  if (p.t==='text') return '<div class="bubble">'+md(p.x)+'</div>';
  if (p.t==='think') return '<details class="think"><summary>💭 思考过程</summary><div class="dbody">'+esc(p.x)+'</div></details>';
  if (p.t==='tool') return '<details class="tool"><summary>🔧 '+(p.n?esc(p.n):'工具调用')+'</summary><div class="dbody">'+esc(p.x)+'</div></details>';
  if (p.t==='result') return '<details class="res"><summary>↳ '+(p.x && p.x.indexOf('❌')===0?'执行出错':'执行结果')+'</summary><div class="dbody'+(p.x && p.x.indexOf('❌')===0?' err':'')+'">'+esc(p.x)+'</div></details>';
  return '';
}
function render(m){
  const row=document.createElement('div');
  row.className = 'row ' + (m.role==='user' ? 'user' : 'asst');
  const av=document.createElement('div'); av.className='av'; av.textContent = m.role==='user' ? '👤' : '🤖';
  const col=document.createElement('div'); col.className='col';
  const who=document.createElement('div'); who.className='who';
  who.textContent = (m.role==='user' ? '我' : 'Claude') + (m.ts ? ' · '+m.ts.replace('T',' ').slice(5,16) : '');
  col.appendChild(who);
  let html='';
  for(const p of m.parts) html += part(p);
  col.insertAdjacentHTML('beforeend', html);
  row.appendChild(av); row.appendChild(col);
  return row;
}
async function tick(){
  try{
    const r = await fetch('/t/'+SID+'/data');
    const d = await r.json();
    const dot=document.getElementById('dot');
    dot.className = 'dot' + (d.live ? ' live' : '');
    document.getElementById('meta').textContent =
      (d.live ? '活跃中' : '空闲') + ' · ' + d.msgs.length + ' 条消息 · 2s 刷新';
    const j = JSON.stringify(d.msgs);
    if (j===last) return;
    last = j;
    log.innerHTML = '';
    for(const m of d.msgs) log.appendChild(render(m));
    if (stick) scrollTo(0, document.body.scrollHeight);
    else bar.style.display='block';
  }catch(e){}
}
tick(); setInterval(tick, 2000);
</script></body></html>"""


def transcript_page(session_id, path):
    return (_TRANSCRIPT_TPL
            .replace("__CSS__", CSS)
            .replace("__SID__", html.escape(session_id, quote=True))
            .replace("__SID8__", html.escape(session_id[:8], quote=True)))


def atom_page(slug, path):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            end = f.tell()
            f.seek(max(0, end - TAIL_BYTES))
            text = f.read().decode("utf-8", "replace")
    except OSError:
        text = "(无法读取日志)"
    body = f"""
<h1>⚛ atomcode 会话 <span class="mono">{_esc(slug)}</span></h1>
<div class="sub">原始日志尾部(最近 {TAIL_BYTES // 1024} KB) · 5s 自动刷新 · 只读</div>
<pre style="background:#161b22;border:1px solid #30363d;border-radius:8px;padding:12px;
margin-top:16px;font-size:12px;overflow:auto;white-space:pre-wrap;word-break:break-word">{_esc(text)}</pre>"""
    return page(f"atomcode {slug}", body, refresh=5)


# 托管会话终端页:xterm.js 由本服务 /assets/ 自托管(首次访问时自动下载缓存,
# 无外网 CDN 依赖,避免 Tracking Prevention / 内网隔离环境加载失败),加载失败降级为简易行输入。
# 注意:模板内 JS 出现的反斜杠必须写成 \\(Python 字面量),否则真实换行会破坏 JS 字符串字面量。
_TERMINAL_TPL = """<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>__SID__ · ai-session-share</title>
<link rel="stylesheet" href="/assets/xterm.css">
<script src="/assets/xterm.js"></script>
<script src="/assets/xterm-fit.js"></script>
<style>__CSS__</style></head>
<body style="overflow:hidden">
<div style="position:fixed;top:0;left:0;right:0;height:36px;background:#161b22;border-bottom:1px solid #30363d;
display:flex;justify-content:space-between;align-items:center;padding:0 14px;z-index:9">
  <div style="font:12px ui-monospace,Menlo,monospace;color:#79c0ff;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">__CMD__</div>
  <div style="font:12px -apple-system,sans-serif"><span id="status" style="color:#3fb950">● 连接中…</span>
  &nbsp;<a href="/" style="color:#58a6ff">面板</a></div>
</div>
<div id="term" style="position:fixed;top:36px;left:0;right:0;bottom:0"></div>
<div id="fallback" style="display:none;position:fixed;top:36px;left:0;right:0;bottom:0;overflow:auto;padding:8px">
  <div style="color:#d29922;font:12px sans-serif;padding:4px">终端组件未就绪,已降级为简易模式:仅支持整行回车发送。</div>
  <pre id="flog" style="white-space:pre-wrap;word-break:break-word;font:12px ui-monospace,Menlo,monospace;color:#c9d1d9"></pre>
  <input id="fin" style="position:fixed;bottom:0;left:0;width:100%;background:#161b22;border:none;
border-top:1px solid #30363d;color:#c9d1d9;padding:8px;font:12px ui-monospace,monospace" placeholder="输入后回车发送">
</div>
<script>
const SID = "__SID__";
function setStatus(t, c){ const e=document.getElementById('status'); e.textContent=t; e.style.color=c; }
let ws=null, term=null;
const enc = new TextEncoder(); const dec = new TextDecoder();
function fb(t){ document.getElementById('flog').textContent += t; document.getElementById('fallback').scrollTop = 1e9; }
async function boot(){
  if (window.Terminal){
    term = new Terminal({
      cursorBlink:true, fontSize:13, fontFamily:'ui-monospace,Menlo,Consolas,monospace',
      theme:{
        background:'#0d1117', foreground:'#c9d1d9', cursor:'#c9d1d9', cursorAccent:'#0d1117',
        selectionBackground:'rgba(88,166,255,.35)',
        black:'#484f58', red:'#ff7b72', green:'#3fb950', yellow:'#d29922',
        blue:'#58a6ff', magenta:'#bc8cff', cyan:'#39c5cf', white:'#b1bac4',
        brightBlack:'#6e7681', brightRed:'#ffa198', brightGreen:'#56d364', brightYellow:'#e3b341',
        brightBlue:'#79c0ff', brightMagenta:'#d2a8ff', brightCyan:'#56d4dd', brightWhite:'#f0f6fc'
      }
    });
    // 关键顺序:先 open(挂到 DOM)再 fit(量容器尺寸) —— 反了就只能用默认 80x24 的初始盒
    term.open(document.getElementById('term'));
    try {
      if (window.FitAddon){
        const fit = new FitAddon.FitAddon(); term.loadAddon(fit);
        fit.fit();
        window.addEventListener('resize', ()=>{ try{ fit.fit(); }catch(_){} });
        // 首帧渲染前容器可能还未定型(字体/布局异步),下一帧再 fit 一次兜底
        requestAnimationFrame(()=>{ try{ fit.fit(); }catch(_){} });
      }
    } catch(_){}
  } else {
    document.getElementById('fallback').style.display='block';
    document.getElementById('term').style.display='none';
    document.getElementById('fin').addEventListener('keydown', e=>{
      if (e.key==='Enter' && ws && ws.readyState===1){
        ws.send(document.getElementById('fin').value+'\\n'); document.getElementById('fin').value='';
      }
    });
  }
  let t=null;
  try { t = (await (await fetch('/api/ticket')).json()).t; } catch(e){}
  const url = (location.protocol==='https:'?'wss://':'ws://') + location.host + '/ws/' + SID + (t?('?t='+t):'');
  ws = new WebSocket(url);
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => {
    setStatus('● 运行中', '#3fb950');
    const cols = term ? term.cols : 80, rows = term ? term.rows : 24;
    ws.send(enc.encode(JSON.stringify({type:'init', cols:cols, rows:rows})));
  };
  ws.onmessage = e => {
    if (typeof e.data === 'string'){
      try { const c = JSON.parse(e.data);
        if (c.type==='ended'){ setStatus('■ 已结束(进程退出)', '#484f58'); document.title='已结束 · '+SID; }
      } catch(_){}
    } else {
      const u = new Uint8Array(e.data);
      if (term) term.write(dec.decode(u, {stream:true})); else fb(dec.decode(u, {stream:true}));
    }
  };
  ws.onclose = () => setStatus('■ 连接已关闭', '#484f58');
  ws.onerror = () => setStatus('■ 连接错误', '#f85149');
  if (term){
    term.onData(d => { if (ws && ws.readyState===1) ws.send(d); });
    term.onResize(({cols, rows}) => { if (ws && ws.readyState===1)
      ws.send(enc.encode(JSON.stringify({type:'resize', cols:cols, rows:rows}))); });
  }
}
boot();
</script></body></html>"""


def terminal_page(sid, sess):
    return (_TERMINAL_TPL
            .replace("__CSS__", CSS)
            .replace("__SID__", html.escape(sid, quote=True))
            .replace("__CMD__", html.escape(" ".join(sess.argv), quote=True)))


def ended_page(sid):
    body = f"""
<h1>■ 会话已结束</h1>
<div class="sub">托管会话 <span class="mono">{_esc(sid)}</span> 已结束 —— 进程退出(如会话内 /exit)后
网页会话自动停止,无需手动关闭。<br>返回 <a href="/">会话监控面板</a> 可查看或新建其他会话。</div>"""
    return page("会话已结束", body)


# ------------------------------------------------- 终端组件自托管(/assets/)
# xterm.js 由本服务从 /assets/ 提供:首次访问时下载并缓存到 STATE_DIR/assets/,
# 之后浏览器不再访问任何外部 CDN —— Tracking Prevention / 内网隔离都不影响。
XTERM_VERSION = "5.5.0"
FIT_VERSION = "0.10.0"
ASSETS = {
    # 文件名: (下载源, 合法性最小字节数, Content-Type)
    "xterm.js": (
        f"https://cdn.jsdelivr.net/npm/@xterm/xterm@{XTERM_VERSION}/lib/xterm.js",
        100_000, "application/javascript"),
    "xterm.css": (
        f"https://cdn.jsdelivr.net/npm/@xterm/xterm@{XTERM_VERSION}/css/xterm.min.css",
        200, "text/css"),
    "xterm-fit.js": (
        f"https://cdn.jsdelivr.net/npm/@xterm/addon-fit@{FIT_VERSION}/lib/addon-fit.js",
        500, "application/javascript"),
}
_ASSET_LOCK = threading.Lock()


def fetch_asset(name):
    """取终端组件:缓存命中直接返回;否则下载缓存(原子替换)。失败返回 None。"""
    url, min_size, _ = ASSETS[name]
    dest = STATE_DIR / "assets" / name
    try:
        if dest.is_file() and dest.stat().st_size >= min_size:
            return dest
    except OSError:
        pass
    with _ASSET_LOCK:
        try:
            if dest.is_file() and dest.stat().st_size >= min_size:
                return dest
        except OSError:
            pass
        tmp = dest.with_name(dest.name + ".tmp")
        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
            req = urllib.request.Request(url, headers={"User-Agent": "ai-session-share/1.0"})
            with urllib.request.urlopen(req, timeout=20) as r, open(tmp, "wb") as f:
                f.write(r.read())
            if tmp.stat().st_size >= min_size:
                tmp.replace(dest)
                return dest
        except OSError:
            pass
        try:
            tmp.unlink()
        except OSError:
            pass
    return None


# ---------------------------------------------------------------- HTTP 服务
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass  # 静默访问日志

    # -- 认证 --
    def authorized(self):
        if NO_AUTH or not TOKEN:
            return True
        if getattr(self, "_cookie_login", False):
            return True
        header = self.headers.get("Authorization", "")
        expected = "Basic " + base64.b64encode(f"{AUTH_USER}:{TOKEN}".encode()).decode()
        if hmac.compare_digest(header, expected):
            return True
        # Cookie 兜底:?key=token 免密登录链接种下的 cookie,后续请求(含刷新/WS)自动带上
        for part in self.headers.get("Cookie", "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == "ss_auth" and v and hmac.compare_digest(v, TOKEN):
                return True
        return False

    def deny(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="ai-session-share"')
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        body = "401 Unauthorized"
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body.encode())

    # -- 响应 --
    def reply(self, code, body, ctype="text/html; charset=utf-8"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        if getattr(self, "_cookie_login", False) and TOKEN:
            # ?key=token 免密登录成功:种 30 天 cookie,之后打开链接/刷新都不用再输密码
            self.send_header("Set-Cookie", f"ss_auth={TOKEN}; Path=/; Max-Age=2592000; SameSite=Lax")
        self.end_headers()
        self.wfile.write(data)

    def reply_json(self, obj, code=200):
        self.reply(code, json.dumps(obj, ensure_ascii=False), "application/json; charset=utf-8")

    # -- GET --
    def do_GET(self):
        raw = self.path
        path = raw.split("?", 1)[0].rstrip("/") or "/"
        qs = urllib.parse.parse_qs(raw.split("?", 1)[1]) if "?" in raw else {}

        # ?key=token 免密登录:与 Basic Auth 等价的另一种认证方式(不是内嵌凭据 URL,
        # 只是普通查询参数,不会被浏览器拦截),验证通过后 reply() 会顺手种 cookie,
        # 之后同源的刷新/跳转/WS 连接都自动带凭据,不用再输账号密码。
        key = qs.get("key", [""])[0]
        self._cookie_login = bool(key) and not NO_AUTH and bool(TOKEN) and hmac.compare_digest(key, TOKEN)

        # /ws/<id>?t=…:WebSocket 升级(浏览器 WS 无法携带 Basic Auth,用一次性票据)
        m = re.fullmatch(r"/ws/([A-Za-z0-9_-]+)", path)
        if m:
            return self.handle_ws(m.group(1), raw)

        if not self.authorized():
            return self.deny()

        if path in ("/", "/index.html"):
            return self.reply(200, hub_page())

        if path == "/api/state":
            return self.reply_json({
                "hub": {"port": HUB_PORT},
                "claude": claude_sessions(),
                "atomcode": atomcode_sessions(),
                "managed": MANAGED.list(),
                "presets": [c for c in ("bash", "zsh", "claude", "atomcode", "codex")
                            if shutil.which(c)],
            })

        # 终端组件自托管(本地缓存,无 CDN 依赖)
        m = re.fullmatch(r"/assets/(xterm(?:-fit)?\.(?:js|css))", path)
        if m:
            dest = fetch_asset(m.group(1))
            if not dest:
                return self.reply(404, "404 终端组件未缓存且下载失败(可稍后重试或检查网络)",
                                 "text/plain; charset=utf-8")
            try:
                data = dest.read_bytes()
            except OSError:
                return self.reply(404, "404", "text/plain; charset=utf-8")
            ctype = ASSETS[m.group(1)][2]
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "public, max-age=86400")
            self.end_headers()
            self.wfile.write(data)
            return

        if path == "/api/ticket":
            now = time.time()
            for k in [k for k, v in TICKETS.items() if now - v > 60]:
                del TICKETS[k]
            t = secrets.token_hex(16)
            TICKETS[t] = now
            return self.reply_json({"t": t})

        # 单个托管会话状态(含最近输出预览)
        m = re.fullmatch(r"/api/session/([A-Za-z0-9_-]+)", path)
        if m:
            sess = MANAGED.get(m.group(1))
            if not sess:
                return self.reply_json({"ok": False, "error": "会话不存在或已清理"}, 404)
            info = sess.info()
            info["ok"] = True
            preview = sess.tail(2048).decode("utf-8", "replace")
            info["output_preview"] = preview
            info["output_b64"] = base64.b64encode(sess.tail(65536)).decode()
            return self.reply_json(info)

        # 托管会话最近输出(?tail=字节数,默认 4096)
        m = re.fullmatch(r"/api/output/([A-Za-z0-9_-]+)", path)
        if m:
            sess = MANAGED.get(m.group(1))
            if not sess:
                return self.reply_json({"ok": False, "error": "会话不存在或已清理"}, 404)
            qs = urllib.parse.parse_qs(raw.split("?", 1)[1]) if "?" in raw else {}
            try:
                n = min(max(int(qs.get("tail", ["4096"])[0]), 1), 262144)
            except (TypeError, ValueError):
                n = 4096
            data = sess.tail(n)
            return self.reply_json({
                "ok": True,
                "id": sess.id,
                "exited": sess.exited is not None,
                "len": len(data),
                "text": data.decode("utf-8", "replace"),
            })

        # /w/<id>:托管会话网页终端
        m = re.fullmatch(r"/w/([A-Za-z0-9_-]+)", path)
        if m:
            sess = MANAGED.get(m.group(1))
            if not sess or sess.exited is not None:
                return self.reply(200, ended_page(m.group(1)))
            return self.reply(200, terminal_page(sess.id, sess))

        # /t/<id>[/data]
        m = re.fullmatch(r"/t/([A-Za-z0-9-]+)(/data)?", path)
        if m:
            sid, is_data = m.group(1), m.group(2) is not None
            if sid.startswith("a-"):  # atomcode:a-<datalog目录名>
                slug = sid[2:]
                dl = ATOM_DIR / "datalog" / slug
                if not re.fullmatch(r"[A-Za-z0-9_.-]+", slug) or not dl.is_dir():
                    return self.reply(404, "404 未找到该 atomcode 会话", "text/plain; charset=utf-8")
                try:
                    newest = max((f for f in dl.iterdir() if f.suffix == ".jsonl"),
                                 key=lambda f: f.stat().st_mtime)
                except (OSError, ValueError):
                    return self.reply(404, "404 该会话没有日志文件", "text/plain; charset=utf-8")
                return self.reply(200, atom_page(slug, newest))
            jf = find_claude_jsonl(sid)
            if not jf:
                # 新会话的 jsonl 在 hook 返回后才落盘:404 页自动重试几秒,避免"链接是死的"错觉
                body = ("<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">"
                        "<meta http-equiv=\"refresh\" content=\"2\">"
                        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
                        "<title>会话加载中</title><body style=\"background:#0d1117;color:#c9d1d9;"
                        "font:14px/1.8 -apple-system,'PingFang SC',sans-serif;padding:24px\">"
                        "⏳ 会话文件尚未生成(新会话最初几秒)或会话不存在,2 秒后自动重试…"
                        "<br><a style=\"color:#58a6ff\" href=\"/\">← 返回监控面板</a></body></html>")
                return self.reply(404, body)
            if is_data:
                st = jf.stat()
                return self.reply_json({
                    "live": time.time() - st.st_mtime < LIVE_SEC,
                    "project": _jsonl_last_cwd(jf) or _slug_to_path(jf.parent.name),
                    "mtime": st.st_mtime,
                    "msgs": parse_claude_jsonl(jf),
                })
            return self.reply(200, transcript_page(sid, jf))

        return self.reply(404, "404 Not Found", "text/plain; charset=utf-8")

    # -- WebSocket:/ws/<id> --
    def handle_ws(self, sid, raw):
        if pty is None:
            return self.reply(501, "501 当前平台不支持 pty,无托管会话功能", "text/plain; charset=utf-8")
        # 认证:一次性票据(浏览器)或 Basic Auth(attach 本机客户端)
        ok = False
        qs = urllib.parse.parse_qs(raw.split("?", 1)[1]) if "?" in raw else {}
        t = qs.get("t", [""])[0]
        if t and t in TICKETS and time.time() - TICKETS.pop(t, 0) < 60:
            ok = True
        elif self.authorized():
            ok = True
        if not ok:
            return self.deny()
        sess = MANAGED.get(sid)
        if not sess:
            return self.reply(404, "404 会话不存在或已结束", "text/plain; charset=utf-8")
        if sess.exited is not None:
            return self.reply(410, "410 会话已结束(进程退出后会话自动停止)", "text/plain; charset=utf-8")
        key = self.headers.get("Sec-WebSocket-Key", "")
        if not key:
            return self.reply(400, "400 缺少 Sec-WebSocket-Key", "text/plain; charset=utf-8")
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.close_connection = True

        ws = WSConn(self.connection, self.rfile)
        sess.add_conn(ws)
        try:
            while True:
                fr = ws.recv()
                if fr is None:
                    break
                op, data = fr
                if op == 0x1:            # 文本帧 = 键盘输入 → 直通 PTY(UTF-8 透传)
                    sess.write(data)
                elif op == 0x2:          # 二进制帧 = 控制 JSON(init/resize)
                    try:
                        ctl = json.loads(data.decode("utf-8", "replace"))
                    except (ValueError, UnicodeDecodeError):
                        continue
                    if ctl.get("type") in ("init", "resize"):
                        try:
                            sess.set_winsize(int(ctl.get("cols", 80)), int(ctl.get("rows", 24)))
                        except (TypeError, ValueError):
                            pass
        finally:
            sess.remove_conn(ws)

    # -- POST:/api/new | /api/send | /api/kill --
    def do_POST(self):
        # 防 CSRF:跨站请求无法携带自定义头
        if self.headers.get("X-Share-API") != "1":
            return self.reply_json({"ok": False, "error": "缺少 X-Share-API 头(防跨站请求)"}, 403)
        if not self.authorized():
            return self.deny()
        path = self.path.split("?", 1)[0].rstrip("/")

        if path == "/api/new":
            try:
                raw = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode("utf-8", "replace")
                body = json.loads(raw or "{}")
            except (ValueError, UnicodeDecodeError):
                return self.reply_json({"ok": False, "error": "请求体不是合法 JSON"}, 400)
            argv = body.get("argv")
            if not argv and isinstance(body.get("cmd"), str) and body["cmd"].strip():
                argv = [body["cmd"].strip()]
            if (not isinstance(argv, list) or not (1 <= len(argv) <= 32)
                    or not all(isinstance(a, str) and a and len(a) <= 256 for a in argv)):
                return self.reply_json({"ok": False, "error": "argv 不合法"}, 400)
            if shutil.which(argv[0]) is None:
                return self.reply_json({"ok": False, "error": f"命令不存在: {argv[0]}"}, 400)
            if MANAGED.running_count() >= MAX_MANAGED:
                return self.reply_json({"ok": False, "error": f"托管会话已达上限({MAX_MANAGED})"}, 429)
            cwd = body.get("cwd")
            if not isinstance(cwd, str) or not os.path.isdir(cwd):
                # claude --resume 未指定 cwd 时:从会话 jsonl 解析原项目目录,
                # 避免 resume 出来落在 $HOME 读不到项目上下文
                if argv[:2] == ["claude", "--resume"] and len(argv) >= 3 \
                        and re.fullmatch(r"[A-Za-z0-9-]+", argv[2]):
                    jf = find_claude_jsonl(argv[2])
                    if jf:
                        last = _jsonl_last_cwd(jf)
                        if last and os.path.isdir(last):
                            cwd = last
                if not isinstance(cwd, str) or not os.path.isdir(cwd):
                    cwd = str(HOME)
            try:
                sess = MANAGED.spawn(argv, cwd)
            except (RuntimeError, OSError) as e:
                return self.reply_json({"ok": False, "error": str(e)}, 500)
            return self.reply_json({"ok": True, "id": sess.id, "url": f"/w/{sess.id}"})

        m = re.fullmatch(r"/api/kill/([A-Za-z0-9_-]+)", path)
        if m:
            sess = MANAGED.get(m.group(1))
            if not sess or sess.exited is not None:
                return self.reply_json({"ok": False, "error": "会话不存在或已结束"}, 404)
            sess.terminate()   # 进程组 TERM→KILL 升级,交互式 bash 也能杀干净
            return self.reply_json({"ok": True, "exited": sess.exited is not None})

        # 向托管会话发送键盘输入(MCP/程序化操作入口;与网页输入同一条 PTY 通路)
        m = re.fullmatch(r"/api/send/([A-Za-z0-9_-]+)", path)
        if m:
            sess = MANAGED.get(m.group(1))
            if not sess or sess.exited is not None:
                return self.reply_json({"ok": False, "error": "会话不存在或已结束"}, 404)
            try:
                raw_body = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode("utf-8", "replace")
                body = json.loads(raw_body or "{}")
            except (ValueError, UnicodeDecodeError):
                return self.reply_json({"ok": False, "error": "请求体不是合法 JSON"}, 400)
            text = body.get("text")
            if not isinstance(text, str) or not (1 <= len(text) <= 4096):
                return self.reply_json({"ok": False, "error": "text 不合法(1-4096 字符)"}, 400)
            sess.write(text.encode())
            return self.reply_json({"ok": True, "id": sess.id})

        return self.reply_json({"ok": False, "error": "路径不合法"}, 404)


def _api_call(port, token, method, path, body=None):
    """api_cli 共用的 HTTP 调用:返回 dict 或(失败时)错误文本。"""
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}",
                                 data=body.encode() if body is not None else None, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Share-API", "1")
    if token:
        req.add_header("Authorization", "Basic " + base64.b64encode(f"{AUTH_USER}:{token}".encode()).decode())
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return f"HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:300]}"
    except OSError as e:
        return f"请求失败: {e}"


def api_cli():
    """命令行 API 客户端(share.sh 调用):读 hub.state 或 SS_HUB_URL,带 Basic Auth 与防 CSRF 头。

    用法:
      hub_server.py api new <cwd> <argv...>   新建托管会话,输出 JSON
      hub_server.py api kill <id>             结束托管会话,输出 JSON
      hub_server.py api send <id> <text>      向托管会话发送输入,输出 JSON
      hub_server.py api output <id> [tail]    读托管会话最近输出,输出 JSON
      hub_server.py api session <id>          托管会话详情,输出 JSON
      hub_server.py api state                 面板状态,输出 JSON
      hub_server.py api sessions              活动会话一览(文本,share.sh sessions 用)
    """
    args = sys.argv[2:]
    if len(args) < 1:
        print("用法: hub_server.py api new <cwd> <argv...> | api kill <id> | api state", file=sys.stderr)
        return 2
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
        # 兜底:SS_HUB_URL / SS_HUB_TOKEN 环境变量(免状态文件的全局发现)
        hub_url = os.environ.get("SS_HUB_URL", "").rstrip("/")
        if not port and hub_url and ":" in hub_url:
            port = hub_url.rsplit(":", 1)[1]
        if not token:
            token = os.environ.get("SS_HUB_TOKEN", "")
    if not port:
        print(f"读取 {STATE_DIR / 'hub.state'} 失败(面板未启动?先 share hub start)", file=sys.stderr)
        return 1

    if args[0] == "new":
        if len(args) < 3:
            print("用法: api new <cwd> <argv...>", file=sys.stderr)
            return 2
        method, path, body = "POST", "/api/new", json.dumps({"argv": args[2:], "cwd": args[1]})
    elif args[0] == "kill":
        if len(args) != 2:
            print("用法: api kill <id>", file=sys.stderr)
            return 2
        method, path, body = "POST", "/api/kill/" + args[1], None
    elif args[0] == "send":
        if len(args) != 3:
            print("用法: api send <id> <text>", file=sys.stderr)
            return 2
        method, path, body = "POST", "/api/send/" + args[1], json.dumps({"text": args[2]})
    elif args[0] == "output":
        if len(args) < 2:
            print("用法: api output <id> [tail字节]", file=sys.stderr)
            return 2
        tail = args[2] if len(args) > 2 else "4096"
        method, path, body = "GET", f"/api/output/{args[1]}?tail={tail}", None
    elif args[0] == "session":
        if len(args) != 2:
            print("用法: api session <id>", file=sys.stderr)
            return 2
        method, path, body = "GET", "/api/session/" + args[1], None
    elif args[0] == "state":
        method, path, body = "GET", "/api/state", None
    elif args[0] == "sessions":
        # 全局活动会话一览(文本表格,share.sh sessions 调用)
        d = _api_call(port, token, "GET", "/api/state")
        if not isinstance(d, dict):
            print(d, file=sys.stderr)
            return 1
        base = f"http://127.0.0.1:{port}"
        print("═══ ai-session-share 活动会话 ═══")
        mg = [x for x in d.get("managed", []) if not x.get("exited")]
        ended = [x for x in d.get("managed", []) if x.get("exited")]
        if mg:
            print("托管会话(进程退出自动结束):")
            for x in mg:
                print(f"  {x['id']}  ● 运行中  客户端 {x['clients']}  {x['cmd']}")
                print(f"    网页: {base}/w/{x['id']}   本机: share attach {x['id']}   结束: share kill {x['id']}")
        if ended:
            print(f"托管会话(已结束,面板仍可查看): {len(ended)} 个")
        if not mg and not ended:
            print("托管会话: 无(可 share new claude 创建)")
        cl = d.get("claude", [])
        if cl:
            live = [x for x in cl if x.get("live")]
            print(f"Claude Code 会话: {len(cl)} 个(活跃 {len(live)}),实时视图: {base}/t/<会话id>")
        at = d.get("atomcode", [])
        if at:
            print(f"atomcode 活动: {len(at)} 个项目")
        print()
        print(f"面板: {base}/    全局环境变量: SS_HUB_URL=http://127.0.0.1:{port}")
        return 0
    else:
        print("未知 api 子命令: " + args[0], file=sys.stderr)
        return 2

    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}",
                                 data=body.encode() if body is not None else None, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Share-API", "1")
    if token:
        req.add_header("Authorization", "Basic " + base64.b64encode(f"{AUTH_USER}:{token}".encode()).decode())
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            print(r.read().decode())
    except urllib.error.HTTPError as e:
        print(e.read().decode(), file=sys.stderr)
        return 1
    except OSError as e:
        print(f"请求失败: {e}", file=sys.stderr)
        return 1
    return 0


def _daemonize():
    """双 fork + setsid 脱离调用者的会话/进程组:
    终端关闭、父进程组被清理都不会波及面板(与常驻服务同理)。
    stdio 重定向: stdin=/dev/null, stdout/stderr=hub.log(追加)。"""
    log_path = STATE_DIR / "hub.log"
    try:
        pid = os.fork()
        if pid > 0:
            os._exit(0)              # 第一父进程立即退出,启动方轮询 hub.pid 即可
        os.setsid()                  # 脱离原会话,成为新会话首进程
        pid2 = os.fork()
        if pid2 > 0:
            os._exit(0)              # 会话首进程退出,最终进程不再持有控制终端
    except OSError:
        return                       # fork 失败则退化为前台运行
    sys.stdout.flush()
    sys.stderr.flush()
    try:
        os.close(0)
        os.open(os.devnull, os.O_RDONLY)     # fd0 = /dev/null
        fd = os.open(str(log_path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        os.dup2(fd, 1)
        os.dup2(fd, 2)
        if fd > 2:
            os.close(fd)
    except OSError:
        pass


def main():
    global TOKEN
    if len(sys.argv) > 1 and sys.argv[1] == "api":
        return api_cli()

    if pty is None:
        print("[hub] 警告: 当前平台无 pty,托管会话功能不可用(仅监控)", file=sys.stderr)
    if not TOKEN and not NO_AUTH:
        TOKEN = secrets.token_hex(16)

    if os.environ.get("SS_HUB_DAEMON") == "1":
        _daemonize()                 # 先守护化(脱离进程组),再绑定端口/写状态

    # 预热终端组件(后台尽力而为):首次访问 /w/ 页面时资源多半已就绪
    threading.Thread(target=lambda: [fetch_asset(n) for n in ASSETS], daemon=True).start()

    srv = ThreadingHTTPServer(("0.0.0.0", HUB_PORT), Handler)

    # 状态文件由最终进程自己写(pid 才是真实的守护进程 pid);绑定成功后才写
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        os.chmod(STATE_DIR, 0o700)   # token 等敏感状态仅本用户可读(与 README 安全章节一致)
        (STATE_DIR / "hub.state").write_text(
            f"port={HUB_PORT}\ntoken={TOKEN}\npid={os.getpid()}\n"
            f"started={time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        (STATE_DIR / "hub.pid").write_text(f"{os.getpid()}\n")
    except OSError:
        pass

    signal.signal(signal.SIGCHLD, signal.SIG_IGN)   # 托管会话子进程自动回收,不产生僵尸

    def _shutdown(_sig, _frm):
        # 面板退出 = 托管会话宿主消失:一并结束所有托管会话
        MANAGED.kill_all()
        sys.exit(0)

    signal.signal(signal.SIGTERM, _shutdown)

    print(f"[hub] 会话监控面板已启动: http://0.0.0.0:{HUB_PORT} pid={os.getpid()} "
          f"(认证已{'关闭' if NO_AUTH else '开启'})", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        MANAGED.kill_all()
    return 0


if __name__ == "__main__":
    sys.exit(main())
