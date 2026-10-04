#!/usr/bin/env python3
"""
JoyOS 无头自动化测试。

做法(和 Project/System/test.py 一个路子,但更清爽):
    1. QEMU 无窗口启动,-display none,monitor 挂在 unix socket 上
    2. 通过 monitor 的 `xp` 命令把 VGA 文本缓冲(0xB8000)读回来
    3. 把"字符 + 颜色"两字节一对拆开,还原成 25 行文字去断言
    4. 需要交互的用例用 monitor 的 `sendkey` 注入按键(阶段 4/5 会用到)

退出码 0 = 全过。失败时会把整屏打出来,方便看卡在哪。
"""
import os
import re
import socket
import subprocess
import sys
import tempfile
import time

COLS, ROWS = 80, 25
VGA = 0xB8000


class Monitor:
    def __init__(self, sock_path: str, timeout: float = 10.0):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(timeout)
        deadline = time.time() + timeout
        while True:
            try:
                self.s.connect(sock_path)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if time.time() > deadline:
                    raise RuntimeError("连不上 QEMU monitor")
                time.sleep(0.1)
        self.buf = b""
        time.sleep(0.2)
        self._drain()

    def _drain(self):
        self.s.settimeout(0.3)
        try:
            while True:
                chunk = self.s.recv(65536)
                if not chunk:
                    break
                self.buf += chunk
        except socket.timeout:
            pass
        finally:
            self.s.settimeout(10.0)

    def cmd(self, line: str, wait: float = 0.4) -> str:
        self.buf = b""
        self.s.sendall((line + "\n").encode())
        time.sleep(wait)
        try:
            while True:
                chunk = self.s.recv(65536)
                if not chunk:
                    break
                self.buf += chunk
        except socket.timeout:
            pass
        return self.buf.decode("utf-8", "replace")

    def sendkey(self, key: str):
        """只发不等 —— sendkey 没有回显,等就是白等"""
        self.s.sendall(f"sendkey {key}\n".encode())
        time.sleep(0.05)

    def type_text(self, text: str, delay: float = 0.06):
        for ch in text:
            self.sendkey(KEYMAP.get(ch, ch))
            time.sleep(delay)

    def screendump(self, path: str = "build/_shot.ppm"):
        """抓一张像素图(图形模式下的断言要靠它)"""
        import os
        from PIL import Image
        if os.path.exists(path):
            os.unlink(path)
        self.cmd(f"screendump {path}", wait=1.5)
        return Image.open(path).convert("RGB")

    def screen(self) -> list[str]:
        """读 0xB8000 还原成 25 行文字"""
        out = self.cmd(f"xp /{COLS * ROWS * 2}xb 0x{VGA:x}", wait=0.5)
        cells = []
        for line in out.splitlines():
            if ":" not in line:
                continue
            body = line.split(":", 1)[1]
            body = body.split("'")[0]              # 丢掉后面的 ASCII 提示
            for tok in re.findall(r"0x([0-9a-fA-F]{2})", body):
                cells.append(int(tok, 16))
        chars = cells[0::2]                        # 每格:字符 + 颜色
        rows = []
        for r in range(ROWS):
            chunk = chars[r * COLS:(r + 1) * COLS]
            rows.append("".join(chr(c) if 32 <= c < 127 else " " for c in chunk).rstrip())
        return rows


# ---------------------------------------------------------------------------
#  图形模式下的断言:屏幕上没有"字符码"可读了,只能比像素。
#  好在字形是我们自己的字库(font/font-joyf.bin),可以在 Python 里用同样的位运算
#  把期望的文字渲染成"有墨/无墨"网格,再去截图里找这个图案 —— 找到了就说明
#  屏幕上确实显示着这段文字(不看颜色,只看形状)。
# ---------------------------------------------------------------------------
FONT_PATH = "font/font-joyf.bin"


