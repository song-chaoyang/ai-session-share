#!/usr/bin/env python3
"""ai-session-share UserPromptSubmit hook —— 零 token 拦截 /share_session。

用户在 AI 工具(atomcode / claude / codex)里输入 /share_session 时,
斜杠命令模板展开为 prompt 提交,UserPromptSubmit hook 在【模型介入前】触发,
直接执行共享命令并把链接写进 {"decision":"block","reason":...} 返回 ——
LLM 完全不参与,不消耗任何推理 token。

会话感知(核心):输出的链接必须对应【调用它的那个会话】,绝不打印其他会话的链接:

  1. AI 工具就跑在托管会话里($SS_MANAGED_ID 存在,hub 用 PTY 起的)
     → 链接即本会话的双向终端;生命周期与会话进程绑定(/exit → 网页自动结束);
  2. 普通终端(无论是否在 tmux 内)、stdin JSON 带 session_id(claude 会传)
     → 自动 claude --resume 起托管会话,输出双向网页终端链接;
       失败或 SS_HOOK_VIEW_ONLY=1 时退回只读实时视图(/t/<session_id>);
  3. 兜底 → 监控面板首页(列出所有运行中的会话,由用户自选)。

未命中 /share_session 特征则空输出放行,不影响其他对话。
只依赖 Python 标准库。配合 install.sh 安装到各工具的 hooks 配置。
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# 命中标记:模板 commands/share_session.md 中的特征文本(斜杠命令展开后必然出现)
MARKERS = (
    "/share_session",
    "把当前终端会话共享成局域网 Web 服务",
    "局域网访问链接",
    "$ARGUMENTS",
)

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

STATE_DIR = Path(os.environ.get("SS_STATE_DIR", str(Path.home() / ".ai-session-share")))
HOOK_DIR = Path(__file__).resolve().parent
REPO_DIR = HOOK_DIR.parent
SHARE_SH = REPO_DIR / "share.sh"


def hit(prompt: str) -> bool:
    return any(m in prompt for m in MARKERS)


def wants_mcp(prompt: str) -> bool:
    """/share_session mcp [config] → 额外输出 MCP 客户端配置(默认带鉴权)。

    兼容两种展开形态:
    - 原样命令串:行首 "/share_session mcp …";
    - 模板被工具替换 $ARGUMENTS 后:"用户输入的参数(原样透传给 hook 识别):mcp"。
    """
    for ln in prompt.splitlines():
        s = ln.strip()
        if s.startswith("/share_session"):
            parts = s.split()
            if len(parts) > 1 and parts[1].lower().rstrip("。.") == "mcp":
                return True
        if s.startswith("用户输入的参数"):
            tail = s.split(":", 1)[-1].split("：", 1)[-1].strip()
            parts = tail.split()
            if parts and parts[0].lower().rstrip("。.") == "mcp":
                return True
    return False


def run(cmd, timeout=40):
    """执行命令,返回 (returncode, stdout);异常按失败处理。"""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout
    except (subprocess.TimeoutExpired, OSError):
        return 1, ""


def share_sh_path() -> str:
    """优先用仓库内 share.sh(hook 与其同仓库);否则用 PATH 里的 share 命令。"""
    return str(SHARE_SH) if SHARE_SH.exists() else "share"


def ensure_hub() -> dict:
    """确保会话监控面板在运行(幂等);返回 hub.state 的 {port, token} 或 {}。"""
    if not SHARE_SH.exists():
        return {}
    rc, _ = run(["bash", str(SHARE_SH), "hub", "start"])
    if rc != 0:
        return {}
    cfg = {}
    try:
        for line in (STATE_DIR / "hub.state").read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                cfg[k] = v
    except OSError:
        return {}
    if cfg.get("port"):
        return cfg
    return {}


def lan_ip() -> str:
    """探测局域网 IP(与 share.sh 同策略;失败回退 127.0.0.1)。"""
    if sys.platform == "darwin":
        for i in range(10):
            rc, out = run(["ipconfig", "getifaddr", f"en{i}"], timeout=5)
            ip = out.strip()
            if rc == 0 and ip:
                return ip
    else:
        rc, out = run(["hostname", "-I"], timeout=5)
        for ip in out.split():
            if re.match(r"^\d+\.\d+\.\d+\.\d+$", ip) and not ip.startswith(("127.", "169.254.")):
                return ip
    return "127.0.0.1"


def claude_session_exists(sid: str) -> bool:
    """session_id 是否有对应的 Claude 会话文件(projects/<slug>/<sid>.jsonl)。
    不存在时兜底到面板首页,绝不输出打不开的深链。"""
    if not re.fullmatch(r"[A-Za-z0-9-]+", sid or ""):
        return False
    root = Path(os.environ.get("SS_CLAUDE_DIR", str(Path.home() / ".claude" / "projects")))
    if not root.is_dir():
        return False
    try:
        return any((d / f"{sid}.jsonl").is_file() for d in root.iterdir() if d.is_dir())
    except OSError:
        return False


def want_claude_view(sid: str, transcript_path: str) -> bool:
    """判断能否给当前会话输出 /t/<sid> 深链。

    - 带 transcript_path(Claude Code 权威字段):直接信任 —— 新会话的 jsonl 在
      hook 返回后才会写入,存在性检查必然失败,不能因此降级;
    - 只有 session_id(其他工具):仅在文件已存在时信任,避免输出死链。
    """
    if not re.fullmatch(r"[A-Za-z0-9-]+", sid or ""):
        return False
    if transcript_path:
        return True
    return claude_session_exists(sid)


def spawn_resume_session(sid: str, cwd: str = "") -> str:
    """把当前 Claude 会话以 claude --resume 起成托管会话,返回 share.sh new 的输出(失败返回空串)。

    cwd 来自 hook stdin 的 cwd 字段(即 AI 工具的运行目录),保证 resume 出的
    Claude 落在目标项目路径而不是 $HOME。普通终端里的 Claude 进程无法事后
    接管(stdin 已绑定原终端),--resume 是唯一能"从当前上下文继续"的方式:
    网页终端与本地原会话是同一对话历史的两个分支,两边可各自继续。
    SS_HOOK_VIEW_ONLY=1 可禁用(测试/只读偏好)。
    """
    if os.environ.get("SS_HOOK_VIEW_ONLY", "") == "1":
        return ""
    sh = share_sh_path()
    base = [sh, "new", "--no-attach"] if sh != "share" else ["share", "new", "--no-attach"]
    if cwd and os.path.isdir(cwd):
        base += ["--cwd", cwd]
    cmd = base + ["claude", "--resume", sid]
    rc, out = run(["bash"] + cmd if sh != "share" else cmd, timeout=90)
    # share.sh 输出带 ANSI 颜色码:先剥离再判断/透传,否则链接与密码行无法匹配
    out = ANSI_RE.sub("", out or "")
    if rc == 0 and "/w/" in out:
        return out.strip()
    return ""


def build_links() -> str:
    """按会话上下文生成输出文本(带 [share] 前缀,风格与 share.sh 一致)。"""
    lines = []

    # 分支 0:当前 AI 工具就跑在本服务的托管会话里(hub 用 PTY 起的)
    # → 链接即本会话的双向终端;生命周期与会话进程绑定(/exit → 网页自动结束)
    managed = os.environ.get("SS_MANAGED_ID", "")
    if managed:
        hub = ensure_hub()
        if hub:
            ip = lan_ip()
            port, token = hub["port"], hub.get("token", "")
            view = f"http://{ip}:{port}/w/{managed}"
            lines.append("[share] 当前会话已在托管终端中,链接即本会话(双向操作,生命周期与会话绑定):")
            lines.append(f"[share]   局域网访问: {view}")
            if token:
                lines.append(f"[share]   浏览器登录: 用户名 ai，密码 {token}")
                lines.append(f"[share]   免密登录(打开即自动登录): {view}?key={token}")
            lines.append("[share]   说明: 在会话里执行 /exit 或进程退出后,网页会话自动结束,无需 stop;")
            lines.append(f"[share]   本机重新连接: share attach {managed}")
            lines.append(f"[share]   会话监控面板(所有会话): http://{ip}:{port}/")
            return "\n".join(lines)

    # 公共:确保监控面板在运行(所有分支都需要它承载 /t/ /w/ 视图与面板)
    hub = ensure_hub()

    # 分支 2(非托管会话):把当前 Claude 会话继续为托管会话(claude --resume),
    # 网页直接可操作;失败或被禁用时退回只读实时视图 /t/<sid>。
    # 不区分当前终端是否在 tmux 里 —— 托管会话由 hub 自己起 PTY,与外层无关;
    # 在 tmux 里运行的 Claude 同样走 resume(网页与本地是同对话的两个分支)。
    sid = DATA.get("session_id") or DATA.get("sessionId") or ""
    tp = DATA.get("transcript_path") or DATA.get("transcriptPath") or ""
    orig_cwd = DATA.get("cwd") or ""
    ip = lan_ip()
    if sid and hub and want_claude_view(sid, tp):
        port, token = hub["port"], hub.get("token", "")
        base = f"http://{ip}:{port}"
        resume_out = spawn_resume_session(sid, orig_cwd)
        if resume_out:
            lines.append("[share] 已把当前 Claude 会话共享为网页终端(双向可继续):")
            # share.sh 的输出已是 [share] 风格(含托管会话 id/命令/局域网链接/密码),
            # ANSI 已剥离,整体透传即可 —— 不做逐行前缀过滤(曾有丢行 bug)
            lines.append(resume_out)
            lines.append("[share]   说明: 网页是当前对话的继续分支(claude --resume),")
            lines.append("[share]         两边可各自继续;网页里执行 /exit 即结束该共享。")
            lines.append(f"[share]   只读实时视图(原会话): {base}/t/{sid}")
            lines.append(f"[share]   会话监控面板(所有会话): {base}/")
        else:
            view = f"{base}/t/{sid}"
            lines.append("[share] 已把当前 Claude 会话共享为网页(只读实时视图):")
            lines.append(f"[share]   局域网访问: {view}")
            if token:
                lines.append(f"[share]   浏览器登录: 用户名 ai，密码 {token}")
                lines.append(f"[share]   免密登录(打开即自动登录): {view}?key={token}")
            lines.append("[share]   说明: 浏览器打开后可实时查看本会话;")
            lines.append("[share]         页面上有\"在网页继续此会话\"按钮,点击即可转为双向终端。")
            lines.append(f"[share]   会话监控面板(所有会话): {base}/")
    elif hub:
        # 分支 3 兜底:面板首页
        port, token = hub["port"], hub.get("token", "")
        base = f"http://{ip}:{port}"
        lines.append("[share] 已打开会话监控面板(可选任意会话查看):")
        lines.append(f"[share]   面板地址: {base}/")
        if token:
            lines.append(f"[share]   浏览器登录: 用户名 ai，密码 {token}")
            lines.append(f"[share]   免密登录(打开即自动登录): {base}/?key={token}")
    else:
        lines.append("[share] 会话监控面板启动失败,请确认已运行 ./install.sh -y 安装依赖(python3)")

    return "\n".join(lines)


# stdin JSON 在模块级解析一次,供 build_links 分支判断
RAW = sys.stdin.read()
try:
    DATA = json.loads(RAW)
    if not isinstance(DATA, dict):
        DATA = {}
except (ValueError, json.JSONDecodeError):
    DATA = {}


def main() -> None:
    prompt = DATA.get("prompt", "")
    if not hit(prompt):
        # 与共享无关的对话:放行给模型
        return
    out = ANSI_RE.sub("", build_links()).strip()
    if not out:
        out = "[share] 共享失败:请确认已运行 ./install.sh -y"
    # /share_session mcp [config] → 追加 MCP 客户端配置(默认带鉴权 token)
    if wants_mcp(prompt):
        rc, mcp_out = run(["bash", str(SHARE_SH), "mcp", "config"]
                          if SHARE_SH.exists() else ["share", "mcp", "config"], timeout=20)
        if rc == 0 and mcp_out.strip():
            out += "\n" + ANSI_RE.sub("", mcp_out).strip()
        else:
            out += "\n[share]   (MCP 配置获取失败:请手动执行 share mcp config)"
    # block:不调用 LLM,直接把链接展示给用户
    print(json.dumps({"decision": "block", "reason": out}, ensure_ascii=False))


if __name__ == "__main__":
    main()
