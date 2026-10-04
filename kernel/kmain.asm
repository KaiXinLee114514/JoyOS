; ============================================================================
;  JoyOS (胡闹OS) — 内核入口
;
;  这个文件负责"开机报到"+ 终端输出,其它功能在各自文件里:
;      kernel/idt.asm       中断描述符表 + CPU 异常(panic 屏)
;      kernel/paging.asm    页目录/页表 + 开分页
;      kernel/keyboard.asm  PS/2 键盘(PIC 重映射 + IRQ1)
;      kernel/shell.asm     那个很土的 shell
;
;  构建: nasm -f bin -I kernel/ kernel/kmain.asm -o build/kernel.bin
;        (要 -I kernel/ 才能 %include 到同目录的文件)
;
;  内存布局(这个阶段的约定):
;      0x00000-0x004FF   中断向量表 / BIOS 数据区
;      0x01000-0x03FFF   页目录 + 页表(paging.asm 里硬编码)
;      0x07C00           引导扇区(512 字节)
;      0x10000-0x17FFF   内核(32 KiB = 64 扇区,引导扇区读进来的)
;      0x90000           内核栈(往下长)
;      0xB8000           VGA 文本缓冲(80×25,每格 2 字节:字符 + 颜色)
; ============================================================================

[BITS 32]
[ORG 0x10000]

VGA_MEM    equ 0xB8000
VGA_COLS   equ 80
VGA_ROWS   equ 25

COL_NORMAL equ 0x07                    ; 浅灰
COL_HEADER equ 0x0B                    ; 亮青
COL_OK     equ 0x0A                    ; 亮绿
COL_ERR    equ 0x0C                    ; 亮红

kmain:
    ; 引导扇区把参数放在 eax/ebx/ecx 里,先搬走免得后面被覆盖
    mov [boot_sectors], eax            ; 内核区扇区数
    mov [boot_lba], ebx                ; 内核起始 LBA
    mov [boot_mode], ecx               ; 1 = LBA(EDD),0 = CHS 退回

    call term_init                     ; 清屏 + 光标归位

    ; ---- 开机报到 ----
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_title
    call term_print
    mov al, 10
    call term_putc

    mov al, COL_NORMAL
    call term_set_color
    mov esi, msg_chain
    call term_print

    mov esi, msg_sectors
    call term_print
    mov eax, [boot_sectors]
    call term_print_dec
    mov esi, msg_equals
    call term_print
    mov eax, [boot_sectors]
    shl eax, 9
    call term_print_dec
    mov esi, msg_bytes
    call term_print

    mov esi, msg_kmain
    call term_print
    call term_print_addr
    mov esi, msg_pm
    call term_print

    mov esi, msg_seg
    call term_print
    mov ax, ds
    movzx eax, ax
    call term_print_hex
    mov esi, msg_seg2
    call term_print

    ; 引导扇区是用哪种方式读的盘
    mov esi, msg_disk
    call term_print
    cmp dword [boot_mode], 0
    je .chs
    mov esi, msg_disk_lba
    jmp .disk_done
.chs:
    mov esi, msg_disk_chs
.disk_done:
    call term_print

    ; ---- 装 IDT ----
    call idt_init
    mov esi, msg_idt
    call term_print

    ; ---- 开分页 ----
    call paging_init
    mov esi, msg_paging
    call term_print

    ; ---- 键盘 ----
    call kbd_init
    mov esi, msg_kbd
    call term_print

    mov al, COL_OK
    call term_set_color
    mov esi, msg_ok
    call term_print

%ifdef SELFTEST_FAULT
    ; ---- 故意除零,验证异常处理真的生效 ----
    ; 只有 make div / make test-div 时才会编进去(-DSELFTEST_FAULT=1)
    mov eax, 1
    xor edx, edx
    xor ecx, ecx
    div ecx                              ; 除零 → 0 号异常
%endif

    jmp shell_main                       ; 进 shell(不返回)

.hang:
    hlt
    jmp .hang

