#!/usr/bin/env python3
"""Web helper release probe: does a destroyed view's WPEWebProcess exit?

Plays the ENGINE side of the helper protocol (engine/webview/WebViewProtocol.h)
over the same AF_UNIX SEQPACKET socket rn-impeller uses, so the check runs on
the real helper + the real WebKit with no RN app in between.

  webview_release_probe.py --helper <launcher> --work <dir> --url-a <url> --url-b <url>

Steps (each one prints a RELEASE line):
  1. view 1 loads url-a: the helper's container/process tree has >= 1 web process
     (instrument control: the counter can see one)
  2. view 2 loads url-b (another site): >= 2 web processes
  3. destroy view 1: the count drops by one within --settle-s, and view 2 still
     loads a page afterwards (the fix must not take the other view's process)
  4. destroy view 2: no web process left within --settle-s
Exit 0 + WEBVIEW_RELEASE_PASS, else 1 + WEBVIEW_RELEASE_FAIL <why>.
"""
import argparse
import array
import atexit
import os
import socket
import struct
import subprocess
import sys
import threading
import time

MAGIC = 0x56574E52
K_CREATE, K_LOAD, K_DESTROY, K_RELEASE_SLOT, K_QUIT = 1, 2, 12, 13, 15
K_READY, K_FRAME, K_EVENT = 101, 102, 103
HDR = struct.Struct("<IHHI")


def pack(mtype, view, *fields):
    out = bytearray(HDR.pack(MAGIC, mtype, len(fields), view))
    for f in fields:
        b = f.encode() if isinstance(f, str) else str(f).encode()
        out += struct.pack("<I", len(b)) + b
    return bytes(out)


def parse(buf):
    magic, mtype, n, view = HDR.unpack_from(buf, 0)
    if magic != MAGIC:
        return None
    off, fields = HDR.size, []
    for _ in range(n):
        (ln,) = struct.unpack_from("<I", buf, off)
        off += 4
        fields.append(buf[off:off + ln].decode(errors="replace"))
        off += ln
    return mtype, view, fields


class Link:
    def __init__(self, conn, log):
        self.conn, self.log = conn, log
        self.lock = threading.Lock()
        self.events = []  # (view, type, json)
        self.ready = threading.Event()
        self.closed = False
        threading.Thread(target=self._rx, daemon=True).start()

    def send(self, data):
        with self.lock:
            self.conn.send(data)

    def _rx(self):
        fds = array.array("i")
        while True:
            try:
                data, anc, _, _ = self.conn.recvmsg(1 << 18, socket.CMSG_LEN(fds.itemsize))
            except OSError:
                break
            if not data:
                break
            for level, ctype, cdata in anc:
                if level == socket.SOL_SOCKET and ctype == socket.SCM_RIGHTS:
                    got = array.array("i")
                    got.frombytes(cdata[: len(cdata) - (len(cdata) % got.itemsize)])
                    for fd in got:
                        os.close(fd)
            m = parse(data)
            if not m:
                continue
            mtype, view, f = m
            if mtype == K_READY:
                self.log(f"helper ready protocol={f[0] if f else '?'} webkit={f[1] if len(f) > 1 else '?'}")
                self.ready.set()
            elif mtype == K_FRAME:  # copy done at once: hand the slot back
                self.send(pack(K_RELEASE_SLOT, view, f[0], f[1]))
            elif mtype == K_EVENT and len(f) >= 2:
                self.events.append((view, f[0], f[1]))
        self.closed = True

    def wait_event(self, view, etype, since, timeout):
        end = time.time() + timeout
        while time.time() < end:
            for i in range(since, len(self.events)):
                if self.events[i][0] == view and self.events[i][1] == etype:
                    return i + 1
            time.sleep(0.05)
        return 0


