#!/usr/bin/env python3
"""share attach —— 把本地终端连接到托管会话(不依赖 tmux)。

通过 WebSocket 连到 hub 的 /ws/<id>,本地终端 raw 模式直通 PTY:
本机与所有浏览器操作的是同一个会话;关闭本终端【不会】结束会话,
会话进程退出(如 Claude 里 /exit)时所有连接自动结束。

协议(与 hub_server 一致):
  本工具 → 服务端: 文本帧 = 键盘输入;二进制帧 = 控制JSON(init/resize)
  服务端 → 本工具: 二进制帧 = 终端原始输出;文本帧 = 控制JSON(ended)
"""
import argparse
import base64
import json
import os
import select
import signal
import socket
import struct
import sys
import termios
import tty

try:
    import fcntl
except ImportError:
    fcntl = None

# TIOCGWINSZ:macOS 0x40087468 / Linux 0x5413
TIOCGWINSZ = 0x40087468 if sys.platform == "darwin" else 0x5413


def die(msg):
    print(f"[share] {msg}", file=sys.stderr)
    sys.exit(1)


def load_hub_cfg():
    """读 hub.state(与 share.sh / hub_server 同一状态目录);SS_HUB_URL 兜底端口。"""
    state_dir = os.environ.get("SS_STATE_DIR", os.path.expanduser("~/.ai-session-share"))
    path = os.path.join(state_dir, "hub.state")
    cfg = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if "=" in line:
                    k, v = line.rstrip("\n").split("=", 1)
                    cfg[k] = v
    except OSError:
        pass
    if not cfg.get("port") or not cfg.get("token"):
        # 兜底:全局环境变量 SS_HUB_URL / SS_HUB_TOKEN(install.sh 写入 shell rc)
        hub_url = os.environ.get("SS_HUB_URL", "").rstrip("/")
        if not cfg.get("port") and hub_url and ":" in hub_url:
            cfg["port"] = hub_url.rsplit(":", 1)[1]
        if not cfg.get("token") and os.environ.get("SS_HUB_TOKEN"):
            cfg["token"] = os.environ["SS_HUB_TOKEN"]
    if not cfg.get("port"):
        die(f"会话监控面板未运行(找不到 {path},且未设 SS_HUB_URL),先执行: share hub start")
    return cfg


def get_winsize(fd):
    if fcntl is None or not os.isatty(fd):
        return 80, 24
    try:
        data = fcntl.ioctl(fd, TIOCGWINSZ, b"\x00" * 8)
        rows, cols = struct.unpack("HHHH", data)[:2]
        return cols or 80, rows or 24
    except OSError:
        return 80, 24


