#!/usr/bin/env python3
"""把 ai-session-share 的 MCP 服务器注册到本机各 AI 客户端。

注册后,任何支持 MCP 的 AI 客户端(claude / atomcode / codex / 其他)都能直接
在对话里 list_sessions / spawn_session / send_input / read_output / kill_session,
查看与操作所有共享会话。

三客户端配置格式不同,分别合并写入(保留用户已有配置,绝不覆盖):
  - claude:   ~/.claude.json 顶层 "mcpServers"(JSON,与其他配置共存)
  - atomcode: ~/.atomcode/mcp.json "mcpServers"(JSON)
  - codex:    ~/.codex/config.toml 追加 [mcp_servers.ai-session-share](TOML)

用法:
  python3 mcp_register.py            # 检测并安装
  python3 mcp_register.py --home DIR # 用指定 HOME(测试用)
"""
import argparse
import json
import os
import shutil
import sys
from pathlib import Path

MCP_NAME = "ai-session-share"
MCP_DESC_NOTE = "terminal session sharing: list/spawn/send/read/kill sessions"

REPO = Path(__file__).resolve().parent
MCP_PY = REPO / "mcp_server.py"


def home_path(args, rel):
    return Path(args.home) / rel


def which_bin(name, args):
    # 测试 HOME 下用假 bin 目录里的可执行文件判断"是否安装"
    fake = Path(args.home) / "bin" / name
    if fake.is_file() and os.access(fake, os.X_OK):
        return True
    return shutil.which(name) is not None


def load_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def save_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    tmp.replace(path)


def mcp_entry():
    env = {"SS_HUB_URL": os.environ.get("SS_HUB_URL", "http://127.0.0.1:7690")}
    return {
        "type": "stdio",
        "command": sys.executable or "python3",
        "args": [str(MCP_PY)],
        "env": env,
    }


def register_json(cfg_path):
    """claude / atomcode 的 mcpServers JSON 格式。"""
    cfg = load_json(cfg_path)
    servers = cfg.get("mcpServers")
    if not isinstance(servers, dict):
        servers = {}
    servers[MCP_NAME] = mcp_entry()
    cfg["mcpServers"] = servers
    save_json(cfg_path, cfg)
    return True


def register_toml(cfg_path):
    """codex 的 [mcp_servers.<name>] TOML 段(追加式,幂等:先剔除旧段)。"""
    entry = mcp_entry()
    header = f"[mcp_servers.{MCP_NAME}]"
    text = ""
    if cfg_path.exists():
        try:
            text = cfg_path.read_text(encoding="utf-8")
        except OSError:
            text = ""
    lines = text.splitlines()
    # 幂等:删除已有本段(从 header 行到下一个 [ 开头的行或文件尾)
    out, skipping = [], False
    for ln in lines:
        if ln.strip() == header:
            skipping = True
            continue
        if skipping and ln.lstrip().startswith("["):
            skipping = False
        if not skipping:
            out.append(ln)
    while out and not out[-1].strip():
        out.pop()
    block = [
        "",
        f"# {MCP_DESC_NOTE}",
        header,
        f'command = "{entry["command"]}"',
        f'args = ["{entry["args"][0]}"]',
        f'env = {{ SS_HUB_URL = "{entry["env"]["SS_HUB_URL"]}" }}',
    ]
    cfg_path.parent.mkdir(parents=True, exist_ok=True)
    cfg_path.write_text("\n".join(out + block) + "\n", encoding="utf-8")
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--home", default=str(Path.home()), help="目标 HOME(默认真实家目录;测试用)")
    args = ap.parse_args()

    if not MCP_PY.exists():
        print(f"  缺少 {MCP_PY},跳过 MCP 注册")
        return 0

    jobs = [
        # (客户端名, 探测命令, 配置路径, 注册函数)
        ("claude", "claude", home_path(args, ".claude.json"), register_json),
        ("atomcode", "atomcode", home_path(args, ".atomcode/mcp.json"), register_json),
        ("codex", "codex", home_path(args, ".codex/config.toml"), register_toml),
    ]
    registered = 0
    for name, binname, cfg_path, fn in jobs:
        if not which_bin(binname, args):
            print(f"  {name}: 未安装,跳过")
            continue
        try:
            fn(cfg_path)
            print(f"  {name}: 已注册 MCP 服务器 {MCP_NAME} → {cfg_path}")
            registered += 1
        except OSError as e:
            print(f"  {name}: 注册失败({e})")
    if registered == 0:
        print("  未检测到已安装的 MCP 客户端(claude/atomcode/codex),跳过注册")
    else:
        print(f"  共 {registered} 个客户端已接入(重启 AI 客户端后可用 list_sessions 等工具)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
