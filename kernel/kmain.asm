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

BOOTINFO   equ 0x8000
VGA_MEM    equ 0xB8000
VGA_COLS   equ 80
VGA_ROWS   equ 25

COL_NORMAL equ 0x07                    ; 浅灰
COL_HEADER equ 0x0B                    ; 亮青
COL_OK     equ 0x0A                    ; 亮绿
COL_ERR    equ 0x0C                    ; 亮红

    ; 启动参数由引导扇区/实模式 stub 写在固定地址 BOOTINFO(0x8000)
    mov eax, [BOOTINFO + 4]
    mov [boot_sectors], eax            ; 内核区扇区数
    mov eax, [BOOTINFO + 8]
    mov [boot_lba], eax                ; 内核起始 LBA
    mov eax, [BOOTINFO + 12]
    mov [boot_mode], eax               ; 1 = LBA(EDD),0 = CHS 退回
    mov eax, [BOOTINFO + 64]
    mov [vbe_ok], eax                  ; 1 = 拿到图形模式
    mov eax, [BOOTINFO + 16]
    mov [fb_phys], eax
    mov eax, [BOOTINFO + 20]
    mov [fb_width], eax
    mov eax, [BOOTINFO + 24]
    mov [fb_height], eax
    mov eax, [BOOTINFO + 28]
    mov [fb_pitch], eax
    mov eax, [BOOTINFO + 32]
    mov [fb_bpp], eax

    ; ---- 字库:先从磁盘尝试读完整版(读不到就退回内建子集)----
    call font_load_from_disk

    ; 图形模式:先把帧缓冲终端初始化(它自己会清屏,所以要在任何打印之前)
    cmp dword [vbe_ok], 0
    je .skip_fb_early
    call fb_init
.skip_fb_early:

%ifdef USE_CUSTOM_FONT
    call vgafont_init                  ; 实验中的自定义点阵字模(见 font/README.md)
%endif

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

%ifdef USE_CUSTOM_FONT
    ; 中文自检:这一行是从 Unifont 点阵拼出来的
    mov esi, msg_zh_tag
    call term_print
    mov esi, zh_str_2                   ; "这是 JoyOS 的中文显示。"
    call term_print_zh
%endif

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

    ; (帧缓冲终端在开头已经初始化过 —— 它自带清屏,调两次会把前面的输出擦掉)

    ; ---- 报一下字库用了哪个 ----
    ; ---- 帧缓冲几何(排 QEMU / VirtualBox 差异:谁报的行距对不上一眼可见)----
    mov esi, msg_fbdump
    call term_print
    mov eax, [fb_phys]
    call term_print_hex
    mov esi, msg_fbw
    call term_print
    mov eax, [fb_width]
    call term_print_dec
    mov esi, msg_fbh
    call term_print
    mov eax, [fb_height]
    call term_print_dec
    mov esi, msg_fbp
    call term_print
    mov eax, [fb_pitch]
    call term_print_dec
    mov esi, msg_fbb
    call term_print
    mov eax, [fb_bpp]
    call term_print_dec
    mov esi, msg_fbmi16
    call term_print
    mov eax, [BOOTINFO + 80]
    call term_print_dec
    mov esi, msg_fbmi32
    call term_print
    mov eax, [BOOTINFO + 84]
    call term_print_dec
    mov esi, msg_fbvbe
    call term_print
    mov eax, [BOOTINFO + 76]
    call term_print_hex
    mov al, 10
    call term_putc

    mov esi, msg_font
    call term_print
    cmp dword [font_from_disk], 0
    je .font_builtin
    mov esi, msg_font_disk
    call term_print
    jmp .font_done
.font_builtin:
    mov esi, msg_font_builtin
    call term_print
.font_done:
    mov eax, [font_glyphs]
    call term_print_dec
    mov esi, msg_font_glyphs
    call term_print

    ; ---- 文件系统 + 程序接口 ----
    call fat_mount
    call api_install
    cmp byte [fat_ok], 0
    je .fs_none_print
    cmp byte [fat_fat32], 0
    je .fs16
    mov esi, msg_fs32
    call term_print
    jmp .fs_done
