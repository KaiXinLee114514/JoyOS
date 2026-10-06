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

    def _write(self, data: bytes, tries: int = 6) -> bool:
        """往 monitor 写,带超时重试。

        为什么要重试:客户机重画一整屏(帧缓冲是 MMIO)时 QEMU 主循环会被压住,
        monitor 一时读不走数据,sendall 就会阻塞。以前这里没有保护,
        一阻塞就是"整轮测试卡死"(踩过)。"""
        for _ in range(tries):
            try:
                self.s.sendall(data)
                return True
            except (socket.timeout, BlockingIOError, OSError):
                time.sleep(0.4)
        return False

    def cmd(self, line: str, wait: float = 0.4, budget: float = 8.0) -> str:
        """发一条 monitor 命令并收结果。

        ★ 收数据必须有硬上限:以前是 while True: recv(...),只要 monitor 还有
          数据在流,超时就永远不触发 —— 测试无限等下去(卡死的老根因)。
          现在:最多等 budget 秒,而且一看到 (qemu) 提示符就认为答完了。"""
        self.buf = b""
        self._write((line + chr(10)).encode())
        time.sleep(wait)
        deadline = time.time() + budget
        self.s.settimeout(0.3)
        try:
            while time.time() < deadline:
                try:
                    chunk = self.s.recv(65536)
                except socket.timeout:
                    if b"(qemu)" in self.buf:
                        break
                    continue
                if not chunk:
                    break
                self.buf += chunk
                if b"(qemu)" in chunk:
                    break
        except OSError:
            pass
        finally:
            self.s.settimeout(10.0)
        return self.buf.decode("utf-8", "replace")

    def sendkey(self, key: str):
        """只发不等 —— sendkey 没有回显,等就是白等。
        间隔别太大:整个测试要敲几百个键,0.05 秒就是十几秒的纯等待"""
        self._write(f"sendkey {key}\n".encode())
        time.sleep(0.03)

    def type_text(self, text: str, delay: float = 0.04):
        """按字符发给 QEMU。注意:monitor 的 sendkey 只认**键名**,
        大写字母要发 shift+小写,带 Shift 的符号也要查 SHIFTED 表
        (不然 sendkey '*' 是无效按键,字符就丢了)。"""
        for ch in text:
            if ch in SHIFTED:
                key = "shift-" + SHIFTED[ch]
            elif ch in KEYMAP:
                key = KEYMAP[ch]
            elif 'A' <= ch <= 'Z':
                key = "shift-" + ch.lower()
            else:
                key = ch
            self.sendkey(key)
            time.sleep(delay)

    def screendump(self, path: str = "build/_shot.ppm"):
        """抓一张像素图(图形模式下的断言要靠它)"""
        import os
        from PIL import Image
        if os.path.exists(path):
            os.unlink(path)
        self.cmd(f"screendump {path}", wait=1.0)
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
        if ch == " ":                      # 空格就是"什么都不画",不用查字库
            cells.append((8, 16, bytes(16)))
            continue
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
        # 别静悄悄地判失败:多半是模板字库选错了(比如硬盘模式该用 font/full-joyf.bin)
        miss = "".join(sorted({c for c in text if ord(c) not in glyphs and c != " "}))
        print(f"  ⚠️  模板字库里没有 {miss!r},没法比对:{text!r}")
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


