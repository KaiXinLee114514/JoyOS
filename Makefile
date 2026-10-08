# ============================================================================
#  JoyOS (胡闹OS) — 构建 / 运行 / 测试
#
#    make            只构建镜像
#    make run        在 QEMU 里跑(开窗口,自己看)
#    make test        无头自动化测试:软盘 + 硬盘 + 除零 + 页错误 + 键盘 + shell + 磁盘字库/FAT16,七条都跑
#    make test-fda    只跑软盘(BIOS 不支持 LBA → CHS 退回那条路)
#    make test-hda    只跑硬盘(BIOS 支持 LBA/EDD 那条路)
#    make test-div    故意除零,看 0 号异常处理
#    make test-pgfault 故意访问没映射的地址,看 14 号页错误 + CR2
#    make test-kbd    用 monitor 的 sendkey 真按键,验证键盘中断 + 回显
#    make test-shell  真键盘输入一串命令,验证 shell 的命令/滚屏/清屏
#    make test-hd-font 硬盘镜像:字库从磁盘读、FAT16 读/写、run 跑磁盘上的程序
#                     (测完还会把镜像当块设备离线解析一遍,证明字节真落盘了)
#    make test-hd32   同一个内核 + FAT32 分区(88 MB),验证 BPB 自动认 32 位 FAT
#    make hd32        自己开窗口跑 FAT32 镜像玩
#    make div         构建"开机就除零"的镜像,自己 qemu 跑着看
#    make clean      清干净
#
#  为什么软盘硬盘都要跑:同一个镜像,BIOS 对软盘不认 LBA 扩展读,对硬盘才认,
#  两条读盘路径都得有测试盯着(见 boot/boot.asm 开头的表)。
#  异常处理同理 —— 不主动踩一脚,永远不知道 IDT 装对没有。
#
#  需要: nasm、qemu-system-i386、python3
#  改代码看: boot/boot.asm(引导)、kernel/*.asm(内核)
# ============================================================================

NASM    := nasm
# 字库源:子集(已入库,make font 离线可用)和完整字库(font/.cache/,不入库)
UNIFONT_HEX ?= font/unifont-subset.hex
UNIFONT_FULL ?= font/.cache/unifont_all.hex
QEMU    := qemu-system-i386
BUILD   := build
# 注释必须单独成行!写在同一行时,`#` 前面的空格会算进变量值,
# 值末尾的空格会把 `-drive file=$(HDIMG),format=raw` 劈成两个参数(make hd 就报
# "drive with bus=0, unit=0 (index=0) exists")。见 makefile-check 目标。
# 软盘镜像(1.44 MB,无字库)
IMG     := $(BUILD)/joyos.img
# 硬盘镜像(16 MB,带完整字库)
HDIMG   := $(BUILD)/joyos-hd.img
# QMP socket:`make hd` / `make hd32` 把它开在这儿,
# tools/text2alt.py --send 就靠它把中文/日文/韩文打进去(见该脚本的说明)
QMP_SOCK := $(BUILD)/qmp.sock
# RTC 给虚拟机的"现在几点":QEMU 默认 base=utc,guest 里 date 打出来会比你墙上钟少 8 小时。
# 加了这个,窗口里看到的 CMOS 时间就是你本机时间(测试台自己起 QEMU,不受影响)
RTC_ARG := -rtc base=localtime
DIV_IMG    := $(BUILD)/joyos-div.img

