# ============================================================================
#  JoyOS (胡闹OS) — 构建 / 运行 / 测试
#
#    make            只构建镜像
#    make run        在 QEMU 里跑(开窗口,自己看)
#    make test        无头自动化测试:软盘 + 硬盘 + 除零 + 页错误 + 键盘 + shell,六条都跑
#    make test-fda    只跑软盘(BIOS 不支持 LBA → CHS 退回那条路)
#    make test-hda    只跑硬盘(BIOS 支持 LBA/EDD 那条路)
#    make test-div    故意除零,看 0 号异常处理
#    make test-故意访问没映射的地址,看 14 号页错误 + CR2
#    make test-kbd    用 monitor 的 sendkey 真按键,验证键盘中断 + 回显
#    make test-shell  真键盘输入一串命令,验证 shell 的命令/滚屏/清屏
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
# unifont 的 .hex 放哪(只有 make font 用得到,平时构建不需要它)
UNIFONT_HEX ?= font/unifont-subset.hex
QEMU    := qemu-system-i386
BUILD   := build
IMG     := $(BUILD)/joyos.img
DIV_IMG    := $(BUILD)/joyos-div.img

BOOT_SRC    := boot/boot.asm
KERNEL_SRCS := $(wildcard kernel/*.asm)
# 内核 incbin 了字模、%include 了映射表 —— 它们变了也必须重编内核,
# 不然 make 会说"无事可做",你改了字库却看到的还是老字模(这个坑踩过一次)
FONT_DEPS   := font/vga-font.bin font/vga-zh-map.asm font/vga-zh-strings.asm

.PHONY: all run run-font test test-fda test-hda test-div test-pgfault test-kbd test-shell div font clean lst

all: $(IMG)

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/boot.bin: $(BOOT_SRC) | $(BUILD)
	$(NASM) -f bin $< -o $@ -l $(BUILD)/boot.lst
	@printf '   引导扇区: %s 字节 (必须 512)\n' "$$(stat -c %s $@)"

# USE_CUSTOM_FONT=1 时启用实验中的自定义字模(见 font/README.md)
NASM_DEFS := $(if $(USE_CUSTOM_FONT),-DUSE_CUSTOM_FONT=1)

$(BUILD)/kernel.bin: $(KERNEL_SRCS) $(FONT_DEPS) | $(BUILD)
	$(NASM) -f bin -I kernel/ $(NASM_DEFS) kernel/kmain.asm -o $@ -l $(BUILD)/kernel.lst
	@printf '   内核:     %s 字节\n' "$$(stat -c %s $@)"

$(IMG): $(BUILD)/boot.bin $(BUILD)/kernel.bin tools/mkimg.py
	python3 tools/mkimg.py $(BUILD)/boot.bin $(BUILD)/kernel.bin $(IMG)

# 两个"开机就炸"的镜像:自测代码用 -D 开关才编进去,正常镜像里没有
$(BUILD)/kernel-div.bin: $(KERNEL_SRCS) $(FONT_DEPS) | $(BUILD)
	$(NASM) -f bin -I kernel/ -DSELFTEST_FAULT=1 kernel/kmain.asm -o $@ -l $(BUILD)/kernel-div.lst

$(DIV_IMG): $(BUILD)/boot.bin $(BUILD)/kernel-div.bin tools/mkimg.py
	python3 tools/mkimg.py $(BUILD)/boot.bin $(BUILD)/kernel-div.bin $(DIV_IMG)

run: $(IMG)
	$(QEMU) -fda $(IMG) -boot a

# 带自定义点阵字模的实验版(见 font/README.md;默认构建不启用)
run-font:
	$(MAKE) -B build/kernel.bin USE_CUSTOM_FONT=1
	$(MAKE) $(IMG)
	$(QEMU) -fda $(IMG) -boot a

div: $(DIV_IMG)
	$(QEMU) -fda $(DIV_IMG) -boot a

# 从上游 .hex 重新生成字模 / 映射 / 文案(需要先下 unifont 的 .hex,见 font/README.md)
font: tools/unifont2bin.py font/charset.txt font/strings.txt
	python3 tools/unifont2bin.py --hex $(UNIFONT_HEX) \
	    --vga-font font/vga-font.bin --vga-map font/vga-zh-map.asm --vga-chars-file font/charset.txt \
	    --zh-strings-in font/strings.txt --zh-strings-out font/vga-zh-strings.asm

test: test-fda test-hda test-div test-pgfault test-kbd test-shell

test-fda: $(IMG)
	@echo "── 作为软盘启动(BIOS 无 LBA,应走 CHS 退回)──"
	python3 tests/qemu_test.py $(IMG)

test-hda: $(IMG)
	@echo "── 作为硬盘启动(BIOS 有 LBA,应走 EDD)──"
	python3 tests/qemu_test.py $(IMG) --hda

test-div: $(DIV_IMG)
	@echo "── 故意除零(应打出 KERNEL PANIC + divide error)──"
	python3 tests/qemu_test.py $(DIV_IMG) --fault

test-pgfault: $(IMG)
	@echo "── shell 里敲 fault(应打出 page fault + CR2)──"
	python3 tests/qemu_test.py $(IMG) --pgfault

test-kbd: $(IMG)
	@echo "── 键盘:sendkey 打字,看屏幕回显 ──"
	python3 tests/qemu_test.py $(IMG) --kbd

test-shell: $(IMG)
	@echo "── shell:敲 help/info/page/echo/clear,还有滚屏 ──"
	python3 tests/qemu_test.py $(IMG) --shell

# 看反汇编: make lst 之后翻 build/*.lst
lst: $(BOOT_SRCS) $(KERNEL_SRCS) $(FONT_DEPS) | $(BUILD)
	$(NASM) -f bin $(BOOT_SRC) -o $(BUILD)/boot.bin -l $(BUILD)/boot.lst
	$(NASM) -f bin -I kernel/ kernel/kmain.asm -o $(BUILD)/kernel.bin -l $(BUILD)/kernel.lst
	@echo "反汇编在 $(BUILD)/boot.lst 和 $(BUILD)/kernel.lst"

clean:
	rm -rf $(BUILD)
