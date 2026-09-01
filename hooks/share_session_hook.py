#!/usr/bin/env python3
"""ai-session-share UserPromptSubmit hook —— 零 token 拦截 /share_session。

用户在 AI 工具(atomcode / claude / codex)里输入 /share_session 时,
斜杠命令模板展开为 prompt 提交,UserPromptSubmit hook 在【模型介入前】触发,
直接执行共享命令并把链接写进 {"decision":"block","reason":...} 返回 ——
LLM 完全不参与,不消耗任何推理 token。

会话感知(核心):输出的链接必须对应【调用它的那个会话】,绝不打印其他会话的链接:

  1. 终端在 tmux 内($TMUX 存在)
     → share here:把【当前所在的】 tmux 会话共享为可双向操作的 Web 终端;
  2. 不在 tmux 内、但 stdin JSON 带 session_id(claude 会传)
     → 启动会话监控面板,输出【当前 Claude 会话】的实时网页视图链接(/t/<session_id>);
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
)

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

STATE_DIR = Path(os.environ.get("SS_STATE_DIR", str(Path.home() / ".ai-session-share")))
HOOK_DIR = Path(__file__).resolve().parent
REPO_DIR = HOOK_DIR.parent
SHARE_SH = REPO_DIR / "share.sh"


def hit(prompt: str) -> bool:
    return any(m in prompt for m in MARKERS)


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


def build_links() -> str:
    """按会话上下文生成输出文本(带 [share] 前缀,风格与 share.sh 一致)。"""
    lines = []

    # 分支 1:在 tmux 会话内 → 共享当前 tmux 会话(可双向操作)
    if os.environ.get("TMUX"):
        sh = share_sh_path()
        rc, out = run(["bash", sh, "here"]) if sh != "share" else run(["share", "here"])
        if rc == 0 and out.strip():
            lines.append(out.strip())
        else:
            lines.append("[share] 执行 share here 失败,可手动运行: share here")

    # 公共:确保监控面板在运行(所有分支都需要它承载 /t/ 视图与面板)
    hub = ensure_hub()

    if not os.environ.get("TMUX"):
        # 分支 2:不在 tmux 内 → Claude 会话的实时网页视图(只读)
        sid = DATA.get("session_id") or DATA.get("sessionId") or ""
        tp = DATA.get("transcript_path") or DATA.get("transcriptPath") or ""
        if sid and hub and want_claude_view(sid, tp):
            ip = lan_ip()
            port, token = hub["port"], hub.get("token", "")
            base = f"http://{ip}:{port}"
            view = f"{base}/t/{sid}"
            lines.append("[share] 已把当前 Claude 会话共享为网页(实时视图):")
            lines.append(f"[share]   局域网访问: {view}")
            if token:
                lines.append(f"[share]   浏览器登录: 用户名 ai，密码 {token}")
                lines.append(f"[share]   一键登录: http://ai:{token}@{ip}:{port}/t/{sid}")
            lines.append("[share]   说明: 当前终端不在 tmux 内,网页是该会话的实时只读视图;")
            lines.append("[share]         要浏览器能直接输入操作,请在 tmux 会话里运行 AI 工具:")
            lines.append(f"[share]         share start  # 进入 tmux 后运行: claude --resume {sid}")
            lines.append(f"[share]   会话监控面板(所有会话): {base}/")
        elif hub:
            # 分支 3 兜底:面板首页
            ip = lan_ip()
            port, token = hub["port"], hub.get("token", "")
            base = f"http://{ip}:{port}"
            lines.append("[share] 当前终端不在 tmux 内,已打开会话监控面板(可选任意会话查看):")
            lines.append(f"[share]   面板地址: {base}/")
            if token:
                lines.append(f"[share]   浏览器登录: 用户名 ai，密码 {token}")
                lines.append(f"[share]   一键登录: http://ai:{token}@{ip}:{port}/")
        else:
            lines.append("[share] 会话监控面板启动失败,请确认已运行 ./install.sh -y 安装依赖(python3)")
    elif hub:
        # tmux 分支附加:面板链接
        ip = lan_ip()
        lines.append(f"[share] 会话监控面板(所有会话): http://{ip}:{hub['port']}/")

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
    # block:不调用 LLM,直接把链接展示给用户
    print(json.dumps({"decision": "block", "reason": out}, ensure_ascii=False))


if __name__ == "__main__":
    main()