BOOT_SRC    := boot/boot.asm
KERNEL_SRCS := $(wildcard kernel/*.asm)
# 内核 incbin 了字模、%include 了映射表 —— 它们变了也必须重编内核,
# 不然 make 会说"无事可做",你改了字库却看到的还是老字模(这个坑踩过一次)
FONT_DEPS   := font/vga-font.bin font/vga-zh-map.asm font/vga-zh-strings.asm
# asm 写的程序(progs/*.asm → nasm → 平铺二进制)
PROGS       := HELLO.BIN COUNT.BIN CALC.BIN EDIT.BIN TOUCH.BIN UTF8.BIN

# ---- C 写的程序(progs/*.c):有 gcc 的多架构支持就编,没有就跳过 ----
# 为什么单独探测:gcc -m32 需要 gcc-multilib,没装的话不该让整个 make 挂掉 ——
# 汇编那部分是自足的,别人 clone 下来照样能玩。
CC          := gcc
CC_OK       := $(shell $(CC) -m32 -ffreestanding -c -x c /dev/null -o /dev/null 2>/dev/null && echo yes)
C_CFLAGS    := -m32 -std=gnu89 -ffreestanding -fno-pic -fno-stack-protector \
               -fno-asynchronous-unwind-tables -fno-builtin -nostdlib -O2 -Wall \
               -Iinclude -Ilib -Wno-unused-parameter -Wno-comment
C_LD        := ld -m elf_i386 -T lib/joyos.ld
CRT0_OBJ    := $(BUILD)/crt0.o
MINIC_OBJ   := $(BUILD)/minic.o
ifeq ($(CC_OK),yes)
C_PROGS     := CHELLO.BIN PLAY.BIN
else
C_PROGS     :=
endif

# 扩展:vi(STEVIE 公版 vi 克隆,现在住在 extensions/vi)。
# 默认构建**不含**它 —— 扩展是可选玩具,main 线不该被它拖住;`make ext` 才构建。
VI_OBJS     := $(addprefix $(BUILD)/vi/,$(notdir $(patsubst %.c,%.o,$(wildcard extensions/vi/*.c))))

PROG_BINS   := $(addprefix $(BUILD)/,$(PROGS) $(C_PROGS))

.PHONY: all run run-font hd hd32 ext ext-img run-ext subset test makefile-check test-fda test-hda test-div test-pgfault test-kbd test-shell test-hd-font test-hd32 div font clean lst cc-check

all: $(IMG) $(HDIMG)

# 看一眼 C 工具链在不在(不在就给一句人话,而不是一堆 ld 报错)
cc-check:
	@if [ "$(CC_OK)" = "yes" ]; then \
	    echo "C 工具链: OK ($(CC) -m32),C 程序: $(if $(C_PROGS),$(C_PROGS),无)"; \
	else \
	    echo "C 工具链: 缺 32 位支持 —— C 程序会被跳过(汇编那部分不受影响)。"; \
	    echo "  Debian/Ubuntu:  sudo apt install gcc-multilib"; \
	fi

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/boot.bin: $(BOOT_SRC) | $(BUILD)
	$(NASM) -f bin $< -o $@ -l $(BUILD)/boot.lst
	@printf '   引导扇区: %s 字节 (必须 512)\n' "$$(stat -c %s $@)"

# USE_CUSTOM_FONT=1 时启用实验中的自定义字模(见 font/README.md)
NASM_DEFS := $(if $(USE_CUSTOM_FONT),-DUSE_CUSTOM_FONT=1)

$(BUILD)/kernel.bin: $(KERNEL_SRCS) $(FONT_DEPS) | $(BUILD)
	$(NASM) -f bin -I kernel/ $(NASM_DEFS) kernel/start.asm -o $@ -l $(BUILD)/kernel.lst
	@printf '   内核:     %s 字节\n' "$$(stat -c %s $@)"

$(BUILD)/stub.bin: kernel/stub.asm | $(BUILD)
	$(NASM) -f bin kernel/stub.asm -o $@ -l $(BUILD)/stub.lst
	@printf '   实模式stub: %s 字节\n' "$$(stat -c %s $@)"

$(IMG): $(BUILD)/boot.bin $(BUILD)/stub.bin $(BUILD)/kernel.bin tools/mkimg.py
	python3 tools/mkimg.py $(BUILD)/boot.bin $(BUILD)/stub.bin $(BUILD)/kernel.bin $(IMG)

# 硬盘镜像:多一个磁盘字库(内核启动时用 ATA PIO 读进内存)
# 磁盘上的示例程序:nasm 编成平铺二进制,再被 mkfat 塞进 FAT16 分区
$(BUILD)/%.BIN: progs/%.asm | $(BUILD)
	$(NASM) -f bin $< -o $@
	@printf '   程序: %s %s 字节\n' "$@" "$$(stat -c %s $@)"

# ---- C 程序的构建链:crt0.asm(elf32)→ 程序 → 迷你 libc → ld 出平铺二进制 ----
$(CRT0_OBJ): lib/crt0.asm | $(BUILD)
	$(NASM) -f elf32 $< -o $@

$(MINIC_OBJ): lib/minic.c lib/minic.h include/joyos.h | $(BUILD)
	$(CC) $(C_CFLAGS) -c $< -o $@

# STEVIE 的每个源文件(注意这条要写在通用 progs/%.c 规则前面)
$(BUILD)/vi/%.o: extensions/vi/%.c lib/minic.h include/joyos.h | $(BUILD)
	@mkdir -p $(BUILD)/vi
	$(CC) $(C_CFLAGS) -Iextensions/vi -c $< -o $@

$(BUILD)/%.o: progs/%.c include/joyos.h lib/minic.h | $(BUILD)
	$(CC) $(C_CFLAGS) -c $< -o $@

# ★ PLAY.C 是**大写**后缀(和 progs/ 里那几个 .asm 一个命名习惯),而 gcc 看见 .C
#   会当成 C++ 编 —— 那样 -std=gnu89、隐式 void* 转换这些立刻全是错。所以这条规则
#   显式写 -x c:语言由规则定,不由后缀名说了算。
$(BUILD)/PLAY.o: progs/PLAY.C include/joyos.h lib/minic.h | $(BUILD)
	$(CC) $(C_CFLAGS) -x c -c $< -o $@

$(BUILD)/%.BIN: $(BUILD)/%.o $(CRT0_OBJ) $(MINIC_OBJ) lib/joyos.ld
	$(C_LD) $(CRT0_OBJ) $< $(MINIC_OBJ) -o $@ 2>/dev/null
	@printf '   C 程序: %s %s 字节(链接地址 0x120000)\n' "$@" "$$(stat -c %s $@)"

# vi 扩展:STEVIE 核心 + 迷你 libc + crt0(只有 `make ext` 才会构建)
$(BUILD)/VI.BIN: $(VI_OBJS) $(CRT0_OBJ) $(MINIC_OBJ) lib/joyos.ld
	$(C_LD) $(CRT0_OBJ) $(MINIC_OBJ) $(VI_OBJS) -o $@
	@printf '   C 程序: %s %s 字节(STEVIE 移植,链接地址 0x120000)\n' "$@" "$$(stat -c %s $@)"

# 注意 progs/README.TXT、progs/NOTES.TXT 也要当依赖:改了它们镜像就得重做,
# 不然测试会拿"旧内容"去比新文件,报个莫名其妙的字节数不一致(踩过)
# 造一批小文件,用来测试"目录装满一簇之后自动扩一簇"(每簇 16 项 → 40 个就必须链了)
$(BUILD)/bigdir/.stamp: | $(BUILD)
	@mkdir -p $(BUILD)/bigdir
	@for i in $$(seq -w 0 39); do printf 'file %s\n' "$$i" > $(BUILD)/bigdir/f$$i.txt; done
	@touch $@

# 用 make 自己的 $(shell ...) 生成清单:以前写成 recipe 里的 shell 循环,
# 一旦 `seq`/引号在某个环境里不合适,清单就变成空的 → mkfat 收到怪名字
# (比如 BIGDIR/F.TXT),根目录里的文件全乱(踩过)。
BIGDIR_SPECS := $(foreach i,$(shell seq -w 0 39),BIGDIR/F$(i).TXT=$(BUILD)/bigdir/f$(i).txt)

$(HDIMG): $(BUILD)/boot.bin $(BUILD)/stub.bin $(BUILD)/kernel.bin font/full-joyf.bin \
          $(PROG_BINS) progs/README.TXT progs/NOTES.TXT \
          tools/mkimg.py tools/mkfat.py \
          $(BUILD)/bigdir/.stamp
	python3 tools/mkimg.py $(BUILD)/boot.bin $(BUILD)/stub.bin $(BUILD)/kernel.bin $(HDIMG) font/full-joyf.bin
	python3 tools/mkfat.py $(HDIMG) 6144 8 README.TXT=progs/README.TXT \
	    NOTES.TXT=progs/NOTES.TXT DOCS/ DOCS/NOTE.TXT=progs/NOTES.TXT \
	    DOCS/HELLO.BIN=$(BUILD)/HELLO.BIN BIGDIR/ $(BIGDIR_SPECS) \
	    $(foreach p,$(PROGS) $(C_PROGS),$(p)=$(BUILD)/$(p))

hd: $(HDIMG)
	@rm -f $(QMP_SOCK)
	$(QEMU) -drive file=$(HDIMG),format=raw,if=ide,index=0 -boot c -qmp unix:$(QMP_SOCK),server,nowait $(RTC_ARG)

# ---------------------------------------------------------------------------
#  FAT32 版镜像:同一个内核(BPB 自动认 FAT16/FAT32),只是分区格式不一样。
#  FAT32 要求 ≥ 65525 个簇,8 MB 的分区凑不出来,所以镜像开到 96 MB、分区 88 MB。
# ---------------------------------------------------------------------------
HD32IMG := $(BUILD)/joyos-hd32.img

$(HD32IMG): $(BUILD)/boot.bin $(BUILD)/stub.bin $(BUILD)/kernel.bin font/full-joyf.bin \
            $(PROG_BINS) progs/README.TXT progs/NOTES.TXT \
            tools/mkimg.py tools/mkfat.py \
            $(BUILD)/bigdir/.stamp
	python3 tools/mkimg.py $(BUILD)/boot.bin $(BUILD)/stub.bin $(BUILD)/kernel.bin $(HD32IMG) \
	    font/full-joyf.bin --disk-mb 96
	python3 tools/mkfat.py $(HD32IMG) 6144 88 --fat32 README.TXT=progs/README.TXT \
	    NOTES.TXT=progs/NOTES.TXT DOCS/ DOCS/NOTE.TXT=progs/NOTES.TXT \
	    DOCS/HELLO.BIN=$(BUILD)/HELLO.BIN BIGDIR/ $(BIGDIR_SPECS) \
	    $(foreach p,$(PROGS) $(C_PROGS),$(p)=$(BUILD)/$(p))

hd32: $(HD32IMG)
	@rm -f $(QMP_SOCK)
	$(QEMU) -drive file=$(HD32IMG),format=raw,if=ide,index=0 -boot c -qmp unix:$(QMP_SOCK),server,nowait $(RTC_ARG)

# ---------------------------------------------------------------------------
#  扩展:不进默认构建/默认镜像的东西(现在就一个 vi)
#    make ext        构建所有扩展 → $(BUILD)/ext/*.BIN
#    make ext-img    做一张"默认镜像 + 扩展"的镜像
#    make run-ext    构建 + 启动那张镜像
#  加新扩展:把源码放 extensions/<名字>/,在 EXT_BINS 里加一行就行。
# ---------------------------------------------------------------------------
EXT_BINS    := $(BUILD)/VI.BIN
EXT_IMG     := $(BUILD)/joyos-hd-ext.img

ext: $(EXT_BINS)

$(EXT_IMG): $(EXT_BINS) $(HDIMG)
	cp $(HDIMG) $@
	python3 tools/mkfat.py $@ 6144 8 $(foreach b,$(notdir $(EXT_BINS)),$(b)=$(BUILD)/$(b))

ext-img: $(EXT_IMG)

run-ext: $(EXT_IMG)
	$(QEMU) -drive file=$(EXT_IMG),format=raw,if=ide,index=0 -boot c $(RTC_ARG)

test-hd32: $(PROG_BINS) font/full-joyf.bin progs/README.TXT progs/NOTES.TXT
	@echo "── FAT32 镜像:同一套内核,BPB 自动认 32 位 FAT ──"
	$(MAKE) -s -B $(HD32IMG)
	python3 -u tests/qemu_test.py $(HD32IMG) --hda --fontdisk --fat32 --font font/full-joyf.bin

# 先强制重建镜像:上一轮测试往盘里写的 TEST.TXT / NEWFILE.TXT 会留在这儿,
# 第二次跑就变成"编辑器把内容追加了一遍",测试自己就不干净了
test-hd-font: $(PROG_BINS) font/full-joyf.bin progs/README.TXT progs/NOTES.TXT
	@echo "── 硬盘镜像:磁盘字库 + FAT16 读写 + 计算器 + 编辑器 ──"
	$(MAKE) -s -B $(HDIMG)
	python3 -u tests/qemu_test.py $(HDIMG) --hda --fontdisk --font font/full-joyf.bin

# 两个"开机就炸"的镜像:自测代码用 -D 开关才编进去,正常镜像里没有
$(BUILD)/kernel-div.bin: $(KERNEL_SRCS) $(FONT_DEPS) | $(BUILD)
	$(NASM) -f bin -I kernel/ -DSELFTEST_FAULT=1 kernel/start.asm -o $@ -l $(BUILD)/kernel-div.lst

$(DIV_IMG): $(BUILD)/boot.bin $(BUILD)/stub.bin $(BUILD)/kernel-div.bin tools/mkimg.py
	python3 tools/mkimg.py $(BUILD)/boot.bin $(BUILD)/stub.bin $(BUILD)/kernel-div.bin $(DIV_IMG)

run: $(IMG)
	$(QEMU) -fda $(IMG) -boot a $(RTC_ARG)

# 带自定义点阵字模的实验版(见 font/README.md;默认构建不启用)
run-font:
	$(MAKE) -B build/kernel.bin USE_CUSTOM_FONT=1
	$(MAKE) $(IMG)
	$(QEMU) -fda $(IMG) -boot a $(RTC_ARG)

div: $(DIV_IMG)
	$(QEMU) -fda $(DIV_IMG) -boot a $(RTC_ARG)

# 从上游 .hex 重新生成字模 / 映射 / 文案(需要先下 unifont 的 .hex,见 font/README.md)
# 从完整字库重新抽子集(需要先有 font/.cache/unifont_all.hex,见 font/README.md)
subset: tools/unifont2bin.py font/charset.txt font/charset-cjk.txt font/charset-extra.txt
	@test -f $(UNIFONT_FULL) || { \
	    echo "缺 $(UNIFONT_FULL) —— 从 USTC 镜像下一个:"; \
	    echo "  mkdir -p font/.cache && curl -o font/.cache/unifont_all.hex.gz \\"; \
	    echo "    https://mirrors.ustc.edu.cn/gnu/unifont/unifont-18.0.01/unifont_all-18.0.01.hex.gz"; \
	    echo "  gunzip -c font/.cache/unifont_all.hex.gz > $(UNIFONT_FULL)"; exit 1; }
	python3 tools/mkfontsubset.py $(UNIFONT_FULL) font/unifont-subset.hex font/charset-all.txt

font: tools/unifont2bin.py font/charset.txt font/strings.txt
	python3 tools/unifont2bin.py --hex $(UNIFONT_HEX) \
	    --vga-font font/vga-font.bin --vga-map font/vga-zh-map.asm --vga-chars-file font/charset.txt \
	    --zh-strings-in font/strings.txt --zh-strings-out font/vga-zh-strings.asm

# 防回归:变量定义里 `#` 前有空格时,那些空格会进变量值 —— 曾把 make hd 的
# `-drive file=$(HDIMG),format=raw` 劈成两个参数。注释请单独成行。
makefile-check:
	@bad=$$(grep -nE '^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:=[^#]*[[:space:]]+#' Makefile || true); \
	if [ -n "$$bad" ]; then \
	    echo "✗ Makefile 里这些变量定义的 # 前有空格,值末尾会带空格:"; echo "$$bad"; \
	    echo "  把注释挪到单独一行,否则 shell 会把参数劈开(例如 make hd 会失败)。"; exit 1; \
	fi
	@echo "makefile-check: OK(变量定义里没有行尾空格)"

test: makefile-check test-fda test-hda test-div test-pgfault test-kbd test-shell test-hd-font test-hd32

test-fda: $(IMG)
	@echo "── 作为软盘启动(BIOS 无 LBA,应走 CHS 退回)──"
	python3 -u tests/qemu_test.py $(IMG)

test-hda: $(IMG)
	@echo "── 作为硬盘启动(BIOS 有 LBA,应走 EDD)──"
	python3 -u tests/qemu_test.py $(IMG) --hda

test-div: $(DIV_IMG)
	@echo "── 故意除零(应打出 KERNEL PANIC + divide error)──"
	python3 -u tests/qemu_test.py $(DIV_IMG) --fault

test-pgfault: $(IMG)
	@echo "── shell 里敲 debug fault(应打出 page fault + CR2)──"
	python3 -u tests/qemu_test.py $(IMG) --pgfault

test-kbd: $(IMG)
	@echo "── 键盘:sendkey 打字,看屏幕回显 ──"
	python3 -u tests/qemu_test.py $(IMG) --kbd

test-shell: $(IMG)
	@echo "── shell:敲 help/info/page/echo/clear,还有滚屏 ──"
	python3 -u tests/qemu_test.py $(IMG) --shell

# 看反汇编: make lst 之后翻 build/*.lst
lst: $(BOOT_SRCS) $(KERNEL_SRCS) $(FONT_DEPS) | $(BUILD)
	$(NASM) -f bin $(BOOT_SRC) -o $(BUILD)/boot.bin -l $(BUILD)/boot.lst
	$(NASM) -f bin -I kernel/ kernel/start.asm -o $(BUILD)/kernel.bin -l $(BUILD)/kernel.lst
	@echo "反汇编在 $(BUILD)/boot.lst 和 $(BUILD)/kernel.lst"

clean:
	rm -rf $(BUILD)
