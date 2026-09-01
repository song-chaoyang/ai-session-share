#!/usr/bin/env python3
"""ai-session-share 会话监控面板 —— 本地常驻 Web 服务。

监控本机正在运行的 AI 会话与终端会话,并输出统一的网页入口:

  - tmux 会话列表(可从网页一键起 ttyd 共享,双向操作)
  - Claude Code 会话列表(~/.claude/projects/**/**.jsonl,实时网页视图)
  - atomcode 会话活动(~/.atomcode/datalog/**,原始日志尾部视图)
  - 已在共享中的 ttyd 服务清单(端口/链接)

设计原则:只用 Python 标准库,无任何第三方依赖;
Basic Auth 与 share.sh 同一套随机 token 机制(用户名 ai,密码每次启动重新生成)。

路由:
  GET  /                       仪表盘(5s 自动刷新)
  GET  /api/state             仪表盘数据 JSON
  GET  /t/<claude-session-id> Claude 会话实时视图(2s 轮询)
  GET  /t/<id>/data           Claude 会话消息 JSON
  GET  /t/a-<atomcode-slug>   atomcode 会话原始日志尾部(5s meta 刷新)
  POST /api/share/<tmux名>     对指定 tmux 会话启动 ttyd 共享(调用 share.sh serve)

环境变量:
  SS_HUB_PORT    监听端口(默认 7690)
  SS_HUB_TOKEN   认证 token(share.sh 启动时生成传入;直接运行时自生成)
  SS_NO_AUTH     设 1 关闭认证(不推荐)
  SS_CLAUDE_DIR  Claude projects 目录(默认 ~/.claude/projects,测试用)
  SS_ATOM_DIR    atomcode 根目录(默认 ~/.atomcode,测试用)
  SS_STATE_DIR   状态目录(默认 ~/.ai-session-share)
"""
import base64
import hmac
import html
import json
import os
import re
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

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

TOKEN = os.environ.get("SS_HUB_TOKEN", "")
if not TOKEN and not NO_AUTH:
    import secrets
    TOKEN = secrets.token_hex(16)
    # 直接运行时自写状态文件,保证 share.sh hub url / hook 能读到同一份 token
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        (STATE_DIR / "hub.state").write_text(
            f"port={HUB_PORT}\ntoken={TOKEN}\nstarted={time.strftime('%Y-%m-%d %H:%M:%S')}\n"
        )
    except OSError:
        pass


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


def read_state_files():
    """读取 ~/.ai-session-share/*.state → 正在共享的 ttyd 服务清单。"""
    out = []
    if not STATE_DIR.is_dir():
        return out
    for f in sorted(STATE_DIR.glob("*.state")):
        if f.name == "hub.state":
            continue
        cfg = {}
        try:
            for line in f.read_text().splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    cfg[k] = v
        except OSError:
            continue
        pid, port = cfg.get("pid", ""), cfg.get("port", "")
        if pid and pid_alive(pid) and port:
            out.append({
                "session": cfg.get("session", f.stem),
                "port": port,
                "url": f"/open/{port}",
            })
    return out


