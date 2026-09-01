#!/usr/bin/env python3
"""把 /share_session 的 UserPromptSubmit hook 安装到已安装的 AI 工具。

原理:用户在 AI 工具里输入 /share_session 时,斜杠命令模板展开为 prompt 提交,
UserPromptSubmit hook 在【模型介入前】触发,直接执行 share 命令并返回结果 ——
LLM 不参与,不消耗推理 token(零 token)。

三工具 hooks 配置格式不同,分别合并写入(保留用户已有配置,绝不覆盖):
  - atomcode: ~/.atomcode/hooks.json —— 命名格式:
      {"hooks": {"<名字>": {"event": "user_prompt_submit",
                             "command": "...", "timeout_ms": 30000}}}
  - claude:   ~/.claude/settings.json 的 hooks 字段 —— CC 数组格式:
      {"hooks": {"UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", ...}]}]}}
  - codex:    ~/.codex/hooks.json —— 同上 CC 数组格式

用法:
  python3 hooks/install_hooks.py          # 检测并安装
  python3 hooks/install_hooks.py --force  # 强制重写 share-session 条目
"""
import argparse
import json
import os
import shutil
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK_PY = os.path.join(REPO, "hooks", "share_session_hook.py")

ATOMCODE_HOOK_NAME = "share-session"

# 工具 -> 配置文件路径
TOOLS = {
    "atomcode": os.path.expanduser("~/.atomcode/hooks.json"),
    "claude":   os.path.expanduser("~/.claude/settings.json"),
    "codex":    os.path.expanduser("~/.codex/hooks.json"),
}


def load_json(path):
    """读取 JSON,文件缺失/损坏时返回空 dict。"""
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")


def add_atomcode_hook(cfg, force):
    """atomcode 命名格式:{"hooks": {"share-session": {"event": ..., "command": ..., "timeout_ms": ...}}}。"""
    command = "python3 " + HOOK_PY
    hooks = cfg.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        hooks = {}
        cfg["hooks"] = hooks
    entry = hooks.get(ATOMCODE_HOOK_NAME)
    if isinstance(entry, dict) and "share_session_hook.py" in entry.get("command", ""):
        if force:
            entry["command"] = command
            entry["timeout_ms"] = 30000
            return cfg, True
        return cfg, False
    hooks[ATOMCODE_HOOK_NAME] = {
        "event": "user_prompt_submit",
        "command": command,
        "timeout_ms": 30000,
    }
    return cfg, True


def add_cc_hook(cfg, force):
    """claude/codex CC 数组格式:{"hooks": {"UserPromptSubmit": [{"matcher": "", "hooks": [...]}]}}。"""
    command = "python3 " + HOOK_PY
    hooks = cfg.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        hooks = {}
        cfg["hooks"] = hooks
    entries = hooks.get("UserPromptSubmit", [])
    if not isinstance(entries, list):
        entries = []
    for e in entries:
        if not isinstance(e, dict):
            continue
        for h in e.get("hooks", []):
            if isinstance(h, dict) and "share_session_hook.py" in h.get("command", ""):
                if force:
                    h["command"] = command
                    h["timeout"] = h.get("timeout", 30)
                    return cfg, True
                return cfg, False
    entries.append({
        "matcher": "",
        "hooks": [{"type": "command", "command": command, "timeout": 30}],
    })
    hooks["UserPromptSubmit"] = entries
    return cfg, True


def install_one(name, path, force):
    if not shutil.which(name):
        return f"  {name}: 未安装,跳过"
    cfg = load_json(path)
    if name == "atomcode":
        new_cfg, changed = add_atomcode_hook(cfg, force)
    else:
        new_cfg, changed = add_cc_hook(cfg, force)
    if changed:
        save_json(path, new_cfg)
        return f"  {name}: 已安装 UserPromptSubmit hook → {path}"
    return f"  {name}: hook 已存在,跳过"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true", help="覆盖已有 share-session hook 条目")
    args = ap.parse_args()

    installed = detected = 0
    for name, path in TOOLS.items():
        if shutil.which(name):
            detected += 1
        msg = install_one(name, path, args.force)
        print(msg)
        if "已安装" in msg:
            installed += 1
    if detected == 0:
        print("  未检测到已安装的 AI 工具(atomcode/claude/codex),跳过 hook 安装")
    elif installed == 0:
        print("  已检测到 %d 个 AI 工具,hook 此前均已安装,无需变更" % detected)
    return 0


if __name__ == "__main__":
    sys.exit(main())