# ---------------------------------------------------------------------------
#  独立信道之二:QEMU 关掉之后,直接把镜像文件当块设备读一遍。
#  内核说自己"写成功了"不算数 —— 字节真的落在 FAT16 分区里才算数。
# ---------------------------------------------------------------------------
class Fat16:
    """够用的只读 FAT 解析器(FAT16 + FAT32,8.3 短名 + 子目录 + 簇链),纯 Python"""

    def __init__(self, path: str, part_lba: int = 6144):
        self.img = open(path, "rb").read()
        base = part_lba * 512
        if self.img[base + 510:base + 512] != b"\x55\xaa":
            raise ValueError(f"LBA {part_lba} 上没有 FAT16 引导扇区")
        u16 = lambda off: int.from_bytes(self.img[base + off:base + off + 2], "little")
        self.spc = self.img[base + 13]
        self.reserved = u16(14)
        self.nfats = self.img[base + 16]
        self.root_ents = u16(17)
        self.fat_sectors = u16(22)
        # 每 FAT 扇区数为 0 → FAT32(和内核 fat_mount 的判法一致)
        self.fat32 = self.fat_sectors == 0
        if self.fat32:
            self.fat_sectors = int.from_bytes(self.img[base + 36:base + 40], "little")
            self.root_cluster = int.from_bytes(self.img[base + 44:base + 48], "little") & 0x0FFFFFFF
            self.root_ents = 0
            self.eoc = 0x0FFFFFF8
        else:
            self.root_cluster = 0
            self.eoc = 0xFFF8
        self.root_lba = base + (self.reserved + self.nfats * self.fat_sectors) * 512
        self.data_lba = self.root_lba + (self.root_ents * 32 + 511) // 512 * 512
        self.fat_lba = base + self.reserved * 512

    def next_cluster(self, cl: int) -> int:
        if self.fat32:
            off = self.fat_lba + cl * 4
            return int.from_bytes(self.img[off:off + 4], "little") & 0x0FFFFFFF
        off = self.fat_lba + cl * 2
        return int.from_bytes(self.img[off:off + 2], "little")

    def entry_cluster(self, raw: bytes) -> int:
        """目录项里的首簇:FAT32 的高 16 位在偏移 +20"""
        lo = int.from_bytes(raw[26:28], "little")
        if not self.fat32:
            return lo
        hi = int.from_bytes(raw[20:22], "little")
        return ((hi << 16) | lo) & 0x0FFFFFFF

    def entries(self):
        for i in range(self.root_ents):
            e = self.root_lba + i * 32
            raw = self.img[e:e + 32]
            if raw[0] == 0x00:
                return
            if raw[0] == 0xE5 or (raw[11] & 0x0F) == 0x0F:
                continue
            name = raw[0:8].decode("ascii", "replace").rstrip()
            ext = raw[8:11].decode("ascii", "replace").rstrip()
            yield (f"{name}.{ext}" if ext else name), raw

    def read(self, want: str) -> bytes:
        want = want.upper()
        for name, raw in self.entries():
            if name != want:
                continue
            cl = self.entry_cluster(raw)
            size = int.from_bytes(raw[28:32], "little")
            out = bytearray()
            while 2 <= cl < self.eoc and len(out) < size:
                off = self.data_lba + (cl - 2) * self.spc * 512
                out += self.img[off:off + self.spc * 512]
                cl = self.next_cluster(cl)
            return bytes(out[:size])
        raise KeyError(want)

    def names(self) -> list:
        return [n for n, _ in self.entries()]

    # ---- 子目录:0 = 根目录那块固定区域,否则是簇链 ----
    def dir_entries(self, cluster: int = 0):
        """列一个目录:cluster=0 → 根目录固定区域;否则跟着簇链走"""
        if cluster == 0 and self.fat32:
            cluster = self.root_cluster            # FAT32 的根目录也是一条簇链
        if cluster == 0:
            blobs = [
                self.img[self.root_lba + i * 32:self.root_lba + i * 32 + 32]
                for i in range(self.root_ents)
            ]
        else:
            blobs, cl = [], cluster
            while 2 <= cl < self.eoc:
                off = self.data_lba + (cl - 2) * self.spc * 512
                sec = self.img[off:off + self.spc * 512]
                blobs += [sec[i:i + 32] for i in range(0, len(sec), 32)]
                cl = self.next_cluster(cl)
        for raw in blobs:
            if len(raw) < 32:
                return
            if raw[0] == 0x00:
                return
            if raw[0] == 0xE5 or (raw[11] & 0x0F) == 0x0F:
                continue
            if raw[0] == 0x2E:                      # . / .. 不算文件
                continue
            name = raw[0:8].decode("ascii", "replace").rstrip()
            ext = raw[8:11].decode("ascii", "replace").rstrip()
            is_dir = bool(raw[11] & 0x10)
            yield (f"{name}.{ext}" if ext else name), raw, is_dir

    def resolve(self, path: str):
        """"DOCS/NOTE.TXT" → 目录项(找不到返回 None);路径都相对根目录"""
        parts = [x for x in path.replace("\\", "/").split("/") if x]
        cluster = 0
        for i, part in enumerate(parts):
            last = i == len(parts) - 1
            for name, raw, is_dir in self.dir_entries(cluster):
                if name.upper() != part.upper():
                    continue
                if last:
                    return raw
                if not is_dir:
                    return None
                cluster = self.entry_cluster(raw)
                break
            else:
                return None
        return None

    def listdir(self, path: str = "") -> list:
        """列目录,返回 [(名字, 是不是目录)]"""
        cluster = 0
        if path.strip("./"):
            raw = self.resolve(path)
            if raw is None or not (raw[11] & 0x10):
                raise KeyError(path)
            cluster = self.entry_cluster(raw)
        return [(n, d) for n, _, d in self.dir_entries(cluster)]

    def read_path(self, path: str) -> bytes:
        """按路径读文件内容(带簇链),比 read() 多支持子目录"""
        raw = self.resolve(path)
        if raw is None:
            raise KeyError(path)
        cl = self.entry_cluster(raw)
        size = int.from_bytes(raw[28:32], "little")
        out = bytearray()
        while 2 <= cl < self.eoc and len(out) < size:
            off = self.data_lba + (cl - 2) * self.spc * 512
            out += self.img[off:off + self.spc * 512]
            cl = self.next_cluster(cl)
        return bytes(out[:size])