; ============================================================================
;  终端驱动:在 VGA 文本缓冲上做一个会滚屏的光标终端
;
;  为什么不用"按行打印"那套:shell 要连续输出几十行,写满 25 行必须滚屏,
;  所以这里做成"一个光标 + 一个字符一个字符地吐",和真终端一个道理。
; ============================================================================

; 清屏:整屏填空格(0x0720 = 浅灰空格),光标回左上角
term_init:
    mov byte [term_row], 0
    mov byte [term_col], 0
    mov byte [term_color], COL_NORMAL
    ; 落到 term_clear
term_clear:
    push eax
    push ecx
    push edi
    mov edi, VGA_MEM
    mov eax, 0x0720                      ; 空格 + 浅灰
    mov ecx, VGA_COLS * VGA_ROWS / 2      ; 每双字两格
    rep stosd
    mov byte [term_row], 0
    mov byte [term_col], 0
    call term_move_hw_cursor
    pop edi
    pop ecx
    pop eax
    ret

; al = 颜色属性
term_set_color:
    mov [term_color], al
    ret

; al = 字符(支持 \n \r \b)
term_putc:
    push eax
    push ebx
    push edi
    cmp al, 10
    je .newline
    cmp al, 13
    je .cr
    cmp al, 8
    je .bs

    call term_addr                        ; edi = 当前光标处的显存地址
    mov [edi], al
    mov bl, [term_color]
    mov [edi + 1], bl
    inc byte [term_col]
    cmp byte [term_col], VGA_COLS
    jb .done
    call term_newline
    jmp .done

.newline:
    call term_newline
    jmp .done
.cr:
    mov byte [term_col], 0
    jmp .done
.bs:
    cmp byte [term_col], 0
    je .done
    dec byte [term_col]
    call term_addr                        ; 在退掉的那格上写空格
    mov byte [edi], ' '
    mov bl, [term_color]
    mov [edi + 1], bl
.done:
    call term_move_hw_cursor
    pop edi
    pop ebx
    pop eax
    ret

; edi = 光标处的显存地址 = VGA_MEM + 行×160 + 列×2
term_addr:
    push eax
    push ebx
    movzx edi, byte [term_row]
    imul edi, VGA_COLS * 2
    movzx ebx, byte [term_col]
    shl ebx, 1
    add edi, ebx
    add edi, VGA_MEM
    pop ebx
    pop eax
    ret

term_newline:
    mov byte [term_col], 0
    inc byte [term_row]
    cmp byte [term_row], VGA_ROWS
    jb .done
    dec byte [term_row]                   ; 停在最后一行,整屏往上滚
    call term_scroll
.done:
    ret

; 滚屏:第 1~24 行搬到第 0~23 行,最后一行清空
term_scroll:
    push eax
    push ecx
    push esi
    push edi
    mov esi, VGA_MEM + VGA_COLS * 2
    mov edi, VGA_MEM
    mov ecx, VGA_COLS * 2 * (VGA_ROWS - 1) / 4
    rep movsd
    mov edi, VGA_MEM + VGA_COLS * 2 * (VGA_ROWS - 1)
    mov eax, 0x0720
    mov ecx, VGA_COLS / 2
    rep stosd
    pop edi
    pop esi
    pop ecx
    pop eax
    ret

; 把光标位置告诉 VGA 硬件(不然屏幕上不会有那个闪的方块)
term_move_hw_cursor:
    push eax
    push ebx
    push edx
    movzx eax, byte [term_row]
    imul eax, VGA_COLS
    movzx ebx, byte [term_col]
    add eax, ebx                          ; 位置 = 行×80 + 列
    mov ebx, eax
    mov dx, 0x3D4                         ; CRT 索引口
    mov al, 0x0F                          ; 光标位置低 8 位
    out dx, al
    inc dx                                ; 0x3D5 = 数据口
    mov al, bl
    out dx, al
    dec dx
    mov al, 0x0E                          ; 光标位置高 8 位
    out dx, al
    inc dx
    mov al, bh
    out dx, al
    pop edx
    pop ebx
    pop eax
    ret