class WSClient:
    """最小 WebSocket 客户端(标准库实现,客户端帧按 RFC 6455 加掩码)。"""

    def __init__(self, host, port, path, auth=""):
        self.sock = socket.create_connection((host, port), timeout=10)
        self.sock.settimeout(None)
        self.buf = b""
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\n"
               + (f"Authorization: {auth}\r\n" if auth else "")
               + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                 f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise OSError("连接在握手前被关闭")
            head += chunk
            if len(head) > 65536:
                raise OSError("握手响应异常")
        status = head.split(b"\r\n", 1)[0].decode("latin-1")
        if " 101 " not in status:
            raise OSError("WebSocket 升级失败: " + status.strip())
        self.buf = head.split(b"\r\n\r\n", 1)[1]

    def _fill(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                return False
            self.buf += chunk
        return True

    def send(self, opcode, payload: bytes):
        mask = os.urandom(4)
        n = len(payload)
        hdr = bytearray([0x80 | opcode])
        if n < 126:
            hdr.append(0x80 | n)
        elif n < 65536:
            hdr.append(0x80 | 126)
            hdr += struct.pack(">H", n)
        else:
            hdr.append(0x80 | 127)
            hdr += struct.pack(">Q", n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(hdr) + mask + masked)

    def send_text(self, s: str):
        self.send(0x1, s.encode())

    def send_binary(self, b: bytes):
        self.send(0x2, b)

    def recv(self):
        """返回 (opcode, payload);连接关闭返回 ("close", b"")。"""
        if not self._fill(2):
            return ("close", b"")
        b1, b2 = self.buf[0], self.buf[1]
        opcode = b1 & 0x0F
        ln = b2 & 0x7F
        off = 2
        if ln == 126:
            if not self._fill(4):
                return ("close", b"")
            ln = struct.unpack(">H", self.buf[2:4])[0]
            off = 4
        elif ln == 127:
            if not self._fill(10):
                return ("close", b"")
            ln = struct.unpack(">Q", self.buf[2:10])[0]
            off = 10
        if ln > (1 << 22):
            return ("close", b"")
        if not self._fill(off + ln):
            return ("close", b"")
        data = self.buf[off:off + ln]
        self.buf = self.buf[off + ln:]
        if opcode == 0x8:      # close
            return ("close", b"")
        if opcode == 0x9:      # ping → pong
            self.send(0xA, data)
            return self.recv()
        return (opcode, data)


def main():
    ap = argparse.ArgumentParser(description="连接到 ai-session-share 托管会话")
    ap.add_argument("session_id", help="托管会话 id(share new 输出或面板上查看)")
    args = ap.parse_args()

    cfg = load_hub_cfg()
    port = int(cfg["port"])
    token = cfg.get("token", "")
    auth = "Basic " + base64.b64encode(f"ai:{token}".encode()).decode() if token else ""
    try:
        ws = WSClient("127.0.0.1", port, f"/ws/{args.session_id}", auth)
    except OSError as e:
        die(f"连接托管会话失败: {e}(会话可能已结束)")

    is_tty = sys.stdin.isatty() and sys.stdout.isatty()
    old_term = None
    if is_tty:
        old_term = termios.tcgetattr(0)
        tty.setraw(0)

    cols, rows = get_winsize(0)
    ws.send_binary(json.dumps({"type": "init", "cols": cols, "rows": rows}).encode())

    resize_flag = {"on": False}

    def _winch(*_):
        resize_flag["on"] = True

    if is_tty:
        try:
            signal.signal(signal.SIGWINCH, _winch)
        except (ValueError, OSError):
            pass

    stdin_open = True
    try:
        while True:
            rlist = ([0] if stdin_open else []) + [ws.sock]
            try:
                r, _, _ = select.select(rlist, [], [], 0.5)
            except InterruptedError:
                r = []
            if resize_flag["on"]:
                resize_flag["on"] = False
                c2, r2 = get_winsize(0)
                ws.send_binary(json.dumps({"type": "resize", "cols": c2, "rows": r2}).encode())
            if 0 in r:
                try:
                    data = os.read(0, 65536)
                except OSError:
                    data = b""
                if not data:
                    # 本地输入关闭(管道 EOF):停止转发输入,继续显示会话输出
                    stdin_open = False
                else:
                    ws.send_text(data.decode("utf-8", "replace"))
            if ws.sock in r:
                fr = ws.recv()
                if fr is None or fr[0] == "close":
                    print("\r\n[share] 连接已关闭。\r\n")
                    return 0
                op, data = fr
                if op == 0x2:          # 二进制 = 终端原始输出
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                elif op == 0x1:        # 文本 = 控制消息
                    try:
                        ctl = json.loads(data.decode("utf-8", "replace"))
                    except (ValueError, UnicodeDecodeError):
                        continue
                    if ctl.get("type") == "ended":
                        print("\r\n[share] 会话进程已退出,托管会话结束(网页端已同步结束)。\r\n")
                        return 0
    except KeyboardInterrupt:
        pass
    finally:
        if old_term is not None:
            termios.tcsetattr(0, termios.TCSADRAIN, old_term)
    return 0


if __name__ == "__main__":
    sys.exit(main())
