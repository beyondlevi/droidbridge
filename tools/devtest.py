#!/usr/bin/env python3
"""Drives droidbridge-server on a connected device without the Mac app.
Usage: devtest.py <jar> <test>   tests: enter, edge, clipboard"""
import socket, struct, subprocess, sys, time

ADB = "adb"
REMOTE = "/data/local/tmp/droidbridge-server.jar"
VERSION = "0.1.0"
LEFT, RIGHT, TOP, BOTTOM = 0, 1, 2, 3

def adb(*a):
    return subprocess.run([ADB, *a], capture_output=True, text=True).stdout

class Server:
    def __init__(self, jar):
        adb("push", jar, REMOTE)
        port = int(adb("forward", "tcp:0", "localabstract:droidbridge").strip())
        self.port = port
        self.proc = subprocess.Popen([ADB, "shell", f"CLASSPATH={REMOTE}", "app_process", "/", "dev.droidbridge.Main", VERSION],
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        line = self.proc.stdout.readline()
        while line and "READY" not in line:
            print("server:", line.strip()); line = self.proc.stdout.readline()
        self.s = socket.create_connection(("127.0.0.1", port))
        self.send(0x01, struct.pack(">H", 1))
        t, p = self.recv()
        assert t == 0x81, t
        v, w, h = struct.unpack(">HHH", p[:6])
        self.size = (w, h)
        print("device:", p[6:].decode(), w, h)

    def send(self, t, p=b""): self.s.sendall(struct.pack(">BI", t, len(p)) + p)
    def recv(self, timeout=None):
        self.s.settimeout(timeout)
        try:
            hdr = self._n(5)
        except socket.timeout:
            return None, None
        t, n = struct.unpack(">BI", hdr)
        return t, self._n(n)
    def _n(self, n):
        b = b""
        while len(b) < n:
            c = self.s.recv(n - len(b))
            if not c: raise EOFError
            b += c
        return b
    def mouse(self, dx, dy, buttons=0, wheel=0): self.send(0x04, struct.pack(">BhhbB", buttons, dx, dy, wheel, 0))
    def enter(self, side, ratio): self.send(0x02, struct.pack(">BH", side, int(ratio * 65535)))
    def close(self):
        self.s.close(); time.sleep(0.5)
        for line in self.proc.stdout.read().splitlines()[-15:]: print("server:", line)
        adb("forward", "--remove", f"tcp:{self.port}")

def main():
    jar, test = sys.argv[1], sys.argv[2]
    S = Server(jar)
    try:
        if test.split(":")[0] in ("enter", "edge"):
            side = {"left": LEFT, "right": RIGHT, "top": TOP, "bottom": BOTTOM}[test.split(":")[1] if ":" in test else "left"]
            for ratio in (0.1, 0.5, 0.9, 0.25, 0.75):
                t0 = time.time(); S.enter(side, ratio); S.send(0x07)
                t, _ = S.recv(5); print(f"enter side {side} {ratio}: {time.time()-t0:.2f}s (pong={t==0x84})")
                time.sleep(0.3)
        if test.startswith("edge"):
            for _ in range(40): S.mouse(8, 0); time.sleep(0.008)    # into the screen
            t, p = S.recv(0.3); print("after moving in, unexpected:", t)
            t0 = time.time(); got = None
            for i in range(400):
                S.mouse(-8, 0); time.sleep(0.008)
                t, p = S.recv(0.001)
                if t == 0x82:
                    side, r = struct.unpack(">BH", p); got = (side, r / 65535); break
            print("edge:", got, f"after {time.time()-t0:.2f}s")
        if test.startswith("type"):
            # Types dead-key sequences with the given Android layout: devtest.py <jar> type:<layout>
            layout = test.split(":", 1)[1] if ":" in test else "english_us_intl"
            S.send(0x08, layout.encode()); time.sleep(0.8)
            SHIFT = 0x02
            def key(mods, usage):
                S.send(0x05, bytes([mods, 0, usage, 0, 0, 0, 0, 0])); time.sleep(0.03)
                S.send(0x05, bytes(8)); time.sleep(0.03)
            A, C, E, O, U, SPACE, ENTER = 0x04, 0x06, 0x08, 0x12, 0x18, 0x2C, 0x28
            QUOTE, GRAVE, SIX = 0x34, 0x35, 0x23
            seqs = [("'a", [(0, QUOTE), (0, A)]), ("~a", [(SHIFT, GRAVE), (0, A)]), ("`a", [(0, GRAVE), (0, A)]),
                    ("^e", [(SHIFT, SIX), (0, E)]), ('"u', [(SHIFT, QUOTE), (0, U)]), ("'c", [(0, QUOTE), (0, C)]),
                    ("~o", [(SHIFT, GRAVE), (0, O)]), ("' space", [(0, QUOTE), (0, SPACE)])]
            for name, keys in seqs:
                for k in keys: key(*k)
                key(0, SPACE)
            key(0, ENTER)
            print("typed:", " | ".join(n for n, _ in seqs))
        if test == "clipboard":
            S.send(0x06, "droidbridge mac->android ção".encode())
            time.sleep(0.5)
            print("set; device echo (should be none):", S.recv(1)[0])
    finally:
        S.close()

main()
