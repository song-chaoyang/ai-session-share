#!/usr/bin/env python3
"""ai-session-share WebSocket 写入链路探针（仅标准库）。

按 ttyd 1.7.x 的真实 WS 协议工作（src/server.h + src/protocol.c）：
1. GET /token（Basic Auth）取 base64 凭据；
2. 以子协议 "tty" 升级 /ws（携带 Basic Auth 头）；
3. 发 JSON_DATA 帧（含 AuthToken + 窗口尺寸）完成认证并拉起子进程；
4. 发 INPUT 帧写入命令（补回车）；
5. 读取服务端 OUTPUT 帧回显，验证写入通路。

用法:
  ws_probe.py --port PORT --user ai --state-file ~/.ai-session-share/<s>.state --command "echo x > /tmp/mark"

退出码: 0=写入成功且收到回显; 2=升级/认证/写入失败; 3=token 获取失败
"""
import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import time
import urllib.request

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

# ttyd 协议命令字节（server.h）：客户端消息
INPUT = b"0"       # '0'
JSON_DATA = b"{"   # '{'
# 服务端消息
OUTPUT = b"0"      # '0'


def read_state_token(path):
    """从 share.sh 的状态文件读取认证 token。"""
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            key, _, value = line.partition("=")
            if key.strip() == "token":
                return value.strip()
    print(f"状态文件 {path} 中没有 token", file=sys.stderr)
    sys.exit(3)


def basic_auth(user, token):
    return base64.b64encode(f"{user}:{token}".encode()).decode()


def get_ws_token(port, user, token):
    """POST /token 获取 WebSocket 认证 token（即 base64 凭据）。"""
    basic = basic_auth(user, token)
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/token", method="POST", data=b""
    )
    req.add_header("Authorization", f"Basic {basic}")
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            body = resp.read().decode()
    except Exception as exc:  # noqa: BLE001 - 探针脚本，收敛所有异常
        print(f"token 接口失败: {exc}", file=sys.stderr)
        sys.exit(3)
    try:
        return json.loads(body)["token"]
    except (ValueError, KeyError):
        print(f"token 响应异常: {body!r}", file=sys.stderr)
        sys.exit(3)


def send_frame(sock, payload: bytes):
    """发送一个带掩码的二进制帧（客户端→服务端必须掩码）。"""
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    header = bytearray([0x82])  # FIN + opcode=2(binary)
    ln = len(masked)
    if ln < 126:
        header.append(0x80 | ln)
    elif ln < 65536:
        header.append(0x80 | 126)
        header += struct.pack(">H", ln)
    else:
        header.append(0x80 | 127)
        header += struct.pack(">Q", ln)
    sock.sendall(bytes(header) + mask + masked)


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("连接已关闭")
        buf += chunk
    return buf


def recv_frame(sock, timeout=3):
    """读取一个完整帧，返回 (opcode, payload)；超时返回 None。"""
    sock.settimeout(timeout)
    try:
        first = recv_exact(sock, 2)
        opcode = first[0] & 0x0F
        ln = first[1] & 0x7F
        if ln == 126:
            ln = struct.unpack(">H", recv_exact(sock, 2))[0]
        elif ln == 127:
            ln = struct.unpack(">Q", recv_exact(sock, 8))[0]
        return opcode, recv_exact(sock, ln)
    except (socket.timeout, ConnectionError):
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True, type=int)
    ap.add_argument("--user", default="ai")
    ap.add_argument("--state-file", help="share.sh 状态文件路径（含 token）")
    ap.add_argument("--token", help="直接指定 token（与 --state-file 二选一）")
    ap.add_argument("--command", required=True)
    args = ap.parse_args()

    if args.state_file:
        token = read_state_token(args.state_file)
    elif args.token is not None:
        token = args.token
    else:
        print("必须提供 --state-file 或 --token", file=sys.stderr)
        sys.exit(3)

    # 1. 取 base64 凭据（ttyd 的 /token 返回的就是它）
    credential = get_ws_token(args.port, args.user, token)

    # 2. WS 升级：子协议 tty + Basic Auth
    key = base64.b64encode(os.urandom(16)).decode()
    accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()

    sock = socket.create_connection(("127.0.0.1", args.port), timeout=5)
    req = (
        f"GET /ws?token={credential} HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{args.port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "Sec-WebSocket-Protocol: tty\r\n"
        f"Authorization: Basic {basic_auth(args.user, token)}\r\n"
        "\r\n"
    )
    sock.sendall(req.encode())

    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = sock.recv(4096)
        if not chunk:
            break
        resp += chunk
    head = resp.split(b"\r\n\r\n", 1)[0].decode(errors="replace")
    status = head.split("\r\n", 1)[0] if head else "(无响应)"
    if "101" not in status:
        print(f"升级失败: {status}", file=sys.stderr)
        sock.close()
        sys.exit(2)
    if accept not in head:
        print("Sec-WebSocket-Accept 校验失败", file=sys.stderr)
        sock.close()
        sys.exit(2)
    if "Sec-WebSocket-Protocol: tty" not in head:
        print("服务端未确认 tty 子协议", file=sys.stderr)
        sock.close()
        sys.exit(2)

    # 3. JSON_DATA 认证并拉起子进程（含窗口尺寸）
    # 注意：JSON_DATA 命令字节就是 '{'，html 客户端直接发送裸 JSON，
    # 其首字符 '{' 兼作命令字节，不能再额外拼 '{'。
    auth_json = json.dumps({"AuthToken": credential, "columns": 80, "rows": 24})
    send_frame(sock, auth_json.encode())

    # 等待子进程（tmux attach）拉起，避免 INPUT 帧竞态丢失；真实浏览器用户也有此间隔
    time.sleep(0.8)

    # 4. INPUT 写命令（终端规范模式，补回车才会执行）
    if not args.command.endswith(("\r", "\n")):
        args.command += "\r"
    send_frame(sock, INPUT + args.command.encode())

    # 5. 读取回显（OUTPUT 帧 = '0' + 数据）
    echoed = False
    for _ in range(12):
        frame = recv_frame(sock)
        if frame is None:
            break
        opcode, payload = frame
        if opcode == 8:  # close
            print(f"连接被关闭: {payload!r}", file=sys.stderr)
            break
        if payload.startswith(OUTPUT):
            echoed = True
            print(f"收到回显: {payload[1:]!r}")
        else:
            print(f"收到帧(opcode={opcode}): {payload[:80]!r}")
    sock.close()

    if echoed:
        print("ws 写入成功: 命令已发送到终端")
        sys.exit(0)
    print("未收到回显，写入可能失败", file=sys.stderr)
    sys.exit(2)


if __name__ == "__main__":
    main()
