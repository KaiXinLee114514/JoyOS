#!/usr/bin/env python3
"""
把一段文字转成 JoyOS 的 "Alt 码位" 输入序列。

JoyOS 的键盘只有 US ASCII 那一套扫描码,所以中文/日文/韩文/emoji 是这么打的:
**按住左 Alt,敲十进制 Unicode 码位,松开 Alt** —— 内核把那个码位编成 UTF-8
塞进按键缓冲(见 kernel/keyboard.asm 里的 Alt 输入部分)。

这个脚本干三件事:

  1. 把一句话拆成"每个字 = Alt+多少",顺便查本地字库有没有那个字形;
  2. 给出一行可以直接照着敲的数字;
  3. 可选:连上 QEMU 的 QMP socket,把这段话直接打进正在跑的 JoyOS 里
     (`make hd` 已经把 QMP 开在 build/qmp.sock)。

用法:
    python3 tools/text2alt.py "日本語 한국어"          # 列表 + 一行数字
    python3 tools/text2alt.py --line "你好,世界"      # 只要那一行
    python3 tools/text2alt.py --decode 26085 26412    # 反着来:码位 → 字
    python3 tools/text2alt.py --file notes.txt        # 从文件里读
    python3 tools/text2alt.py --send build/qmp.sock "こんにちは"

注意:emoji 那种四字节字符也行(码位最多 6 位数字,内核就收 6 位)。
"""
import argparse
import bisect
import json
import socket
import struct
import sys
import time
import unicodedata

DEFAULT_FONT = "font/full-joyf.bin"


# ---------------------------------------------------------------------------
#  字库:JOYF 格式(见 tools/unifont2bin.py 的格式说明)
#  只读码位表,用来回答"这个字现在显示得出来吗"
# ---------------------------------------------------------------------------
def load_font(path):
    try:
        with open(path, "rb") as f:
            d = f.read()
    except OSError:
        return None
    if d[:4] != b"JOYF" or len(d) < 16:
        return None
    _ver, count, _data_off = struct.unpack("<III", d[4:16])
    return [struct.unpack("<I", d[16 + i * 12: 16 + i * 12 + 4])[0] for i in range(count)]


def in_font(cps, ch):
    """None = 没查(没给字库);True/False = 有/没有"""
    if cps is None:
        return None
    i = bisect.bisect_left(cps, ord(ch))
    return i < len(cps) and cps[i] == ord(ch)


def label(ch):
    return {" ": "(空格)", "\n": "(换行)", "\t": "(Tab)"}.get(ch, ch)


# ---------------------------------------------------------------------------
#  转换
# ---------------------------------------------------------------------------
def convert(text):
    """文字 → [(字符, 码位), ...]"""
    return [(ch, ord(ch)) for ch in text]


def show_table(pairs, cps, alt_line=True):
    print(f"{'字符':<4} {'U+':<8} {'Alt+':<8} 字库")
    for ch, cp in pairs:
        have = in_font(cps, ch)
        mark = "—" if have is None else ("有" if have else "缺 → 会显示成替换字符")
        name = unicodedata.name(ch, "") if cp > 0x7F else ""
        if len(name) > 34:
            name = name[:33] + "…"
        print(f"{label(ch):<4} U+{cp:04X}  {cp:<8} {mark}" + (f"  {name}" if name else ""))
    if alt_line:
        print()
        print("按住左 Alt,依次敲下面的数字,松开 Alt 出字:")
        print(" ".join(f"Alt+{cp}" for _ch, cp in pairs))


# ---------------------------------------------------------------------------
#  --send:直接打进正在跑的虚拟机
#  QEMU 监视器(HMP)是文本协议:发一行命令,它会回一段。
#  关键是 Alt 要"按住":sendkey alt <毫秒> 会按住那么久再松开,
#  这期间我们再敲数字,松开时内核就把码位变成一个字符。
# ---------------------------------------------------------------------------
def hmp_connect(path, timeout=10.0):
    deadline = time.time() + timeout
    last = None
    while True:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(timeout)
            s.connect(path)
            return s
        except OSError as e:
            last = e
            if time.time() > deadline:
                raise SystemExit(f"连不上 QEMU 的 QMP socket {path}:{last}\n"
                                 f"(用 make hd 起的虚拟机把 socket 开在 build/qmp.sock)")
            time.sleep(0.1)