.fs16:
    mov esi, msg_fs
    call term_print
    mov esi, msg_fs_ok
    call term_print
    jmp .fs_done
.fs_none_print:
    mov esi, msg_fs
    call term_print
    jmp .fs_none
.fs_none:
    mov esi, msg_fs_none
    call term_print
.fs_done:

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
    cmp dword [vbe_ok], 0
    jne fb_clear
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

; al = 颜色属性(文本模式直接存;图形模式还要换算成 RGB)
term_set_color:
    mov [term_color], al
    push eax
    call fb_color_of
    mov [term_fb_color], eax
    pop eax
    ret

; al = 字符(支持 \n \r \b)
term_putc:
    cmp dword [vbe_ok], 0
    jne fb_putc                         ; 图形模式:走帧缓冲终端
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
    cmp dword [vbe_ok], 0
    jne .skip                           ; 图形模式没有硬件字符光标
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
.skip:
    ret

; ============================================================================
;  全屏程序要用的三个终端功能(编辑器那种"画面由我控制"的程序)
;
;  普通程序用 term_print 一行行往下吐就行,但编辑器要**在屏幕任意位置写字**、
;  要**知道屏幕多大**、还要**不滚屏**(滚屏会把刚画好的界面顶掉)。
;  所以这里给三个:定位光标、问屏幕大小、在指定位置画一串字。
; ============================================================================

; ---------------------------------------------------------------------------
;  term_size:→ eax = 每行几个字符格,ebx = 几行
;  字符格 = 8 像素宽、16 像素高(VGA 文本模式固定 80×25)
; ---------------------------------------------------------------------------
term_size:
    cmp dword [vbe_ok], 0
    jne .fb
    mov eax, VGA_COLS
    mov ebx, VGA_ROWS
    ret
.fb:
    mov eax, [fb_width]
    shr eax, 3                          ; 像素宽 ÷ 8
    mov ebx, [fb_height]
    shr ebx, 4                          ; 像素高 ÷ 16
    ret

; ---------------------------------------------------------------------------
;  term_set_cursor:ebx = 行,ecx = 列(超出屏幕就夹到边界内)
; ---------------------------------------------------------------------------
term_set_cursor:
    push eax
    push ebx
    push ecx
    cmp dword [vbe_ok], 0
    jne .fb

    ; ---- 文本模式:行/列各自夹住 ----
    cmp ebx, VGA_ROWS
    jb .row_ok
    mov ebx, VGA_ROWS - 1
.row_ok:
    cmp ecx, VGA_COLS
    jb .col_ok
    mov ecx, VGA_COLS - 1
.col_ok:
    mov [term_row], bl
    mov [term_col], cl
    call term_move_hw_cursor
    jmp .done

.fb:
    ; ---- 图形模式:光标是像素坐标(fb_cur_x / fb_cur_y)----
    call term_size                      ; eax = 列数,ebx = 行数
    cmp ecx, eax
    jb .fcol_ok
    lea ecx, [eax - 1]
.fcol_ok:
    mov eax, [fb_height]
    shr eax, 4
    cmp ebx, eax
    jb .frow_ok
    lea ebx, [eax - 1]
.frow_ok:
    shl ecx, 3                          ; 列 × 8 像素
    shl ebx, 4                          ; 行 × 16 像素
    mov [fb_cur_x], ecx
    mov [fb_cur_y], ebx
.done:
    pop ecx
    pop ebx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  term_puts_at:在指定位置画一串 UTF-8 字,**不滚屏、不动全局光标**
;      esi = 字符串   ebx = 行   ecx = 列   edx = 这一行最多占几个字符格
;      → eax = 实际占了几格
;  编辑器靠它重画一行:先定位,再整行写过去。写到 edx 就不写了(免得顶到
;  屏幕最后一格触发换行 → 滚屏,把界面顶掉)。
;  文本模式下只画 ASCII(8 像素的格子塞不下汉字),非 ASCII 画成 '?'。
; ---------------------------------------------------------------------------
term_puts_at:
    pushad
    mov [tpa_row], ebx
    mov [tpa_col], ecx
    mov [tpa_start], ecx
    mov [tpa_max], edx
