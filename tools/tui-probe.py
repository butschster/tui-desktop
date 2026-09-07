#!/usr/bin/env python3
"""Пробник для TUI: запускает команду в настоящем PTY и снимает экран текстом.

Тот же смысл, что у tools/probe.mjs для браузера: полноэкранную программу
нельзя проверить, посмотрев на её код или на код возврата. `wippy run tui`
без настоящего терминала не запустится вовсе, а запущенный пишет не строки,
а поток ANSI с абсолютным позиционированием.

Пробник даёт PTY заданного размера, печатает по сценарию, и разбирает поток
в сетку символов. Разбирает ровно то, что пишет surface рантайма:
    \\x1b[<row>;<col>H  текст  \\x1b[0m\\x1b[K
плюс переключение альтернативного экрана и синхронизацию кадра, которые на
содержимое не влияют.

    python3 tools/tui-probe.py --cols 100 --rows 30 -- wippy run tui
    python3 tools/tui-probe.py --send 'echo probe-ok' --send-key enter -- wippy run tui
"""

import argparse
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

CSI = re.compile(rb"\x1b\[([0-9;?]*)([A-Za-z])")

KEYS = {
    "enter": b"\r",
    "tab": b"\t",
    "esc": b"\x1b",
    "space": b" ",
    "backspace": b"\x7f",
    "up": b"\x1b[A",
    "down": b"\x1b[B",
    "right": b"\x1b[C",
    "left": b"\x1b[D",
    "ctrl+q": b"\x11",
    "ctrl+c": b"\x03",
    "ctrl+d": b"\x04",
}


class Screen:
    """Минимальный экран: позиционирование, печать, стирание до конца строки."""

    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.grid = [[" "] * cols for _ in range(rows)]
        self.x = self.y = 0

    def _put(self, text):
        for ch in text:
            if ch == "\r":
                self.x = 0
            elif ch == "\n":
                self.y = min(self.y + 1, self.rows - 1)
            elif ch == "\b":
                self.x = max(0, self.x - 1)
            elif ch >= " ":
                if self.x < self.cols and self.y < self.rows:
                    self.grid[self.y][self.x] = ch
                self.x += 1

    def feed(self, data):
        pos = 0
        while pos < len(data):
            match = CSI.search(data, pos)
            if not match:
                self._put(data[pos:].decode("utf-8", "replace"))
                return
            if match.start() > pos:
                self._put(data[pos:match.start()].decode("utf-8", "replace"))
            params, final = match.group(1), match.group(2)
            self._apply(params, final)
            pos = match.end()

    def _apply(self, params, final):
        args = [int(p) for p in params.split(b";") if p.isdigit()]
        if final == b"H":
            row = args[0] if len(args) > 0 else 1
            col = args[1] if len(args) > 1 else 1
            self.y = max(0, min(self.rows - 1, row - 1))
            self.x = max(0, min(self.cols - 1, col - 1))
        elif final == b"K":
            mode = args[0] if args else 0
            if self.y < self.rows:
                start = self.x if mode == 0 else 0
                end = self.cols if mode in (0, 2) else self.x + 1
                for col in range(start, min(end, self.cols)):
                    self.grid[self.y][col] = " "
        elif final == b"J" and args and args[0] == 2:
            self.grid = [[" "] * self.cols for _ in range(self.rows)]
        # SGR, режимы курсора, altscreen и синхронизация содержимого не меняют.

    def render(self):
        return "\n".join("".join(row).rstrip() for row in self.grid)