class Qmp:
    """QEMU 的 QMP 通道:JSON 一行一条。用 input-send-event 才能真正控制
    "按下 / 松开" —— HMP 的 sendkey 只能整组按+放,没法让 Alt 一直按着。"""

    def __init__(self, path, timeout=10.0):
        self.f = hmp_connect(path, timeout).makefile("rwb")
        self.f.readline()                       # 打招呼那行 {"QMP": ...}
        self.cmd("qmp_capabilities")

    def cmd(self, name, **args):
        req = {"execute": name}
        if args:
            req["arguments"] = args
        self.f.write((json.dumps(req) + "\n").encode())
        self.f.flush()
        while True:                             # 事件消息要跳过,只等 return/error
            line = self.f.readline()
            if not line:
                raise SystemExit("QMP 连接断了")
            msg = json.loads(line)
            if "return" in msg:
                return msg["return"]
            if "error" in msg:
                raise SystemExit(f"QMP 报错:{msg['error']}")

    def key(self, qcode, down):
        self.cmd("input-send-event", events=[{
            "type": "key",
            "data": {"down": bool(down), "key": {"type": "qcode", "data": qcode}},
        }])


def send_text(qmp, text, gap=0.02, verbose=False):
    """一个字符 = 按住 Alt → 敲十进制码位 → 松开 Alt(内核这时才把码位变成字)"""
    for ch, cp in convert(text):
        qmp.key("alt", True)
        time.sleep(gap)
        for d in str(cp):
            qmp.key(d, True)
            qmp.key(d, False)
            time.sleep(gap)
        qmp.key("alt", False)
        time.sleep(0.05 + gap)
        if verbose:
            print(f"  打进 {label(ch)} (Alt+{cp})")


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(
        description="把文字转成 JoyOS 的 Alt 码位输入序列(顺便查字库)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("用法:")[1].split("注意:")[0].strip())
    ap.add_argument("text", nargs="*", help="要转换的文字(也可以不给,用 --file)")
    ap.add_argument("--file", help="从文件读文字(UTF-8)")
    ap.add_argument("--line", action="store_true", help="只输出一行 Alt+… 序列")
    ap.add_argument("--decode", nargs="+", type=int, metavar="码位",
                    help="反着来:把十进制码位转成文字")
    ap.add_argument("--font", default=DEFAULT_FONT, help=f"字库路径(默认 {DEFAULT_FONT})")
    ap.add_argument("--no-font-check", action="store_true", help="不查字库")
    ap.add_argument("--send", metavar="QMP_SOCKET", help="连 QEMU 的 QMP socket,直接打进虚拟机")
    ap.add_argument("--gap", type=float, default=0.02, help="--send 时按键之间的间隔秒数")
    ap.add_argument("-v", "--verbose", action="store_true", help="--send 时每个字打一行进度")
    args = ap.parse_args()

    if args.decode:
        out = "".join(chr(cp) for cp in args.decode)
        print(out)
        print(" ".join(f"U+{cp:04X}" for cp in args.decode))
        return 0

    text = args.file and open(args.file, encoding="utf-8").read() or " ".join(args.text)
    if not text:
        ap.error("给点文字吧:python3 tools/text2alt.py \"日本語\"")

    pairs = convert(text)
    cps = None if args.no_font_check else load_font(args.font)

    if args.send:
        qmp = Qmp(args.send)
        print(f"→ 往 {args.send} 打 {len(pairs)} 个字符…")
        send_text(qmp, text, gap=args.gap, verbose=args.verbose)
        print("→ 打完了(屏幕上应该已经出现这些字)")
        return 0

    if args.line:
        print(" ".join(f"Alt+{cp}" for _ch, cp in pairs))
        return 0

    show_table(pairs, cps)
    if cps is not None:
        missing = [label(ch) for ch, cp in pairs if in_font(cps, ch) is False]
        if missing:
            print()
            print(f"⚠ 字库({args.font})里没有这些字形:{' '.join(missing)}")
            print("  内核会画成替换字符;要补字形就重新生成字库"
                  "(tools/mkfontsubset.py + tools/unifont2bin.py,见 font/README.md)。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
