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
QEMU    := qemu-system-i386
BUILD   := build
IMG     := $(BUILD)/joyos.img
DIV_IMG    := $(BUILD)/joyos-div.img

BOOT_SRC    := boot/boot.asm
KERNEL_SRCS := $(wildcard kernel/*.asm)

.PHONY: all run test test-fda test-hda test-div test-pgfault test-kbd test-shell div clean lst

all: $(IMG)

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/boot.bin: $(BOOT_SRC) | $(BUILD)
	$(NASM) -f bin $< -o $@ -l $(BUILD)/boot.lst
	@printf '   引导扇区: %s 字节 (必须 512)\n' "$$(stat -c %s $@)"

$(BUILD)/kernel.bin: $(KERNEL_SRCS) | $(BUILD)
	$(NASM) -f bin -I kernel/ kernel/kmain.asm -o $@ -l $(BUILD)/kernel.lst
	@printf '   内核:     %s 字节\n' "$$(stat -c %s $@)"

$(IMG): $(BUILD)/boot.bin $(BUILD)/kernel.bin tools/mkimg.py
	python3 tools/mkimg.py $(BUILD)/boot.bin $(BUILD)/kernel.bin $(IMG)

# 两个"开机就炸"的镜像:自测代码用 -D 开关才编进去,正常镜像里没有
$(BUILD)/kernel-div.bin: $(KERNEL_SRCS) | $(BUILD)
	$(NASM) -f bin -I kernel/ -DSELFTEST_FAULT=1 kernel/kmain.asm -o $@ -l $(BUILD)/kernel-div.lst

$(DIV_IMG): $(BUILD)/boot.bin $(BUILD)/kernel-div.bin tools/mkimg.py
	python3 tools/mkimg.py $(BUILD)/boot.bin $(BUILD)/kernel-div.bin $(DIV_IMG)

run: $(IMG)
	$(QEMU) -fda $(IMG) -boot a

div: $(DIV_IMG)
	$(QEMU) -fda $(DIV_IMG) -boot a

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
lst: $(BOOT_SRC) $(KERNEL_SRCS) | $(BUILD)
	$(NASM) -f bin $(BOOT_SRC) -o $(BUILD)/boot.bin -l $(BUILD)/boot.lst
	$(NASM) -f bin -I kernel/ kernel/kmain.asm -o $(BUILD)/kernel.bin -l $(BUILD)/kernel.lst
	@echo "反汇编在 $(BUILD)/boot.lst 和 $(BUILD)/kernel.lst"

clean:
	rm -rf $(BUILD)