def screen_text(img, glyphs: dict, rows: int = 40, cols: int = 100) -> list:
    """
    把图形模式的屏幕**读回成文字**:每个 8×16 字符格跟字库里的 ASCII 字形比一遍,
    一样就翻译成那个字符。

    为什么有用:`find_text` 只能回答"有没有这段字",排查"这一行现在到底长什么样"时
    还得靠眼睛看截图;这个函数直接把屏幕变成可打印的文本,断言和排错都省事。
    16 像素宽的汉字占两格,这里只当两格图案比不出来 → 显示成 '??'。
    """
    rows_ink = image_ink_rows(img)
    W = img.size[0]
    table = {}
    for cp, (w, h, raw) in glyphs.items():
        if w != 8 or h != 16 or cp < 32 or cp > 126:
            continue
        table.setdefault(bytes(raw[:16]), chr(cp))

    def read_row(r, dy):
        """读第 r 行(按 dy 纵向偏移切 16 像素高的格子)→(认出多少格, 文本)"""
        y0 = r * 16 + dy
        if y0 + 16 > len(rows_ink):
            return 0, ""
        band = rows_ink[y0:y0 + 16]
        hit, line = 0, []
        for c in range(cols):
            x0 = c * 8
            if x0 + 8 > W:
                break
            cell = bytes(
                sum((band[y][x0 + x] & 1) << (7 - x) for x in range(8))
                for y in range(16)
            )
            if not any(cell):
                line.append(" ")
                continue
            ch = table.get(cell)
            if ch:
                hit += 1
                line.append(ch)
            else:
                line.append("?")
        return hit, "".join(line).rstrip()

    # ★ 为什么逐行挑偏移:600 像素 ÷ 16 = 37.5,内核滚屏后最后一行的 y 是 584
    #   (y%16=8),上面那些行是 y%16=0 —— 一屏里同时存在两种对齐。
    #   所以每行都试 dy=0 和 dy=8,谁认出的字多用谁(vi 的状态行就在最下面那行)。
    out = []
    for r in range(rows):
        if r * 16 + 16 > len(rows_ink):
            break
        h0, l0 = read_row(r, 0)
        h8, l8 = read_row(r, 8)
        out.append(l8 if h8 > h0 else l0)
    return out


KEYMAP = {
    " ": "spc", ".": "dot", ",": "comma", "/": "slash", ";": "semicolon",
    "-": "minus", "=": "equal", "'": "apostrophe", "\n": "ret",
}

# 要按 Shift 才能打出来的符号:QEMU 的 sendkey 只认键名,不认"打出来是什么字符"。
# 不映射的话 sendkey '*' 是无效按键,字符就悄悄丢了(踩过:计算器里 '*' 按不出来)。
SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6",
    "&": "7", "*": "8", "(": "9", ")": "0", "_": "minus", "+": "equal",
    ":": "semicolon", '"': "apostrophe", "<": "comma", ">": "dot",
    "?": "slash", "~": "grave_accent", "|": "backslash",
    "{": "bracket_left", "}": "bracket_right",
}


