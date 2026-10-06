; ============================================================================
;  JoyOS (胡闹OS) — 内核镜像入口文件
;
;  内核镜像的布局(整块被引导扇区搬到 0x10000):
;      +0x0000  实模式 stub:问 VBE 要图形模式、写启动参数、建 GDT、进保护模式
;      +0x????  32 位内核:终端、IDT、分页、键盘、shell(kmain.asm 及以下)
;
;  为什么要这么分层:VBE 只能实模式调 BIOS,而 512 字节的引导扇区塞不下这些代码。
;  放在内核镜像开头,空间就宽松了;引导扇区只剩"读盘 + 跳过来"。
;
;  构建: nasm -f bin -I kernel/ kernel/start.asm -o build/kernel.bin
;  注意:[ORG 0x10000] 只能写一次(整个平铺镜像共用一个原点),所以 stub.asm 和
;        kmain.asm 里都不要再写 ORG/BITS 头(见各自文件开头)。
; ============================================================================

[BITS 32]
[ORG 0x10000]

kmain:                                  ; 32 位内核入口(stub 里 jmp 0x10000 跳过来)
;  ⚠️ 第一个被 include 的文件决定 0x10000 处的第一条指令 —— 因为 `kmain:` 本身不占字节。
;     所以入口代码必须排在第一个,别的模块(哪怕是被前面引用的)都放后面。
%include "kmain.asm"                     ; 终端 + 启动信息(必须在最前)
%include "utf8.asm"                      ; UTF-8 解码
%include "ata.asm"                       ; ATA 硬盘 PIO
%include "fontdisk.asm"                  ; 从磁盘加载完整字库
%include "fat.asm"                       ; FAT16 文件系统
%include "api.asm"                       ; 程序接口 int 0x30                  ; 从磁盘加载完整字库                      ; UTF-8 解码
%include "speaker.asm"                   ; PC 蜂鸣器(beep,忙等标定见文件开头)
%include "idt.asm"                       ; IDT / 异常 / panic 屏
%include "paging.asm"                    ; 页目录 / 页表
%include "fbterm.asm"                   ; 帧缓冲终端(图形模式)
%include "vgafont.asm"                   ; 自定义点阵字模(文本模式实验)
%include "keyboard.asm"                  ; PS/2 键盘
%include "shell.asm"                     ; shell

; 内核区补到 64 KiB(128 扇区)—— 图形模式的帧缓冲终端和字库都要地方
times (128 * 512) - ($ - $$) db 0