; esi = 以 0 结尾的字符串
term_print:
    push eax
    push esi
.next:
    lodsb
    test al, al
    jz .done
    call term_putc
    jmp .next
.done:
    pop esi
    pop eax
    ret

; eax = 数值 → 打 8 位十六进制,带 0x 前缀
term_print_hex:
    push eax
    push ebx
    push ecx
    mov ebx, eax
    mov al, '0'
    call term_putc
    mov al, 'x'
    call term_putc
    mov ecx, 8
.loop:
    mov eax, ebx
    push ecx
    sub ecx, 1
    shl ecx, 2
    shr eax, cl
    pop ecx
    and eax, 0x0F
    cmp al, 10
    jb .digit
    add al, 'A' - 10
    jmp .emit
.digit:
    add al, '0'
.emit:
    call term_putc
    sub ecx, 1
    jnz .loop
    pop ecx
    pop ebx
    pop eax
    ret

; eax = 数值 → 打十进制(无符号,不补零)
term_print_dec:
    push eax
    push ebx
    push ecx
    push edx
    mov ebx, 10
    xor ecx, ecx
.divide:
    xor edx, edx
    div ebx
    push edx                              ; 余数入栈 → 出栈自然逆序
    inc ecx
    test eax, eax
    jnz .divide
.emit:
    pop eax
    add al, '0'
    call term_putc
    sub ecx, 1
    jnz .emit
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; 打印 AL 的两位十六进制(不带前缀)
term_print_byte:
    push eax
    push ebx
    mov ebx, eax
    shr al, 4
    call .nib
    mov eax, ebx
    call .nib
    pop ebx
    pop eax
    ret
.nib:
    and al, 0x0F
    cmp al, 10
    jb .dig
    add al, 'A' - 10
    jmp .out
.dig:
    add al, '0'
.out:
    call term_putc
    ret

; ============================================================================
;  数据
; ============================================================================
msg_title   db 'JoyOS - stage 5', 10, 0
msg_chain   db 'bootloader -> protected mode -> kernel', 10, 0
msg_sectors db 'kernel area: ', 0
msg_equals  db ' sectors = ', 0
msg_bytes   db ' bytes loaded from disk', 10, 0
msg_kmain   db 'kmain at ', 0
msg_pm      db '  (32-bit protected mode)', 10, 0
msg_seg     db 'DS = ', 0
msg_seg2    db '  (0x10 = our GDT data segment)', 10, 0
msg_disk    db 'boot disk: ', 0
msg_disk_lba db 'LBA (EDD multi-sector read)', 10, 0
msg_disk_chs db 'CHS fallback (BIOS has no LBA)', 10, 0
msg_idt     db 'IDT: 256 vectors installed (errors 0-31 have handlers)', 10, 0
msg_paging  db 'paging: CR0.PG=1, identity-mapped 0-4 MiB (+ 0x400000 -> 0x100000)', 10, 0
msg_kbd     db 'keyboard: PIC remapped to 0x20, IRQ1 enabled', 10, 0
msg_ok      db 'OK - stage 5: boot + protection + IDT + paging + keyboard + shell.', 10, 0

boot_sectors dd 0
boot_lba     dd 0
boot_mode    dd 0

term_row     db 0
term_col     db 0
term_color   db COL_NORMAL

; 函数里用到的小工具:把当前执行地址(kmain 的偏移)打出来
term_print_addr:
    push eax
    mov eax, kmain
    call term_print_hex
    pop eax
    ret

; ============================================================================
;  其它模块(平坦二进制 + %include,不用链接器)
;  注意:必须放在最后那个"补到 32 KiB"的 times 之前
; ============================================================================
%include "idt.asm"
%include "paging.asm"
%include "keyboard.asm"
%include "shell.asm"

; 内核区补到 32 KiB,这样"多扇区"是实打实的(不是只剩几百字节的代码)
times (64 * 512) - ($ - $$) db 0