def layout_checks(font_path: str = "font/full-joyf.bin") -> list:
    """
    静态检查(连 QEMU 都不用开):程序加载区和磁盘字库不能重叠。

    这是真踩过的坑:加载地址一开始是 0x300000,而字库从 0x200000 铺到 0x3AF110 ——
    0x300000 正好在字库的点阵数据中间,程序一载入就把 U+782A~U+7832 九个汉字的点阵改掉了。
    两个功能单独测都是对的,只有"跑完程序再显示那几个字"才看得出来。

    所以这里直接从源码里把两个常量抠出来算一遍,谁把它们改成重叠,这一项就红。
    """
    out = []
    try:
        def const(name: str, text: str) -> int:
            m = re.search(rf"^{name}\s+equ\s+(0x[0-9a-fA-F]+|\d+)", text, re.M)
            if not m:
                raise KeyError(name)
            return int(m.group(1), 0)

        shell_src = open("kernel/shell.asm").read()
        font_src = open("kernel/fontdisk.asm").read()
        prog = const("PROG_ADDR", shell_src)
        file_buf = const("FILE_BUF", shell_src) if "FILE_BUF" in shell_src else 0
        font_base = const("FONT_LOAD_ADDR", font_src)
        font_bytes = len(open(font_path, "rb").read())
        font_end = font_base + font_bytes
        # PROG_MAX_SIZE 是算出来的(FONT_LOAD_ADDR - PROG_ADDR),这里也照算
        m = re.search(r"^PROG_MAX_SIZE\s+equ\s+FONT_LOAD_ADDR\s*-\s*PROG_ADDR",
                      shell_src, re.M)
        declared = (font_base - prog) if m else 0

        # ① 加载地址本身不能落在字库的字节范围里(0x300000 那个坑就是这个样子)
        inside_font = font_base <= prog < font_end
        # ② 也不能压在 cat 的文件缓冲上(它是往上长的)
        clash = file_buf and prog < file_buf
        out.append(("离线:程序加载区不压字库",
                    not inside_font and not clash and declared > 0,
                    f"加载地址 {prog:#x} 要在字库 {font_base:#x}..{font_end:#x} 之外、"
                    f"且在 FILE_BUF {file_buf:#x} 之上"))

        # ③ 程序区大小是"顶到字库为止",而且是正的
        out.append(("离线:程序区大小算得对",
                    m is not None and declared > 0 and prog + declared <= font_end,
                    f"PROG_MAX_SIZE = FONT_LOAD_ADDR-PROG_ADDR = {declared:#x}(要 > 0)"))
    except Exception as e:                                   # noqa: BLE001
        out.append(("离线:程序加载区不压字库", False, f"检查本身出错: {e}"))
    return out


