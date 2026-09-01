#!/usr/bin/env python3
"""hub 托管会话协议探测(冒烟测试用,复用 hub_attach 的 WS 客户端)。

用法:
  hub_ws_probe.py new  --cmd 'bash -c "echo HI; sleep 60"'      # 创建托管会话,输出 id
  hub_ws_probe.py read --id <id> --until MARKER [--timeout 10]  # 连 WS 读输出直到出现 MARKER
  hub_ws_probe.py write --id <id> --text 'echo x > /tmp/x\n'    # 连 WS 发送键盘输入
  hub_ws_probe.py ended --id <id> [--timeout 10]                # 轮询等待会话结束
"""
import argparse
import base64
import json
import shlex
import socket
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from hub_attach import WSClient, load_hub_cfg  # noqa: E402


def api(method, path, body=None):
    cfg = load_hub_cfg()
    port = int(cfg["port"])
    token = cfg.get("token", "")
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=json.dumps(body).encode() if body is not None else None, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Share-API", "1")
    if token:
        req.add_header("Authorization", "Basic " + base64.b64encode(f"ai:{token}".encode()).decode())
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def connect(sid, timeout=2.0):
    cfg = load_hub_cfg()
    port = int(cfg["port"])
    token = cfg.get("token", "")
    auth = "Basic " + base64.b64encode(f"ai:{token}".encode()).decode() if token else ""
    ws = WSClient("127.0.0.1", port, f"/ws/{sid}", auth)
    ws.sock.settimeout(timeout)
    return ws


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["new", "read", "write", "ended"])
    ap.add_argument("--cmd", help="new:完整命令行")
    ap.add_argument("--id")
    ap.add_argument("--text")
    ap.add_argument("--until")
    ap.add_argument("--timeout", type=float, default=10)
    a = ap.parse_args()

    if a.action == "new":
        if not a.cmd:
            print("--cmd 必填", file=sys.stderr)
            return 2
        r = api("POST", "/api/new", {"argv": shlex.split(a.cmd), "cwd": "/tmp"})
        print(r.get("id", ""))
        return 0 if r.get("ok") else 1

    if not a.id:
        print("--id 必填", file=sys.stderr)
        return 2

    if a.action == "read":
        if not a.until:
            print("--until 必填", file=sys.stderr)
            return 2
        ws = connect(a.id)
        ws.send_binary(json.dumps({"type": "init", "cols": 120, "rows": 30}).encode())
        deadline = time.time() + a.timeout
        buf = b""
        while time.time() < deadline:
            try:
                fr = ws.recv()
            except socket.timeout:
                continue
            if fr is None or fr[0] == "close":
                break
            op, data = fr
            if op == 0x2:
                buf += data
                if a.until.encode() in buf:
                    return 0
        return 1

    if a.action == "write":
        if a.text is None:
            print("--text 必填", file=sys.stderr)
            return 2
        ws = connect(a.id)
        ws.send_binary(json.dumps({"type": "init", "cols": 120, "rows": 30}).encode())
        time.sleep(0.2)
        ws.send_text(a.text)
        return 0

    # ended
    deadline = time.time() + a.timeout
    while time.time() < deadline:
        s = api("GET", "/api/state")
        m = [x for x in s.get("managed", []) if x["id"] == a.id]
        if not m or m[0]["exited"]:
            return 0
        time.sleep(0.3)
    return 1


if __name__ == "__main__":
    sys.exit(main())