def set_size(fd, cols, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cols", type=int, default=100)
    parser.add_argument("--rows", type=int, default=30)
    parser.add_argument("--boot", type=float, default=45.0,
                        help="сколько ждать первого кадра, секунд")
    parser.add_argument("--settle", type=float, default=2.0,
                        help="пауза между действиями сценария, секунд")
    parser.add_argument("--tail", type=float, default=None,
                        help="сколько ждать после последнего шага, секунд "
                             "(по умолчанию — одна пауза; выход всего рантайма "
                             "занимает заметно дольше)")
    parser.add_argument("--send", action="append", default=[],
                        help="набрать строку (повторяемо)")
    parser.add_argument("--send-key", action="append", default=[],
                        help="послать клавишу: " + ", ".join(sorted(KEYS)))
    parser.add_argument("--expect", action="append", default=[],
                        help="подстрока, которая обязана появиться на экране")
    parser.add_argument("--resize", action="append", default=[],
                        help="сменить размер терминала на COLSxROWS (повторяемо)")
    parser.add_argument("--raw", help="файл для сырого потока")
    parser.add_argument("cmd", nargs=argparse.REMAINDER)
    opts = parser.parse_args()

    cmd = opts.cmd[1:] if opts.cmd and opts.cmd[0] == "--" else opts.cmd
    if not cmd:
        parser.error("команда не задана")

    child, fd = pty.fork()
    if child == 0:
        os.execvp(cmd[0], cmd)

    set_size(fd, opts.cols, opts.rows)
    screen = Screen(opts.cols, opts.rows)
    raw = open(opts.raw, "wb") if opts.raw else None

    # Сценарий: [(момент, что послать)]. Первый шаг — после boot.
    script = []
    moment = opts.boot
    for text in opts.send:
        script.append((moment, text.encode()))
        moment += opts.settle
    for spec in opts.resize:
        match = re.fullmatch(r"(\d+)x(\d+)", spec)
        if not match:
            parser.error("размер задаётся как COLSxROWS, получено: " + spec)
        script.append((moment, ("resize", int(match.group(1)), int(match.group(2)))))
        moment += opts.settle
    for key in opts.send_key:
        if key not in KEYS:
            parser.error("неизвестная клавиша: " + key)
        script.append((moment, KEYS[key]))
        moment += opts.settle

    deadline = time.time() + moment + (opts.settle if opts.tail is None else opts.tail)
    started = time.time()
    step = 0
    bytes_seen = 0

    try:
        while time.time() < deadline:
            if step < len(script) and time.time() - started >= script[step][0]:
                action = script[step][1]
                if isinstance(action, tuple):
                    # Ресайз: ядро само шлёт SIGWINCH группе процессов терминала,
                    # а экран пересобираем под новый размер.
                    _, cols, rows = action
                    set_size(fd, cols, rows)
                    screen = Screen(cols, rows)
                    opts.cols, opts.rows = cols, rows
                else:
                    os.write(fd, action)
                step += 1
            ready, _, _ = select.select([fd], [], [], 0.2)
            if not ready:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            bytes_seen += len(chunk)
            if raw:
                raw.write(chunk)
            screen.feed(chunk)
    finally:
        # Сам ли вышел — единственный способ отличить корректный выход по
        # ctrl+q от программы, которую пришлось гасить снаружи.
        exited_on_its_own, exit_code = False, None
        try:
            done_pid, status = os.waitpid(child, os.WNOHANG)
            if done_pid == child:
                exited_on_its_own = True
                exit_code = os.waitstatus_to_exitcode(status)
        except ChildProcessError:
            exited_on_its_own = True
        if not exited_on_its_own:
            try:
                os.kill(child, signal.SIGTERM)
            except ProcessLookupError:
                pass
        os.close(fd)
        if raw:
            raw.close()

    print("=" * opts.cols)
    print(screen.render())
    print("=" * opts.cols)
    print(f"[probe] прочитано байт: {bytes_seen}, шагов сценария: {step}/{len(script)}")
    if exited_on_its_own:
        print(f"[probe] программа завершилась сама, код {exit_code}")
    else:
        print("[probe] программа не завершилась — пришлось послать SIGTERM")

    rendered = screen.render()
    failed = [needle for needle in opts.expect if needle not in rendered]
    for needle in opts.expect:
        print(f"[probe] {'НЕТ ' if needle in failed else 'есть'}: {needle!r}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