.next:
    call utf8_decode                    ; eax = 码位(0 = 到头),esi 前进
    test eax, eax
    jz .done
    cmp eax, 10                         ; 换行:这一行画到这儿就够了
    je .done
    cmp eax, 13
    je .done
    cmp eax, 0x20
    jb .next                            ; 其它控制字符不画
    cmp dword [vbe_ok], 0
    je .text

    ; ---- 图形模式:先问字形多宽,放不下就停(不画半个字)----
    mov [tpa_cp], eax
    call fb_glyph                       ; eax = 点阵, ecx = 宽(像素)
    test eax, eax
    jnz .have_w
    mov ecx, 8                          ; 字库没这个字:按 8 像素(方框)算
.have_w:
    shr ecx, 3                          ; 像素 → 格
    mov eax, [tpa_col]
    add eax, ecx
    cmp eax, [tpa_max]
    ja .done
    mov eax, [tpa_cp]
    mov ebx, [tpa_row]
    mov ecx, [tpa_col]
    call fb_putcp_at                    ; → [pa_cells] = 占几格
    mov eax, [pa_cells]
    add [tpa_col], eax
    jmp .check

.text:
    cmp eax, 0x80
    jb .ascii
    mov eax, '?'                        ; 文本模式画不了汉字,给个记号
.ascii:
    mov edx, [tpa_row]
    imul edx, VGA_COLS                  ; 行 × 80
    add edx, [tpa_col]
    shl edx, 1                          ; 每格 2 字节
    add edx, VGA_MEM
    mov [edx], al
    mov al, [term_color]
    mov [edx + 1], al
    inc dword [tpa_col]

.check:
    mov eax, [tpa_col]
    cmp eax, [tpa_max]
    jb .next
.done:
    mov eax, [tpa_col]
    sub eax, [tpa_start]
    mov [tpa_written], eax
    popad
    mov eax, [tpa_written]
    ret

; esi = 以 0 结尾的 **UTF-8** 字符串
; (以前是逐字节 lodsb,现在先解码成码位再画 —— 这样中英都走一条路,而且跟外界一致)
term_print:
    push eax
    push esi
.next:
    call utf8_decode                    ; eax = 码位(0 = 到头了),esi 前进
    test eax, eax
    jz .done
    call term_print_cp
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
msg_fbdump  db 'fb: phys=', 0
msg_fbw     db ' w=', 0
msg_fbh     db ' h=', 0
msg_fbp     db ' pitch=', 0
msg_fbb     db ' bpp=', 0
msg_fbmi16  db '  modeinfo: bytesPerScanLine=', 0
msg_fbmi32  db ' linBytesPerScanLine=', 0
msg_fbvbe   db ' vbe=0x', 0
msg_zh_tag  db 'zh  : ', 0
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
msg_font    db 'font: ', 0
msg_font_disk    db 'loaded from disk (ATA), ', 0
msg_font_builtin db 'built-in subset, ', 0
msg_font_glyphs  db ' glyphs', 10, 0
msg_fs      db 'fat16: ', 0
msg_fs_ok   db 'mounted at LBA 6144 (ls / cat / write / run)', 10, 0
msg_fs_none db 'not available (floppy boot?)', 10, 0
msg_fs32    db 'fat32: mounted at LBA 6144 (BPB 里的 f16 扇区数 = 0 → 32 位 FAT,根目录是簇链)', 10, 0
msg_ok      db 'OK - stage 5: boot + protection + IDT + paging + keyboard + shell.', 10, 0

vbe_ok       dd 0
fb_phys      dd 0
fb_width     dd 0
fb_height    dd 0
fb_pitch     dd 0
fb_bpp       dd 0

boot_sectors dd 0
boot_lba     dd 0
boot_mode    dd 0

term_row     db 0
term_col     db 0
term_color   db COL_NORMAL

; 全屏 API(term_puts_at / term_set_cursor)用的临时变量
tpa_row      dd 0
tpa_col      dd 0
tpa_start    dd 0
tpa_max      dd 0
tpa_cp       dd 0
tpa_written  dd 0

; 函数里用到的小工具:把当前执行地址(kmain 的偏移)打出来
term_print_addr:
    push eax
    mov eax, kmain
    call term_print_hex
    pop eax
    ret

