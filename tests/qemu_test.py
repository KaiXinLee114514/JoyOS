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

        screen = mon.screen()
        text = "\n".join(screen)
        print("=== 屏幕内容 ===")
        for i, line in enumerate(screen):
            if line:
                print(f"  {i:2d}| {line}")
            if i > 12 and not any(screen[i:]):
                break
        print("================\n")

        if dump_only:
            return 0

        if kbd_mode:
            # ---- 键盘:靠 monitor 的 sendkey 真按键,再抓屏看回显 ----
            results = []
            prompts_before = sum(1 for r in mon.screen() if r.startswith(">"))
            mon.type_text("hello")                  # 普通字母
            time.sleep(0.3)
            mon.sendkey("shift-1")                  # Shift 组合键 → '!'
            time.sleep(0.6)
            text = "\n".join(mon.screen())
            results.append(("键入回显", "hello!" in text, "'hello!' 出现在屏幕上"))
            results.append(("Shift 翻译", "hello!" in text, "Shift+1 应该是 '!'"))

            mon.sendkey("ret")                      # 回车换行
            time.sleep(0.4)
            screen2 = mon.screen()
            prompts_after = sum(1 for r in screen2 if r.startswith(">"))
            results.append(("回车后新提示符", prompts_after > prompts_before,
                            "提示符行数应该变多"))

            mon.type_text("abc")                    # 打字
            time.sleep(0.3)
            mon.sendkey("backspace")                # 退格
            time.sleep(0.3)
            mon.type_text("d")                      # 再打一个字
            time.sleep(0.5)
            text2 = "\n".join(mon.screen())
            results.append(("退格删掉 c", "abd" in text2 and "abc" not in text2,
                            "屏幕上应该是 'abd' 而不是 'abc'"))
            return report(results)

        mode = ("boot disk: LBA (EDD multi-sector read)" if as_hdd
                else "boot disk: CHS fallback (BIOS has no LBA)")
        if shell_mode:
            # ---- shell:真敲命令,看输出 ----
            results = []

            def run(line, wait=0.7):
                mon.type_text(line)
                mon.sendkey("ret")
                time.sleep(wait)
                return "\n".join(mon.screen())

            t = run("help")
            results.append(("help 列出命令", "show this list" in t and "page <hex>" in t,
                            "help 输出里有 show this list / page <hex>"))

            t = run("echo hello world")
            results.append(("echo 原样打回", "hello world" in t, "hello world"))

            t = run("info")
            results.append(("info 有 CR0/CR3", "CR0 = 0x" in t and "CR3 = 0x" in t,
                            "CR0/CR3"))
            results.append(("info 有 IDT 基址", "IDT         : base = 0x" in t, "IDT base"))

            t = run("page 0x400000")
            results.append(("page 查到映射", "0x00100000" in t and "present" in t,
                            "0x00100000 + present"))

            t = run("page 0x800000")
            results.append(("page 报未映射", "PDE not present" in t, "PDE not present"))

            t = run("badcommand")
            results.append(("未知命令有提示", "unknown command" in t, "unknown command"))

            # ---- 滚屏:连敲 30 行,开机那些字应该被顶掉 ----
            for i in range(30):
                mon.type_text(f"echo n{i}")
                mon.sendkey("ret")
                time.sleep(0.12)
            time.sleep(0.5)
            t = "\n".join(mon.screen())
            results.append(("滚屏生效", "JoyOS - stage 5" not in t and "echo n29" in t,
                            "开机标题被顶出屏幕、最后一行还在"))

            # ---- 清屏 ----
            t = run("clear")
            results.append(("clear 清屏", "JoyOS - stage 5" not in t and "echo n29" not in t,
                            "屏幕上只剩提示符"))
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
            time.sleep(0.8)
            text = "\n".join(mon.screen())
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
                ("内核区大小(多扇区)", "kernel area: 64 sectors = 32768 bytes"),
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
            if needle in text:
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