def tmux_sessions():
    """tmux 会话列表(name/created/windows/attached)。"""
    out = sh(["tmux", "list-sessions", "-F",
              "#{session_name}\t#{session_created}\t#{session_windows}\t#{session_attached}"])
    shared = {s["session"]: s["port"] for s in read_state_files()}
    rows = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 4:
            continue
        name, created, windows, attached = parts
        rows.append({
            "name": name,
            "created": time.strftime("%m-%d %H:%M", time.localtime(int(created))),
            "windows": windows,
            "attached": attached == "1",
            "shared": name in shared,
            "port": shared.get(name, ""),
        })
    return rows


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
                            parts.append({"t": "tool", "x": "💭 " + str(c.get("thinking", ""))[:400]})
                        elif ct == "tool_use":
                            args = json.dumps(c.get("input", {}), ensure_ascii=False)
                            parts.append({"t": "tool", "x": f"🔧 {c.get('name', 'tool')}  {args[:500]}"})
                        elif ct == "tool_result":
                            rc = c.get("content", "")
                            txt = rc if isinstance(rc, str) else json.dumps(rc, ensure_ascii=False)
                            mark = "❌ " if c.get("is_error") else "↳ "
                            parts.append({"t": "result", "x": mark + txt[:800]})
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
    const sharedRow = x => `<tr><td class="mono">${x.session}</td><td class="mono">${x.port}</td>
      <td><a href="${x.url}" target="_blank">打开终端 ↗</a></td></tr>`;
    if(s.shared.length)
      h += `<div class="card"><h2>📡 共享中的终端服务</h2><table>
        <tr><th>tmux 会话</th><th>端口</th><th>链接</th></tr>${s.shared.map(sharedRow).join('')}</table></div>`;
    if(s.tmux.length){
      h += `<div class="card"><h2>⌨ tmux 会话(可共享为双向终端)</h2><table>
        <tr><th>会话</th><th>创建于</th><th>窗口</th><th>本机连接</th><th>状态</th><th></th></tr>` +
        s.tmux.map(x=>`<tr><td class="mono">${x.name}</td><td class="dim">${x.created}</td>
          <td>${x.windows}</td><td>${x.attached?'已连接':'后台'}</td>
          <td>${x.shared?`<span class="ok">共享中 :${x.port}</span>`:'<span class="off">未共享</span>'}</td>
          <td>${x.shared?`<a href="/open/${x.port}" target="_blank">打开 ↗</a>`
            :`<button onclick="share('${x.name}',this)">共享此会话</button>`}</td></tr>`).join('') +
        `</table></div>`;
    }
    if(s.claude.length){
      h += `<div class="card"><h2>🤖 Claude Code 会话(实时网页视图)</h2><table>
        <tr><th>项目</th><th>会话</th><th>大小</th><th>最近活动</th><th></th></tr>` +
        s.claude.map(x=>`<tr><td class="mono" style="max-width:280px;overflow:hidden;text-overflow:ellipsis" title="${(x.cwd||x.project).replace(/"/g,'&quot;')}">${_esc_js(x.cwd||x.project)}</td>
          <td class="mono">${x.id.slice(0,8)}…</td><td class="dim">${fmtSize(x.size)}</td>
          <td>${x.live?'<span class="ok">● 活跃</span>':'<span class="off">○ '+ago(x.mtime)+'</span>'}</td>
          <td><a href="${x.url}" target="_blank">查看会话 ↗</a></td></tr>`).join('') +
        `</table><div class="sub" style="padding:8px 16px">在 tmux 会话里运行的 Claude 可双向操作;普通终端里的 Claude 为只读实时视图。</div></div>`;
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
async function share(name, btn){
  btn.disabled = true; btn.textContent = '启动中…';
  try{
    const r = await fetch('/api/share/'+name, {method:'POST'});
    const j = await r.json();
    btn.textContent = j.ok ? '已启动 ✓' : '失败';
    setTimeout(load, 800);
  }catch(e){ btn.textContent = '失败'; }
}
function fmtSize(n){ return n>1048576 ? (n/1048576).toFixed(1)+' MB' : n>1024 ? (n/1024).toFixed(0)+' KB' : n+' B'; }
function ago(ts){ const s=Math.floor(Date.now()/1000-ts); return s<3600?Math.floor(s/60)+' 分钟前':s<86400?Math.floor(s/3600)+' 小时前':Math.floor(s/86400)+' 天前'; }
function _esc_js(s){ const d=document.createElement('div'); d.textContent=s||''; return d.innerHTML; }
load(); setInterval(load, 5000);
</script>"""
    return page("会话监控", body)


def transcript_page(session_id, path):
    sid = _esc(session_id[:8])
    body = f"""
<h1>🤖 Claude 会话 <span class="mono">{sid}…</span></h1>
<div class="sub" id="meta">加载中… · 2s 自动刷新</div>
<div id="log" style="display:flex;flex-direction:column;gap:10px;margin-top:16px"></div>
<script>
let stick = true;
const log = document.getElementById('log');
window.addEventListener('scroll', ()=>{{ stick = innerHeight+scrollY >= document.body.scrollHeight-60; }});
async function load(){{
  try{{
    const r = await fetch('/t/{_esc(session_id)}/data');
    const d = await r.json();
    document.getElementById('meta').textContent =
      (d.live ? '● 活跃 · ' : '○ 最后活动 ' ) + d.msgs + ' 条消息 · ' + d.project + ' · 2s 自动刷新';
    log.innerHTML = '';
    for(const m of d.msgs){{
      const div = document.createElement('div');
      div.style.cssText = m.role==='user'
        ? 'background:#1a2332;border:1px solid #26344d;border-radius:8px;padding:8px 12px'
        : 'background:#161b22;border:1px solid #30363d;border-radius:8px;padding:8px 12px';
      const head = document.createElement('div');
      head.className = 'dim'; head.style.fontSize = '11px'; head.style.marginBottom = '4px';
      head.textContent = (m.role==='user' ? '👤 用户' : '🤖 Claude') + (m.ts ? ' · ' + m.ts.replace('T',' ').slice(0,19) : '');
      div.appendChild(head);
      for(const p of m.parts){{
        const el = document.createElement('div');
        el.textContent = p.x;
        if(p.t === 'text'){{ el.style.whiteSpace = 'pre-wrap'; el.style.wordBreak = 'break-word'; }}
        else {{ el.className = 'dim'; el.style.cssText += ';font-family:ui-monospace,Menlo,monospace;font-size:11px;white-space:pre-wrap;word-break:break-word;padding:2px 0'; }}
        div.appendChild(el);
      }}
      log.appendChild(div);
    }}
    if(stick) scrollTo(0, document.body.scrollHeight);
  }}catch(e){{}}
}}
load(); setInterval(load, 2000);
</script>"""
    return page(f"Claude {sid}", body)


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


# ---------------------------------------------------------------- HTTP 服务
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass  # 静默访问日志

    # -- 认证 --
    def authorized(self):
        if NO_AUTH or not TOKEN:
            return True
        header = self.headers.get("Authorization", "")
        expected = "Basic " + base64.b64encode(f"{AUTH_USER}:{TOKEN}".encode()).decode()
        return hmac.compare_digest(header, expected)

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
        self.end_headers()
        self.wfile.write(data)

    def reply_json(self, obj, code=200):
        self.reply(code, json.dumps(obj, ensure_ascii=False), "application/json; charset=utf-8")

    # -- GET --
    def do_GET(self):
        if not self.authorized():
            return self.deny()
        path = self.path.split("?", 1)[0].rstrip("/") or "/"

        if path in ("/", "/index.html"):
            return self.reply(200, hub_page())

        if path == "/api/state":
            return self.reply_json({
                "hub": {"port": HUB_PORT},
                "shared": read_state_files(),
                "tmux": tmux_sessions(),
                "claude": claude_sessions(),
                "atomcode": atomcode_sessions(),
            })

        # /open/<port> → 跳到对应 ttyd(带凭据的一键登录)
        m = re.fullmatch(r"/open/(\d+)", path)
        if m:
            self.send_response(302)
            self.send_header("Location", f"http://{AUTH_USER}:{TOKEN}@{self.headers.get('Host', '127.0.0.1').split(':')[0]}:{m.group(1)}/")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

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
                    "project": _jsonl_last_cwd(jf) or jf.parent.name,
                    "mtime": st.st_mtime,
                    "msgs": parse_claude_jsonl(jf),
                })
            return self.reply(200, transcript_page(sid, jf))

        return self.reply(404, "404 Not Found", "text/plain; charset=utf-8")

    # -- POST:/api/share/<tmux会话名> --
    def do_POST(self):
        if not self.authorized():
            return self.deny()
        m = re.fullmatch(r"/api/share/([A-Za-z0-9_-]+)", self.path.split("?", 1)[0])
        if not m:
            return self.reply_json({"ok": False, "error": "路径不合法"}, 404)
        name = m.group(1)
        if not SHARE_SH.exists():
            return self.reply_json({"ok": False, "error": f"找不到 share.sh: {SHARE_SH}"}, 500)
        env = {k: v for k, v in os.environ.items() if k not in ("SS_PORT", "SS_SESSION")}
        try:
            r = subprocess.run(["bash", str(SHARE_SH), "serve", name],
                               capture_output=True, text=True, timeout=30, env=env)
            ok = r.returncode == 0
            return self.reply_json({"ok": ok, "output": (r.stdout or r.stderr)[-2000:]})
        except (subprocess.TimeoutExpired, OSError) as e:
            return self.reply_json({"ok": False, "error": str(e)}, 500)


def main():
    srv = ThreadingHTTPServer(("0.0.0.0", HUB_PORT), Handler)
    print(f"[hub] 会话监控面板已启动: http://0.0.0.0:{HUB_PORT} (认证已{'关闭' if NO_AUTH else '开启'})", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