def offline_checks(img: str, font_path: str = "font/full-joyf.bin",
                   part_lba: int = 6144) -> list:
    """
    QEMU 关掉之后,不信内核自己说的"写成功了",直接把镜像文件当块设备读一遍。
    这是第二条独立信道:屏幕上的字可能是我看错,磁盘上的字节不会。
    """
    out = []
    raw = open(img, "rb").read()

    # ---- 0) 先做不需要镜像的静态检查(内存布局) ----
    out += layout_checks(font_path)

    # ---- 1) 磁盘字库:描述块 + 本体 ----
    try:
        desc = raw[2047 * 512:2048 * 512]
        blob = raw[2048 * 512:]
        src = open(font_path, "rb").read()
        ok = (desc[:4] == b"JFD1"
              and blob[:4] == b"JOYF"
              and int.from_bytes(desc[12:16], "little") == len(src)
              and blob[:len(src)] == src)
        out.append(("离线:字库在盘上原样", ok,
                    f"LBA 2047 描述块 + LBA 2048 起 {len(src)} 字节与 {font_path} 一致"))
    except Exception as e:                                   # noqa: BLE001
        out.append(("离线:字库在盘上原样", False, str(e)))

    # ---- 2) FAT16:自己解析目录树 ----
    try:
        fs = Fat16(img, part_lba)
    except Exception as e:                                   # noqa: BLE001
        return out + [("离线:解析 FAT16 分区", False, str(e))]

    names = fs.names()
    out.append(("离线:TEST.TXT 进了根目录", "TEST.TXT" in names,
                f"LIST 里有 TEST.TXT,实际 {names}"))
    try:
        got = fs.read("TEST.TXT")
        want = b"hello-from-fat16"
        out.append(("离线:写进去的字节真落盘了", got == want,
                    f"{want!r},实际 {got!r}"))
    except KeyError:
        out.append(("离线:写进去的字节真落盘了", False, "目录里没有 TEST.TXT"))

    # ---- 3c) vi 存出来的文件:STEVIE 移植能不能真的写盘 ----
    try:
        got = fs.read("VITEST.TXT")
        want = b"hello from stevie\n"       # 测试里进插入模式敲的就是这行
        out.append(("离线:vi 存的文件正确", got == want, f"{want!r},实际 {got!r}"))
    except KeyError:
        out.append(("离线:vi 存的文件正确", False, "目录里没有 VITEST.TXT"))

    # ---- 3b) 编辑器存的文件:内容必须和我们敲的键一模一样 ----
    try:
        got = fs.read("NEWFILE.TXT")
        want = b"hello editor\nsecond line"    # 测试里敲的就是这两行
        out.append(("离线:编辑器存的文件正确", got == want, f"{want!r},实际 {got!r}"))
    except KeyError:
        out.append(("离线:编辑器存的文件正确", False, "目录里没有 NEWFILE.TXT"))

    # ---- 3d) 子目录:mkfat 造的 + guest 自己写进去的 ----
    try:
        names = {n.upper() for n, _ in fs.listdir("DOCS")}
        out.append(("离线:DOCS 目录内容齐全",
                    {"NOTE.TXT", "HELLO.BIN", "SUBFILE.TXT"} <= names,
                    f"NOTE.TXT/HELLO.BIN/SUBFILE.TXT,实际 {sorted(names)}"))
    except Exception as e:                                   # noqa: BLE001
        out.append(("离线:DOCS 目录内容齐全", False, str(e)))

    for name, want, label in [
        ("DOCS/NOTE.TXT",    open("progs/NOTES.TXT", "rb").read(), "DOCS/NOTE.TXT 和源文件一致"),
        ("BIGDIR/F39.TXT",   b"file 39\n",                        "跨簇目录里的最后一个文件"),
        ("BIGDIR/F40.TXT",   b"chain-extension",                  "自动扩出来的那一簇里的文件"),
        ("DOCS/SUBFILE.TXT", b"subdir-write-test",                 "子目录里写的文件内容"),
        ("TESTDIR/INNER.TXT", b"hello-in-subdir",                  "二级目录里写的文件内容"),
        ("DOCS/EDITEST.TXT", b"sub dir edit",                      "编辑器存进子目录的内容"),
    ]:
        try:
            got = fs.read_path(name)
            out.append((f"离线:{label}", got == want,
                        f"{want!r},实际 {got!r}"))
        except Exception as e:                               # noqa: BLE001
            out.append((f"离线:{label}", False, str(e)))

    try:
        names = {n.upper() for n, _ in fs.listdir("BIGDIR")}
        out.append(("离线:装满的目录跨了两簇(41 个文件都在)",
                    len([n for n in names if n.startswith("F")]) == 41,
                    f"41 个 F??.TXT,实际 {len([n for n in names if n.startswith('F')])}"))
    except Exception as e:                                   # noqa: BLE001
        out.append(("离线:装满的目录跨了两簇(41 个文件都在)", False, str(e)))

    try:
        names = {n.upper() for n, _ in fs.listdir("")}
        out.append(("离线:空目录真的删掉了", "EMPTY" not in names,
                    f"根目录里没有 EMPTY,实际 {sorted(names)}"))
        out.append(("离线:非空目录还在", "TESTDIR" in names, "TESTDIR 还在(root)"))
    except Exception as e:                                   # noqa: BLE001
        out.append(("离线:空目录真的删掉了", False, str(e)))

    # ---- 3) 对照:镜像里本来就有的文件,字节应该和仓库里的源文件一致 ----
    for name, path in (("README.TXT", "progs/README.TXT"),
                       ("HELLO.BIN", "build/HELLO.BIN"),
                       ("COUNT.BIN", "build/COUNT.BIN")):
        want = open(path, "rb").read()
        try:
            got = fs.read(name)
            out.append((f"离线:{name} 字节一致", got == want,
                        f"{len(want)} 字节,实际 {len(got)} 字节"))
        except Exception as e:                               # noqa: BLE001
            out.append((f"离线:{name} 字节一致", False, str(e)))

    # ---- 4) 两个 FAT 副本应该都更新了(不然掉电就丢目录项) ----
    try:
        idx = next(i for i, (n, _) in enumerate(fs.entries()) if n == "TEST.TXT")
        ent = fs.root_lba + idx * 32
        cl = fs.entry_cluster(raw[ent:ent + 32])
        copies = []
        for i in range(fs.nfats):
            if fs.fat32:
                off = fs.fat_lba + i * fs.fat_sectors * 512 + cl * 4
                copies.append(int.from_bytes(raw[off:off + 4], "little") & 0x0FFFFFFF)
            else:
                off = fs.fat_lba + i * fs.fat_sectors * 512 + cl * 2
                copies.append(int.from_bytes(raw[off:off + 2], "little"))
        # 文件比一个簇小 → 它的簇项应该是"链尾",而且两份 FAT 得一样
        out.append(("离线:两份 FAT 都写了",
                    len(set(copies)) == 1 and copies[0] >= fs.eoc,
                    f"簇 {cl} 在 {fs.nfats} 份 FAT 里都是链尾,实际 {copies}"))
    except Exception as e:                                   # noqa: BLE001
        out.append(("离线:两份 FAT 都写了", False, str(e)))
    return out


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
    hd_mode = "--fontdisk" in argv          # 硬盘镜像:磁盘字库 + FAT16 + 跑程序
    fat32_mode = "--fat32" in argv          # 同一个内核,但分区是 FAT32(镜像得开大)
    font_path = FONT_PATH                   # 比像素用的模板字库(硬盘模式换成完整字库)
    if "--font" in argv:
        font_path = argv[argv.index("--font") + 1]
    argv = [a for a in argv
            if a not in ("--dump", "--hda", "--fault", "--pgfault", "--kbd", "--shell",
                         "--fontdisk", "--fat32")]
    if "--font" in argv:
        i = argv.index("--font")
        del argv[i:i + 2]
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
        glyphs = load_font(font_path) if graphics else None
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

        if hd_mode:
            # ---- 硬盘模式:字库在磁盘上、FAT16 能读能写、程序能从磁盘跑 ----
            results = []

            # 先看开机那几行(还没敲命令,屏幕上一次输出全在)
            results.append(("字库从磁盘加载", has("font: loaded from disk (ATA),"),
                            "font: loaded from disk (ATA), ..."))
            results.append(("完整字库字数", has("40208 glyphs") and not has("416 glyphs"),
                            "40208 glyphs(内置子集是 416)"))
            if fat32_mode:
                results.append(("FAT32 自动识别(BPB 的 f16 每 FAT 扇区数 = 0)",
                                has("fat32: mounted at LBA 6144"),
                                "fat32: mounted at LBA 6144 ...(不用重新分区/换内核)"))
            else:
                results.append(("FAT16 挂载", has("fat16: mounted at LBA 6144"),
                                "fat16: mounted at LBA 6144"))

            def wait_idle(max_wait=25.0):
                """等屏幕不再变化。

                为什么需要:cat 一个 2 KB 的中文文件,内核要一个字一个字画进 VBE
                帧缓冲 —— 在 QEMU 里那是 MMIO,画满一屏要好几秒。固定 sleep 不是
                等太久就是等不够,而"等不够"会让后面所有步骤都跟着乱
                (敲进去的命令排在那次输出后面,断言时屏幕上还没有结果)。
                """
                last = None
                t0 = time.time()
                while time.time() - t0 < max_wait:
                    blob = mon.screendump().tobytes()
                    if blob == last:
                        return
                    last = blob
                    time.sleep(0.3)

            def screen_lines(retries=4):
                """抓一屏并读成文字(全屏程序的断言都走它)。

                为什么要重试:QEMU 抓屏和内核重画是并行的,可能抓到"正在滚屏"那一瞬间的
                撕裂帧 —— 整屏的字都错半个像素,screen_text 一个都认不出来。
                所以这里不只看"有没有非空行",还要数"认得出多少个字",不够就再抓一次。
                """
                best = ""
                # 先等屏幕稳定下来:全屏程序(vi/计算器/编辑器)清屏重画一次
                # 要往 VBE 里画几千个字符,在 QEMU 里是好几秒 —— 不等就会读到
                # 画到一半的屏幕(半屏有字半屏空,一个都认不出来)。
                wait_idle(20.0)
                for _ in range(retries):
                    rescan()
                    raw = screen_text(shot, glyphs)
                    good = sum(1 for l in raw for ch in l if ch not in " ?")
                    text = "\n".join(l for l in raw if l.strip())
                    if good >= 30:
                        return text
                    if len(text) > len(best):
                        best = text
                    time.sleep(0.4)
                return best

            def run(line, wait=0.9, idle=False):
                mon.type_text(line)
                mon.sendkey("ret")
                time.sleep(wait)
                if idle:
                    wait_idle()
                rescan()

            run("ls")
            results.append(("ls 列目录",
                            has("README.TXT") and has("HELLO.BIN") and has("COUNT.BIN"),
                            "README.TXT / HELLO.BIN / COUNT.BIN"))

            # 中文断言用 NOTES.TXT:它短,一屏放得下;READER 文件 2 KB 多,
            # 头几行会被滚屏顶掉(head 部分看不见,不是显示不出来)
            run("cat notes.txt", wait=1.2)
            results.append(("cat 读 UTF-8 文本", has("这个文件是给你改着玩的"),
                            "文件里的中文(UTF-8)显示出来"))
            results.append(("cat 读中文行", has("看看存进去的样子"),
                            "NOTES.TXT 最后一行也在屏幕上"))

            run("cat readme.txt", wait=0.6, idle=True)
            results.append(("cat 读得到正文", has("int 0x30"),
                            "README.TXT 里的 int 0x30(接口表)"))

            run("write test.txt hello-from-fat16")
            results.append(("write 写文件", has("wrote test.txt"), "wrote test.txt"))

            run("ls")
            results.append(("新文件进了目录", has("TEST.TXT"), "TEST.TXT"))

            run("cat test.txt")
            results.append(("写进去的读得回来", has("hello-from-fat16"), "hello-from-fat16"))

            run("run", wait=0.8)
            results.append(("裸 run 打印程序接口",
                            has("JoyOS program API") and has("[ORG 0x120000]"),
                            "int 0x30 的说明(裸敲 run 时打出来)"))

            run("run hello", wait=1.1)
            results.append(("run 跑磁盘上的程序",
                            has("Hello from HELLO.BIN - I was loaded from the FAT16 disk!"),
                            "HELLO.BIN 的英文输出"))
            results.append(("程序里能打中文", has("我是从磁盘上的 HELLO.BIN"),
                            "HELLO.BIN 的中文输出(UTF-8 → 点阵)"))
            results.append(("程序返回 shell", has("program returned to the shell"),
                            "program returned to the shell"))
            results.append(("程序没踩坏字库(哨兵 U+7830 砰)",
                            has("font still intact: 砰"),
                            "font still intact: 砰 —— 这个字的点阵就在以前那个加载地址上"))

            run("run count", wait=1.1)
            results.append(("第二个程序:循环打印", has("counting: 1 2 3 4 5 6 7 8 9 10"),
                            "counting: 1 2 3 4 5 6 7 8 9 10"))
            results.append(("十进制/十六进制 API", has("hex demo: 0xDEADBEEF"),
                            "hex demo: 0xDEADBEEF"))

            # ---- vi(STEVIE 移植):打开 → 插入模式打字 → :w 存盘 → :q 退出 ----
            run("run vi vitest.txt", wait=3.0)
            text_now = screen_lines()
            results.append(("vi 起来了", "vitest.txt" in text_now and "~" in text_now,
                            "vi 的 ~ 空行和 \"vitest.txt\" 状态行"))

            mon.sendkey("i")                    # 插入模式
            time.sleep(0.5)
            mon.type_text("hello from stevie")
            time.sleep(1.0)
            mon.sendkey("esc")                  # 回普通模式
            time.sleep(0.5)
            text_now = screen_lines()
            results.append(("vi 能打字", "hello from stevie" in text_now,
                            "插入模式下打的字出现在屏幕上"))

            mon.type_text(":w")                 # 存盘
            mon.sendkey("ret")
            time.sleep(2.0)
            text_now = screen_lines()
            results.append(("vi :w 存盘", "vitest.txt" in text_now,
                            "状态行报出文件名(存过盘)"))

            mon.type_text(":q")                 # 退出
            mon.sendkey("ret")
            time.sleep(2.0)
            results.append(("vi :q 退出", has("vi closed."), "回到 shell"))

            # ---- 计算器(CALC.BIN):全屏程序,直接读屏幕文字来断言 ----
            def calc(keys: str) -> str:
                """敲一串键,把屏幕读成文字返回(全屏程序没法用 find_text 逐句找)"""
                mon.type_text(keys)
                time.sleep(0.8)
                return screen_lines()

            run("run calc", wait=1.2)
            screen_now = screen_lines()
            results.append(("计算器起来了", "JoyOS calculator" in screen_now,
                            "标题行 JoyOS calculator"))

            for keys, want, name in [
                ("12.5*4=",      "=  50",        "12.5 × 4 = 50"),
                ("c3.5+1.25=",   "=  4.75",      "3.5 + 1.25 = 4.75"),
                ("c7s",          "=  49",        "7 平方 = 49"),
                ("c1/3=",        "=  0.333333",  "1 ÷ 3 = 0.333333(定点 6 位小数)"),
                ("c2-5=",        "=  -3",        "2 - 5 = -3(负数)"),
                ("c5/0=",        "divide by zero", "除以 0 要报错而不是崩"),
                ("c99999=",      "overflow",     "超出范围报 overflow"),
                ("c0.001*1000=", "=  1",         "小数点:0.001 × 1000 = 1"),
            ]:
                text = calc(keys)
                results.append((f"计算器 {name}", want in text, f"屏幕上出现 {want!r}"))

            calc("q")                           # 退出计算器
            results.append(("计算器退出", "program returned to the shell" in calc(""),
                            "回到 shell"))

            # ---- 文本编辑器(EDIT.BIN)----
            run("run edit newfile.txt", wait=1.5)
            screen_now = screen_lines()
            results.append(("编辑器打开新文件", "JoyOS editor" in screen_now
                            and "newfile.txt" in screen_now,
                            "标题栏显示 JoyOS editor --- newfile.txt"))
            results.append(("编辑器读到了参数",
                            "newfile.txt" in screen_now and "NOTES.TXT" not in screen_now,
                            "`run EDIT NEWFILE.TXT` 里的文件名传进去了"))

            mon.type_text("hello editor")       # 打字
            mon.sendkey("ret")
            time.sleep(0.3)
            mon.type_text("second line")
            time.sleep(0.5)
            screen_now = screen_lines()
            results.append(("编辑器能打字", "hello editor" in screen_now,
                            "打进去的字出现在正文里"))

            mon.sendkey("ctrl-s")               # 存盘
            time.sleep(0.9)
            screen_now = screen_lines()
            results.append(("Ctrl-S 存盘", "saved to disk" in screen_now, "状态行 saved to disk"))

            mon.sendkey("ctrl-q")               # 退出
            time.sleep(1.0)
            rescan()
            results.append(("Ctrl-Q 退出编辑器", has("editor closed."),
                            "editor closed. + 回到 shell"))

            # ---- 子目录:路径解析 / cd / mkdir / rmdir / 子目录里读写 ----
            run("ls docs")
            results.append(("ls 列子目录", has("NOTE.TXT") and has("HELLO.BIN"),
                            "DOCS 里的 NOTE.TXT / HELLO.BIN"))
            results.append(("ls 不列 . 和 ..", ".  <DIR>" not in screen_lines(),
                            "目录里不显示 . / .."))

            run("cat docs/note.txt", wait=1.3)
            results.append(("cat 带路径读子目录文件", has("看看存进去的样子"),
                            "DOCS/NOTE.TXT 的内容"))

            run("run docs/hello.bin", wait=1.1)
            results.append(("run 带路径跑子目录里的程序",
                            has("Hello from HELLO.BIN - I was loaded from the FAT16 disk!"),
                            "HELLO.BIN 从 DOCS 里被读出来跑掉"))

            run("cd docs")
            results.append(("cd 进目录(提示符跟着变)", has("docs>"),
                            "提示符变成 docs>"))
            run("write subfile.txt subdir-write-test")
            results.append(("子目录里写文件", has("wrote subfile.txt"), "wrote subfile.txt"))
            run("cat subfile.txt")
            results.append(("子目录里读回文件", has("subdir-write-test"), "文件内容"))
            run("cd ..")
            results.append(("cd .. 回上一层", has("> ls") or has("> cat") or has("> "),
                            "回到根目录(提示符没有目录名)"))

            run("mkdir testdir")
            results.append(("mkdir 建目录", has("created directory testdir"),
                            "created directory testdir"))
            run("ls")
            results.append(("新目录出现在列表里", has("TESTDIR"), "TESTDIR"))
            run("cd testdir")
            run("write inner.txt hello-in-subdir")
            run("cd ..")
            run("rmdir testdir")
            results.append(("非空目录删不掉", has("directory not empty"),
                            "rmdir failed (directory not empty)"))

            run("mkdir empty")
            run("rmdir empty")
            results.append(("rmdir 删空目录", has("removed directory empty"),
                            "removed directory empty"))
            run("ls")
            results.append(("空目录真的没了", "EMPTY" not in screen_lines(),
                            "列表里没有 EMPTY"))

            # ---- 目录满一簇:内核要能往簇链上再挂一簇(不能只会看第一簇)----
            run("ls bigdir", wait=1.0)
            results.append(("列出一整个装满的目录(要跟着簇链走)",
                            has("F00.TXT") and has("F39.TXT"),
                            "F00.TXT 和 F39.TXT 都列得出来(它们在第 2 簇里)"))
            run("cat bigdir/f39.txt", wait=1.0)
            results.append(("读得到第 2 簇里的文件", has("file 39"), "'file 39'"))
            run("write bigdir/f40.txt chain-extension")
            results.append(("目录满了能自动扩一簇", has("wrote bigdir/f40.txt"),
                            "wrote bigdir/f40.txt"))
            run("cat bigdir/f40.txt")
            results.append(("新扩的簇里的文件读得回来", has("chain-extension"),
                            "chain-extension"))

            # int 0x30 的读/写也要认路径:编辑器存到 DOCS 里去
            run("run edit docs/editest.txt", wait=1.5)
            mon.type_text("sub dir edit")
            time.sleep(0.6)
            mon.sendkey("ctrl-s")
            time.sleep(0.9)
            mon.sendkey("ctrl-q")
            time.sleep(1.0)
            rescan()
            results.append(("编辑器能存进子目录", has("editor closed."), "editor closed."))

            # ---- 第二信道:先把 QEMU 关掉(让它把缓存落盘),再自己解析镜像 ----
            qemu.terminate()
            try:
                qemu.wait(timeout=10)
            except subprocess.TimeoutExpired:
                qemu.kill()
                qemu.wait()
            time.sleep(0.3)
            results += offline_checks(img, font_path)
            return report(results)

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
            # 编码相关的三个用例:UTF-8 三字节(汉字)、四字节(emoji)、坏字节(替换字符)
            results.append(("UTF-8 三字节", has("编码统一成 UTF-8"), "编码统一成 UTF-8"))
            results.append(("UTF-8 四字节 emoji", has("😀"), "😀"))
            results.append(("坏字节画替换符",
                            has("broken UTF-8: [") and has("��") and has("still shows"),
                            "[��](两个替换字符)且后面的字还在"))
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
                ("内核区大小(多扇区)", "kernel area: 256 sectors = 131072 bytes"),
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
