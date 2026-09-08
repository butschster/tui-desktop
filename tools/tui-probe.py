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


def mouse(col, row, button=0, press=True):
    """Событие мыши в формате SGR 1006 — тот, что включает композитор.

    Без этого пробник умеет только клавиатуру, и тогда оболочка обрастает
    клавиатурными путями, которых в настоящем Windows нет: интерфейс начинает
    подстраиваться под ограничение инструмента. Координаты — единичные, как на
    экране.
    """
    tail = b"M" if press else b"m"
    return b"\x1b[<%d;%d;%d" % (button, col, row) + tail


class Ordered(argparse.Action):
    """Складывает шаги в ОДИН список в том порядке, в каком их дали.

    Раньше сценарий собирался по типам — сначала все --send, потом ресайзы,
    потом клавиши, — и «щёлкнуть, потом набрать» выразить было нечем:
    получалось «набрать, потом щёлкнуть», молча и не тем.
    """

    def __call__(self, parser, namespace, value, option_string=None):
        steps = getattr(namespace, "steps", None)
        if steps is None:
            steps = []
            setattr(namespace, "steps", steps)
        steps.append((self.dest, value))


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
    parser.add_argument("--send", action=Ordered, default=[],
                        help="набрать строку (повторяемо)")
    parser.add_argument("--send-key", action=Ordered, default=[],
                        help="послать клавишу: " + ", ".join(sorted(KEYS)))
    parser.add_argument("--expect", action="append", default=[],
                        help="подстрока, которая обязана появиться на экране")
    parser.add_argument("--click", action=Ordered, default=[],
                        help="щёлкнуть мышью в COL,ROW (единичные координаты)")
    parser.add_argument("--dblclick", action=Ordered, default=[],
                        help="двойной щелчок в COL,ROW")
    parser.add_argument("--move", action=Ordered, default=[],
                        help="провести мышь в COL,ROW без нажатия (SGR 1003, кнопка 35)")
    parser.add_argument("--wheel", action=Ordered, default=[],
                        help="колёсико в COL,ROW,up|down (SGR 1006, кнопки 64 и 65)")
    parser.add_argument("--drag", action=Ordered, default=[],
                        help="перетаскивание левой кнопкой из COL1,ROW1 в COL2,ROW2: нажатие, движение по строкам, отпускание")
    parser.add_argument("--resize", action=Ordered, default=[],
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

    # Сценарий: [(момент, что послать)] в порядке, в каком шаги дали в
    # командной строке. Первый шаг — после boot.
    def point(spec, what):
        match = re.fullmatch(r"\s*(\d+)\s*,\s*(\d+)\s*", spec)
        if not match:
            parser.error(what + " задаётся как COL,ROW, получено: " + spec)
        return int(match.group(1)), int(match.group(2))

    script = []
    moment = opts.boot
    for kind, value in getattr(opts, "steps", []):
        if kind == "send":
            script.append((moment, value.encode()))
        elif kind == "send_key":
            if value not in KEYS:
                parser.error("неизвестная клавиша: " + value)
            script.append((moment, KEYS[value]))
        elif kind == "click":
            col, row = point(value, "щелчок")
            script.append((moment, mouse(col, row, press=True) + mouse(col, row, press=False)))
        elif kind == "dblclick":
            col, row = point(value, "двойной щелчок")
            # Два полных щелчка подряд одним куском: двойной определяется по
            # сроку между ними, и пауза сценария между шагами его развалила бы.
            single = mouse(col, row, press=True) + mouse(col, row, press=False)
            script.append((moment, single + single))
        elif kind == "move":
            col, row = point(value, "движение")
            # Движение без кнопки — код 35 (32 «движение» + 3 «кнопки нет»);
            # рантайм включает режим 1003, поэтому терминал шлёт его и так.
            script.append((moment, mouse(col, row, button=35, press=True)))
        elif kind == "drag":
            match = re.fullmatch(r"(\d+),(\d+),(\d+),(\d+)", value)
            if not match:
                parser.error("перетаскивание задаётся как COL1,ROW1,COL2,ROW2, получено: " + value)
            c1, r1, c2, r2 = (int(match.group(i)) for i in range(1, 5))
            # Одним куском: нажатие, движение с зажатой кнопкой (SGR: кнопка + 32)
            # по каждой промежуточной строке, отпускание в конечной точке.
            chunk = mouse(c1, r1, press=True)
            steps = max(abs(r2 - r1), abs(c2 - c1), 1)
            for i in range(1, steps + 1):
                col = c1 + (c2 - c1) * i // steps
                row = r1 + (r2 - r1) * i // steps
                chunk += mouse(col, row, button=32, press=True)
            chunk += mouse(c2, r2, press=False)
            script.append((moment, chunk))
        elif kind == "wheel":
            match = re.fullmatch(r"(\d+),(\d+),(up|down)", value)
            if not match:
                parser.error("колёсико задаётся как COL,ROW,up|down, получено: " + value)
            button = 64 if match.group(3) == "up" else 65
            # У колёсика нет отпускания: терминал шлёт только нажатие.
            script.append((moment, mouse(int(match.group(1)), int(match.group(2)), button=button, press=True)))
        elif kind == "resize":
            match = re.fullmatch(r"(\d+)x(\d+)", value)
            if not match:
                parser.error("размер задаётся как COLSxROWS, получено: " + value)
            script.append((moment, ("resize", int(match.group(1)), int(match.group(2)))))
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
