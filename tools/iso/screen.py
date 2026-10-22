# SPDX-License-Identifier: GPL-3.0-or-later
"""CI only: the screen of a terminal, as far as the installer and the programs it hands the terminal to
use it (docs/ISO.md): text at the cursor, the cursor moved (CSI H and f, s and u), the screen and the
line erased (J and K), colours and styles dropped (m), lines that scroll. Anything else is ignored. It
tells a test which screen of the installer is shown, and what is on it."""
import re

CSI = re.compile(rb"\x1b\[([0-9;?]*)([@-~])")
OSC = re.compile(rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


class Screen:
    def __init__(self, rows=24, cols=80):
        self.rows, self.cols = rows, cols
        self.grid = [[" "] * cols for _ in range(rows)]
        self.row = self.col = 0
        self.saved = (0, 0)
        self.pending = b""

    def feed(self, data: bytes):
        data = self.pending + data
        self.pending = b""
        i = 0
        while i < len(data):
            b = data[i]
            if b == 0x1B:
                m = CSI.match(data, i) or OSC.match(data, i)
                if m:
                    if m.re is CSI:
                        self.csi(m.group(1).decode(), m.group(2).decode())
                    i = m.end()
                    continue
                if i + 2 <= len(data) and data[i + 1] in b"()":
                    i += 3
                    continue
                if len(data) - i < 40 and (data[i + 1:i + 2] in (b"", b"[", b"]")):
                    self.pending = data[i:]  # an escape sequence that goes on in the next read
                    return
                i += 2
                continue
            if b == 0x0D:
                self.col = 0
            elif b == 0x0A:
                self.line_feed()
            elif b == 0x08:
                self.col = max(0, self.col - 1)
            elif b == 0x09:
                self.col = min(self.cols - 1, (self.col // 8 + 1) * 8)
            elif b < 0x20 or b == 0x7F:
                pass
            else:
                n = 1 if b < 0x80 else 2 if b >> 5 == 0b110 else 3 if b >> 4 == 0b1110 else 4
                if len(data) - i < n:
                    self.pending = data[i:]
                    return
                self.put(data[i:i + n].decode("utf-8", "replace"))
                i += n
                continue
            i += 1

    def put(self, ch):
        if self.col >= self.cols:
            self.col = 0
            self.line_feed()
        self.grid[self.row][self.col] = ch
        self.col += 1

    def line_feed(self):
        if self.row == self.rows - 1:
            self.grid.pop(0)
            self.grid.append([" "] * self.cols)
        else:
            self.row += 1

    def csi(self, args, final):
        n = [int(x) if x.isdigit() else 0 for x in args.lstrip("?").split(";")]
        a = n[0] if n and n[0] else 1
        if final in "Hf":
            r = n[0] if n and n[0] else 1
            c = n[1] if len(n) > 1 and n[1] else 1
            self.row, self.col = min(r, self.rows) - 1, min(c, self.cols) - 1
        elif final == "A":
            self.row = max(0, self.row - a)
        elif final == "B":
            self.row = min(self.rows - 1, self.row + a)
        elif final == "C":
            self.col = min(self.cols - 1, self.col + a)
        elif final == "D":
            self.col = max(0, self.col - a)
        elif final == "G":
            self.col = min(self.cols, a) - 1
        elif final == "d":
            self.row = min(self.rows, a) - 1
        elif final == "J":
            mode = n[0] if n else 0
            if mode == 2:
                self.grid = [[" "] * self.cols for _ in range(self.rows)]
            elif mode == 0:
                self.grid[self.row][self.col:] = [" "] * (self.cols - self.col)
                for r in range(self.row + 1, self.rows):
                    self.grid[r] = [" "] * self.cols
        elif final == "K":
            mode = n[0] if n else 0
            if mode == 2:
                self.grid[self.row] = [" "] * self.cols
            elif mode == 0:
                self.grid[self.row][self.col:] = [" "] * (self.cols - self.col)
        elif final == "s":
            self.saved = (self.row, self.col)
        elif final == "u":
            self.row, self.col = self.saved

    def lines(self):
        return ["".join(r).rstrip() for r in self.grid]

    def text(self):
        return "\n".join(self.lines())
