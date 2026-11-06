#!/usr/bin/env python3
"""Minimal RFC 6455 echo server for gates (stdlib only, Mac-runnable).

  ws_echo_server.py <portfile>   binds 127.0.0.1:0, writes the port to <portfile>,
                                 echoes every text/binary frame, answers ping and close.
Each event is printed as one line (WS_ECHO ...) so a gate can assert the server side too.
"""
import base64
import hashlib
import socket
import struct
import sys
import threading

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def log(msg):
    print("WS_ECHO " + msg, flush=True)


def recv_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def send_frame(conn, opcode, payload):
    head = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        head += bytes([n])
    elif n < 65536:
        head += bytes([126]) + struct.pack(">H", n)
    else:
        head += bytes([127]) + struct.pack(">Q", n)
    conn.sendall(head + payload)


def handle(conn, addr):
    try:
        req = b""
        while b"\r\n\r\n" not in req:
            chunk = conn.recv(4096)
            if not chunk:
                return
            req += chunk
        lines = req.split(b"\r\n")
        path = lines[0].split(b" ")[1].decode() if len(lines[0].split(b" ")) > 1 else "?"
        headers = {}
        for ln in lines[1:]:
            if b":" in ln:
                k, v = ln.split(b":", 1)
                headers[k.strip().lower()] = v.strip()
        key = headers.get(b"sec-websocket-key")
        if not key:
            conn.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            return
        accept = base64.b64encode(hashlib.sha1(key + GUID).digest())
        conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                     b"Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
        log(f"open path={path}")
        while True:
            b0, b1 = recv_exact(conn, 2)
            opcode = b0 & 0x0F
            masked = b1 & 0x80
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", recv_exact(conn, 2))[0]
            elif n == 127:
                n = struct.unpack(">Q", recv_exact(conn, 8))[0]
            mask = recv_exact(conn, 4) if masked else b"\0\0\0\0"
            data = bytes(c ^ mask[i % 4] for i, c in enumerate(recv_exact(conn, n)))
            if opcode in (1, 2):
                log(f"recv opcode={opcode} masked={1 if masked else 0} data={data.decode('utf-8', 'replace')}")
                send_frame(conn, opcode, data)
            elif opcode == 9:
                send_frame(conn, 10, data)
            elif opcode == 8:
                code = struct.unpack(">H", data[:2])[0] if len(data) >= 2 else 1005
                log(f"close code={code}")
                send_frame(conn, 8, data[:2])
                return
    except (EOFError, ConnectionError, OSError):
        log("eof")
    finally:
        conn.close()


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(8)
    port = srv.getsockname()[1]
    with open(sys.argv[1], "w") as f:
        f.write(str(port))
    log(f"listening port={port}")
    while True:
        conn, addr = srv.accept()
        threading.Thread(target=handle, args=(conn, addr), daemon=True).start()


if __name__ == "__main__":
    main()