def web_processes(helper_pid, container):
    """PIDs of WPEWebProcess that belong to THIS helper (docker container or process tree)."""
    if container:
        r = subprocess.run(["docker", "top", container, "-eo", "pid,args"], capture_output=True, text=True)
        if r.returncode == 0:
            return [ln.split()[0] for ln in r.stdout.splitlines()[1:] if "WPEWebProcess" in ln]
    kids, found = {}, []
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            with open(f"/proc/{p}/stat") as fh:
                ppid = int(fh.read().rsplit(")", 1)[1].split()[1])
            with open(f"/proc/{p}/cmdline", "rb") as fh:
                cmd = fh.read().replace(b"\0", b" ").decode(errors="replace")
        except OSError:
            continue
        kids.setdefault(ppid, []).append((p, cmd))
    todo = [str(helper_pid)]
    while todo:
        for pid, cmd in kids.get(int(todo.pop()), []):
            todo.append(pid)
            if "WPEWebProcess" in cmd:
                found.append(pid)
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--helper", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--url-a", required=True)
    ap.add_argument("--url-b", required=True)
    ap.add_argument("--settle-s", type=float, default=8.0)
    a = ap.parse_args()
    t0 = time.time()

    def log(msg):
        print(f"RELEASE t={time.time() - t0:6.2f} {msg}", flush=True)

    def fail(why):
        print(f"WEBVIEW_RELEASE_FAIL {why}", flush=True)
        sys.exit(1)

    os.makedirs(a.work, exist_ok=True)
    sock_path = os.path.join(a.work, "s")
    if os.path.exists(sock_path):
        os.unlink(sock_path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    srv.bind(sock_path)
    srv.listen(1)
    srv.settimeout(90)
    out = open(os.path.join(a.work, "helper.out"), "w")
    proc = subprocess.Popen([a.helper, "--socket", sock_path, "--data-dir", os.path.join(a.work, "data")],
                            stdout=out, stderr=subprocess.STDOUT)
    # tools/webhelper-docker.sh execs `docker run --name rni-webhelper-$$`: $$ is this pid.
    container = f"rni-webhelper-{proc.pid}" if a.helper.endswith("webhelper-docker.sh") else ""

    def reap():  # a FAIL exits mid-run: never leave the helper (or its container) behind
        if proc.poll() is None:
            proc.kill()
        if container:
            subprocess.run(["docker", "rm", "-f", container], capture_output=True)
    atexit.register(reap)
    try:
        conn, _ = srv.accept()
    except socket.timeout:
        proc.kill()
        fail("helper never connected")
    link = Link(conn, log)
    if not link.ready.wait(60):
        fail("no READY from the helper")

    def count():
        return len(web_processes(proc.pid, container))

    def settle(want_max, what):
        end = time.time() + a.settle_s
        n = count()
        while n > want_max and time.time() < end:
            time.sleep(0.25)
            n = count()
        log(f"{what}: web_processes={n} (want <= {want_max}) after {a.settle_s - max(0, end - time.time()):.1f}s")
        return n

    def load(view, url, since, what):
        link.send(pack(K_LOAD, view, url, ""))
        got = link.wait_event(view, "loadEnd", since, 40)
        if not got:
            fail(f"{what}: view {view} never reached loadEnd for {url}")
        return got

    link.send(pack(K_CREATE, 1, 640, 400, 1, ""))
    seen = load(1, a.url_a, 0, "step1")
    time.sleep(1.0)
    n1 = count()
    log(f"step1 view 1 loaded {a.url_a}: web_processes={n1}")
    if n1 < 1:
        fail("step1: no WPEWebProcess counted while a page is loaded (the counter is blind)")

    link.send(pack(K_CREATE, 2, 640, 400, 1, ""))
    seen = load(2, a.url_b, seen, "step2")
    time.sleep(1.0)
    n2 = count()
    log(f"step2 view 2 loaded {a.url_b}: web_processes={n2}")
    if n2 < 2:
        fail(f"step2: two views on two sites but web_processes={n2}")

    link.send(pack(K_DESTROY, 1))
    n3 = settle(n2 - 1, "step3 destroyed view 1")
    if n3 > n2 - 1:
        fail(f"step3: view 1's web process still alive {a.settle_s}s after destroy ({n3} of {n2})")
    seen = load(2, a.url_b + "?again", len(link.events), "step3")
    log("step3 view 2 still loads pages after view 1 went")
    if count() < 1:
        fail("step3: view 2 has no web process after view 1's destroy")

    link.send(pack(K_DESTROY, 2))
    n4 = settle(0, "step4 destroyed view 2")
    if n4 > 0:
        fail(f"step4: {n4} web process(es) still alive {a.settle_s}s after the last view's destroy")

    link.send(pack(K_QUIT, 0))
    try:
        rc = proc.wait(30)
    except subprocess.TimeoutExpired:
        proc.kill()
        rc = "timeout"
    log(f"helper exit rc={rc}")
    print(f"WEBVIEW_RELEASE_PASS views=2 peak_web_processes={n2} after_last_destroy={n4}", flush=True)


if __name__ == "__main__":
    main()