def load_font(path: str = FONT_PATH) -> dict:
    import struct
    data = open(path, "rb").read()
    if data[:4] != b"JOYF":
        raise ValueError(f"{path} 不是 JOYF 字库")
    _ver, count, data_off = struct.unpack_from("<III", data, 4)
    glyphs = {}
    for i in range(count):
        cp, w, h, _pad, off = struct.unpack_from("<IBBHI", data, 16 + i * 12)
        size = (w // 8) * h
        glyphs[cp] = (w, h, data[data_off + off: data_off + off + size])
    return glyphs


def render_text(text: str, glyphs: dict):
    """按终端的排版规则(8 宽/16 宽混排)渲染成 0/1 网格"""
    cells = []
    for ch in text:
        g = glyphs.get(ord(ch))
        if g is None:
            return None
        cells.append(g)
    width = sum(w for w, _, _ in cells)
    grid = [[0] * width for _ in range(16)]
    x = 0
    for w, h, raw in cells:
        stride = w // 8
        for y in range(h):
            for bx in range(w):
                if (raw[y * stride + bx // 8] >> (7 - bx % 8)) & 1:
                    grid[y][x + bx] = 1
        x += w
    return grid


def image_ink_rows(img):
    px = img.load()
    W, H = img.size
    return [bytes(1 if sum(px[x, y]) > 90 else 0 for x in range(W)) for y in range(H)]


def find_text(img, text: str, glyphs: dict, ink_rows=None) -> bool:
    target = render_text(text, glyphs)
    if target is None:
        return False
    rows = ink_rows if ink_rows is not None else image_ink_rows(img)
    H, W = len(rows), len(rows[0])
    th, tw = len(target), len(target[0])
    trows = [bytes(r) for r in target]
    anchor = next((i for i, r in enumerate(trows) if any(r)), 0)
    ta = trows[anchor]
    for y0 in range(0, H - th + 1):
        line = rows[y0 + anchor]
        pos = line.find(ta)
        while pos >= 0:
            if pos + tw <= W and all(rows[y0 + y][pos:pos + tw] == trows[y] for y in range(th)):
                return True
            pos = line.find(ta, pos + 1)
    return False


KEYMAP = {
    " ": "spc", ".": "dot", ",": "comma", "/": "slash", ";": "semicolon",
    "-": "minus", "=": "equal", "'": "apostrophe", "\n": "ret",
}


def report(results) -> int:
    """results = [(名字, 是否通过, 期望描述)] → 打勾/打叉,返回退出码"""
    failed = []
    for name, ok, want in results:
        if ok:
            print(f"  ✅ {name}")
        else:
            print(f"  ❌ {name}  —— 期望: {want}")
            failed.append(name)
    print()
    if failed:
        print(f"❌ {len(failed)} 项失败: {', '.join(failed)}")
        return 1
    print("✅ 全部通过")
    return 0


def main() -> int:
    argv = sys.argv[1:]
    dump_only = "--dump" in argv            # 只把屏幕打出来,不做断言(调试用)
    as_hdd = "--hda" in argv                # 当硬盘挂载(BIOS 的 LBA/EDD 走这条路)
    fault_mode = "--fault" in argv          # 故意除零的镜像:应该出现 panic 屏
    pgfault_mode = "--pgfault" in argv      # 故意野指针的镜像:应该出现页错误 + CR2
    kbd_mode = "--kbd" in argv              # 键盘测试:用 monitor 的 sendkey 打字,看回显
    shell_mode = "--shell" in argv          # shell 命令测试
    argv = [a for a in argv
            if a not in ("--dump", "--hda", "--fault", "--pgfault", "--kbd", "--shell")]
    img = argv[0] if argv else "build/joyos.img"
    if not os.path.exists(img):
        print(f"❌ 找不到镜像 {img}(先 make)")
        return 2

    sock = os.path.join(tempfile.gettempdir(), f"joyos-mon-{os.getpid()}.sock")
    if os.path.exists(sock):
        os.unlink(sock)

    # 显式写 format=raw:不然 QEMU 会警告"自动探测格式有风险",还可能拒绝对块 0 写入
    drive = ([f"-drive", f"file={img},format=raw,if=ide,index=0", "-boot", "c"] if as_hdd
             else [f"-drive", f"file={img},format=raw,if=floppy", "-boot", "a"])
    qemu = subprocess.Popen(
        ["qemu-system-i386", *drive,
         "-display", "none", "-no-reboot",
         "-monitor", f"unix:{sock},server,nowait"],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
    )

    failures = []
    try:
        mon = Monitor(sock, timeout=15)
        time.sleep(2.0)                        # 等它启动完

        if qemu.poll() is not None:
            err = qemu.stderr.read().decode("utf-8", "replace")[:400]
            print(f"❌ QEMU 启动就退出了(退出码 {qemu.returncode})\n{err}")
            return 1

        # ---- 判断是文本模式还是图形模式:图形模式下读 0xB8000 没有意义 ----
        shot = mon.screendump()
        graphics = shot.size != (720, 400)
        glyphs = load_font() if graphics else None
        ink = image_ink_rows(shot) if graphics else None

        def has(needle: str) -> bool:
            """屏幕上有没有这段文字(图形模式比像素,文本模式比字符码)"""
            if graphics:
                return find_text(shot, needle, glyphs, ink)
            return needle in "\n".join(mon.screen())

        def rescan():
            """重新抓一次屏幕(敲完键/命令之后用)"""
            nonlocal shot, ink
            shot = mon.screendump()
            ink = image_ink_rows(shot) if graphics else None

        screen = mon.screen() if not graphics else []
        text = "\n".join(screen)
        print("=== 屏幕内容 ===")
        for i, line in enumerate(screen):
            if line:
                print(f"  {i:2d}| {line}")
            if i > 12 and not any(screen[i:]):
                break
        print("================\n")

        if dump_only:
            if graphics:
                shot.save("build/screen.png")
                print(f"(图形模式 {shot.size[0]}×{shot.size[1]},已存 build/screen.png)")
            return 0

        if kbd_mode:
            # ---- 键盘:靠 monitor 的 sendkey 真按键,再抓屏看回显 ----
            results = []
            mon.type_text("hello")                  # 普通字母
            time.sleep(0.3)
            mon.sendkey("shift-1")                  # Shift 组合键 → '!'
            time.sleep(0.6)
            rescan()
            results.append(("键入回显", has("hello!"), "'hello!' 出现在屏幕上"))
            results.append(("Shift 翻译", has("hello!"), "Shift+1 应该是 '!'"))

            mon.sendkey("ret")                      # 回车换行
            time.sleep(0.4)
            mon.type_text("abc")                    # 打字
            time.sleep(0.3)
            mon.sendkey("backspace")                # 退格
            time.sleep(0.3)
            mon.type_text("d")                      # 再打一个字
            time.sleep(0.5)
            rescan()
            results.append(("退格删掉 c", has("abd") and not has("abc"),
                            "屏幕上应该是 'abd' 而不是 'abc'"))
            return report(results)

        mode = ("boot disk: LBA (EDD multi-sector read)" if as_hdd
                else "boot disk: CHS fallback (BIOS has no LBA)")
        print(f'(模式: {"图形 VBE" if graphics else "VGA 文本"})')
        if shell_mode:
            # ---- shell:真敲命令,看输出 ----
            results = []

            def run(line, wait=0.7):
                mon.type_text(line)
                mon.sendkey("ret")
                time.sleep(wait)
                rescan()

            run("help")
            results.append(("help 列出命令", has("show this list") and has("page <hex>"),
                            "help 输出里有 show this list / page <hex>"))

            run("echo hello world")
            results.append(("echo 原样打回", has("hello world"), "hello world"))

            run("info")
            results.append(("info 有 CR0/CR3", has("CR0 = 0x") and has("CR3 = 0x"), "CR0/CR3"))
            results.append(("info 有 IDT 基址", has("base = 0x"), "IDT base"))

            run("page 0x400000")
            results.append(("page 查到映射", has("0x00100000") and has("present"),
                            "0x00100000 + present"))

            run("page 0x800000")
            results.append(("page 报未映射", has("PDE not present"), "PDE not present"))

            run("badcommand")
            results.append(("未知命令有提示", has("unknown command"), "unknown command"))

            # ---- 滚屏:连敲 30 行,开机那些字应该被顶掉 ----
            for i in range(30):
                mon.type_text(f"echo n{i}")
                mon.sendkey("ret")
                time.sleep(0.12)
            time.sleep(0.6)
            rescan()
            results.append(("滚屏生效", not has("JoyOS - stage 5") and has("echo n29"),
                            "开机标题被顶出屏幕、最后一行还在"))

            # ---- 清屏 ----
            run("clear")
            results.append(("clear 清屏", not has("JoyOS - stage 5") and not has("echo n29"),
                            "屏幕上只剩提示符"))

            # ---- 中文(图形模式才画得出来:直接往帧缓冲 blit 16×16 点阵)----
            run("zh", wait=1.0)
            results.append(("中文显示", has("你好，世界！"), "你好，世界！"))
            results.append(("中文长句", has("点阵字库来自"), "点阵字库来自"))
            return report(results)

        if fault_mode:
            # 故意除零的镜像:光看"异常处理有没有真的接住"
            checks = [
                ("panic 标题",      "*** KERNEL PANIC ***"),
                ("异常号 + 名字",   "EXCEPTION 00: divide error"),
                ("错误码",          "error code = 0x00000000"),
                ("故障指令地址",    "EIP = 0x"),
                ("CS / EFLAGS",     "CS = 0x00000008"),
                ("停机提示",        "system halted"),
            ]
        elif pgfault_mode:
            # shell 里敲 fault:访问 4 MiB 之外 → 14 号页错误,CR2 应记下那个地址
            mon.type_text("fault")
            mon.sendkey("ret")
            time.sleep(1.0)
            rescan()
            checks = [
                ("panic 标题",      "*** KERNEL PANIC ***"),
                ("页错误 + 名字",   "EXCEPTION 0E: page fault"),
                ("CR2 = 出错地址",  "CR2 (faulting address) = 0x00800000"),
                ("故障指令地址",    "EIP = 0x"),
                ("停机提示",        "system halted"),
            ]
        else:
            checks = [
                ("标题",            "JoyOS - stage 5"),
                ("保护模式链路",    "bootloader -> protected mode -> kernel"),
                ("内核区大小(多扇区)", "kernel area: 128 sectors = 65536 bytes"),
                ("kmain 地址",      "kmain at 0x00010000"),
                ("GDT 生效(DS=0x10)", "DS = 0x00000010"),
                ("读盘方式",         mode),
                ("IDT 装载",        "IDT: 256 vectors installed"),
                ("分页开启",        "paging: CR0.PG=1"),
                ("键盘就绪",        "keyboard: PIC remapped to 0x20, IRQ1 enabled"),
                ("阶段完成提示",    "OK - stage 5"),
                ("shell 就绪",      'type "help" for commands.'),
            ]
        for name, needle in checks:
            if has(needle):
                print(f"  ✅ {name}")
            else:
                print(f"  ❌ {name}  —— 屏幕上找不到: {needle!r}")
                failures.append(name)

    finally:
        qemu.terminate()
        try:
            qemu.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qemu.kill()
        if os.path.exists(sock):
            os.unlink(sock)

    print()
    if failures:
        print(f"❌ {len(failures)} 项失败: {', '.join(failures)}")
        return 1
    print("✅ 全部通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
