#!/usr/bin/env bash
# ============================================================================
#  JoyOS (胡闹OS) — QEMU 启动脚本
#
#  为什么还要个脚本:make run 只有一种跑法,而 JoyOS 有两条读盘路径、
#  一个 panic 演示、还有能接 gdb 的调试模式,直接用脚本选更省事。
#
#    ./tools/run.sh              软盘启动(BIOS 无 LBA → 走 CHS 退回那条路)
#    ./tools/run.sh --hdd        硬盘启动(BIOS 有 LBA → 走 EDD 那条路)
#    ./tools/run.sh --div        开机就除零,直接看 panic 屏
#    ./tools/run.sh --gdb        开 gdb 调试端口(-s -S,等 gdb 连上才开跑)
#    ./tools/run.sh --monitor    把 QEMU monitor 接到当前终端(能 sendkey/xp)
#    ./tools/run.sh --dry-run    只打印要执行的 qemu 命令,不启动
#
#   环境变量:
#     QEMU_DISPLAY=none ./tools/run.sh     无窗口跑(脚本里/远程 SSH 用)
#
#  在 QEMU 窗口里的常用键:
#     Ctrl+Alt+g   放开鼠标键盘抓取
#     Ctrl+Alt+2   切到 monitor 控制台(Ctrl+Alt+1 切回来)
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

QEMU_BIN="${QEMU_BIN:-qemu-system-i386}"
MODE="floppy"
EXTRA=()
DRY_RUN=0

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --hdd)     MODE="hdd" ;;
        --div)     MODE="div" ;;
        --gdb)     EXTRA+=(-s -S) ;;
        --monitor) EXTRA+=(-monitor stdio) ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1(用 --help 看用法)" >&2; exit 1 ;;
    esac
    shift
done

case "$MODE" in
    floppy) IMG="build/joyos.img"
            DRIVE=(-drive "file=$IMG,format=raw,if=floppy" -boot a)
            DESC="软盘启动(应看到 CHS fallback)" ;;
    hdd)    IMG="build/joyos.img"
            DRIVE=(-drive "file=$IMG,format=raw,if=ide,index=0" -boot c)
            DESC="硬盘启动(应看到 LBA (EDD))" ;;
    div)    IMG="build/joyos-div.img"
            DRIVE=(-drive "file=$IMG,format=raw,if=floppy" -boot a)
            DESC="故意除零(应看到 EXCEPTION 00: divide error)" ;;
    *)      echo "内部错误: 未知模式 $MODE" >&2; exit 1 ;;
esac

if [ "$DRY_RUN" -eq 0 ]; then
    command -v "$QEMU_BIN" >/dev/null 2>&1 || {
        echo "找不到 $QEMU_BIN —— 先装 QEMU:" >&2
        echo "    sudo apt install qemu-system-x86" >&2
        exit 1
    }
fi

# 镜像没构建(或源码更新了)就先构建
make -s "$IMG"

CMD=("$QEMU_BIN" "${DRIVE[@]}")
[ -n "${QEMU_DISPLAY:-}" ] && CMD+=(-display "$QEMU_DISPLAY")
[ ${#EXTRA[@]} -gt 0 ] && CMD+=("${EXTRA[@]}")

if [ "$DRY_RUN" -eq 1 ]; then
    printf '要执行的命令: '
    printf '%q ' "${CMD[@]}"
    printf '\n'
    exit 0
fi

echo "JoyOS: $DESC"
[ -n "${QEMU_DISPLAY:-}" ] || echo "(QEMU 窗口里 Ctrl+Alt+g 放开鼠标,Ctrl+Alt+2 看 monitor)"
exec "${CMD[@]}"
