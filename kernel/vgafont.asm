; ============================================================================
;  JoyOS (胡闹OS) — 把自己的点阵字模装进 VGA(中文显示的地基)
;
;  ── 取址公式(从 QEMU 的 hw/display/vga.c 里读出来的,不是我猜的) ────────
;      v = Sequencer 0x03(Character Map Select)
;      font_base[0] = (((v>>4)&1) | ((v<<1)&6)) * 8192 + 0      ; ← 表 A
;      font_base[1] = (((v>>5)&1) | ((v>>1)&6)) * 8192 + 0      ; ← 表 B
;      用哪张表:font = font_base[(属性字节 >> 3) & 1]           ; 属性 bit3!
;      字符 ch 的第 r 行 = plane2[ font + 32*ch + r ]
;
;  两个"和直觉不一样"的地方,正是我踩了两轮的坑:
;   1. **每个字符占 32 字节**,不是 16(字高最大 32 行,硬件就按 32 字节一格排)。
;      按 16 字节排表 → 每个字都被读成"上一个字的后半 + 下一个字的前半",整屏错位。
;   2. **表 A/B 由属性字节的 bit3 选,跟字符码无关**。BIOS 默认 Sequencer 0x03=0x03
;      时算出:表 A 基址 = 0xC000,表 B 基址 = 0x0000。我们的终端里普通文本用 0x07
;      (bit3=0 → 表 A = 0xC000 = BIOS 那套),亮色 0x0B/0x0A/0x0C(bit3=1 → 表 B = 0)
;      —— 于是就出现"有的行是我换的字模、有的行还是 BIOS 的"。
;      解决:把 Sequencer 0x03 设成 0,让**两张表都指向偏移 0**,那就怎么都对。
;
;  ── 另外两个坑 ──────────────────────────────────────────────────────────
;   3. 文本模式下 GC 0x06 的内存映射位默认是 3(只映射 B8000-BFFFF 那 32 KB),
;      这时往 A0000 写字模全写进空气 —— 屏幕上纹丝不动,极唬人。
;      先把 bit3-2 清 0(A0000-BFFFF 全 128 KB)。
;   4. 9 点字符时钟:Sequencer 0x01 的 bit0 **置 1** 才是每字符 8 点;
;      默认 9 点会让劈成两半的汉字中间多一道竖缝。
;
;  ── 汉字为什么占两个字符格 ──────────────────────────────────────────────
;  文本模式一个字符格只有 8 像素宽,汉字 16×16 一格塞不下。把点阵从中间劈开:
;  左 8 列放字模号 N,右 8 列放 N+1,打印时连写两个字符码即可。
;  字符码 0x80-0xFE 这么用 → 最多 63 个汉字(想更多就得上图形模式)。
; ============================================================================

VGA_MEM_BASE equ 0xA0000                ; 显存窗口(靠它访问各 plane)
SEQ_IDX      equ 0x3C4                  ; 定序器:先写索引,再读/写数据
SEQ_DAT      equ 0x3C5
GC_IDX       equ 0x3CE                  ; 图形控制器:同上
GC_DAT       equ 0x3CF
FONT_SIZE    equ 256 * 32               ; 256 个字符 × 32 字节 = 8192

; ---------------------------------------------------------------------------
;  vgafont_init:两张表都指到 0 → 8 点时钟 → 开显存窗口 → 开 plane 2 写权限
;               → 写 8 KB 字模 → 复原
; ---------------------------------------------------------------------------
vgafont_init:
    pushad

    ; ---- 1) 表 A / 表 B 都指向 plane 2 偏移 0(见文件头坑 2)----
    mov dx, SEQ_IDX
    mov al, 0x03                        ; Character Map Select
    out dx, al
    inc dx
    in  al, dx
    mov [seq03_saved], al
    xor al, al                          ; 0 → 两张表基址都是 0
    out dx, al

    ; ---- 2) 每字符 8 点(关掉第 9 点),汉字两半才能无缝 ----
    mov dx, SEQ_IDX
    mov al, 0x01                        ; Clocking Mode
    out dx, al
    inc dx
    in  al, dx
    mov [seq01_saved], al
    or  al, 0x01                        ; bit0 = 1 → 8 点
    out dx, al

    ; ---- 3) 打开 CPU 的显存窗口:GC 0x06 bit3-2 = 0 → A0000-BFFFF ----
    mov dx, GC_IDX
    mov al, 0x06                        ; Miscellaneous
    out dx, al
    inc dx
    in  al, dx
    mov [gc06_saved], al
    and al, 0xF3
    out dx, al

    ; ---- 4) 允许顺序写 plane 2 ----
    mov dx, SEQ_IDX
    mov al, 0x04                        ; Memory Mode
    out dx, al
    inc dx
    in  al, dx
    mov [seq04_saved], al
    or  al, 0x04                        ; bit2 = 1 → 关 odd/even 交叉寻址
    out dx, al

    mov dx, SEQ_IDX
    mov al, 0x02                        ; Map Mask
    out dx, al
    inc dx
    in  al, dx
    mov [seq02_saved], al
    mov al, 0x04                        ; 只写 plane 2
    out dx, al

    mov dx, GC_IDX
    mov al, 0x05                        ; Graphics Controller Mode
    out dx, al
    inc dx
    in  al, dx
    mov [gc05_saved], al
    and al, 0xEF                        ; bit4 = 0 → 关 odd/even
    out dx, al

    ; ---- 5) 写 8 KB 字模到 plane 2 偏移 0 ----
    mov esi, vga_font_blob
    mov edi, VGA_MEM_BASE
    mov ecx, FONT_SIZE
    rep movsb

    ; ---- 6) 复原(Sequencer 0x03 和时钟位不恢复:它们要长期生效)----
    mov dx, GC_IDX
    mov al, 0x05
    out dx, al
    inc dx
    mov al, [gc05_saved]
    out dx, al

    mov dx, GC_IDX
    mov al, 0x06
    out dx, al
    inc dx
    mov al, [gc06_saved]
    out dx, al

    mov dx, SEQ_IDX
    mov al, 0x02
    out dx, al
    inc dx
    mov al, [seq02_saved]
    out dx, al

    mov dx, SEQ_IDX
    mov al, 0x04
    out dx, al
    inc dx
    mov al, [seq04_saved]
    out dx, al

    popad
    ret

; ---------------------------------------------------------------------------
;  term_print_cp:打一个 Unicode 码位(eax)
;    ASCII(<0x80)直接打;汉字查映射表,连着打两个字格
; ---------------------------------------------------------------------------
term_print_cp:
    cmp dword [vbe_ok], 0
    jne fb_putcp                        ; 图形模式:码位直接查表画字,不用字模号那套
    push eax
    push ebx
    push ecx
    push edx
    push esi
    mov edx, eax
    cmp edx, 0x80
    jb .ascii

    mov esi, vga_zh_map
    mov ecx, vga_zh_count
.scan:
    test ecx, ecx
    jz .missing
    cmp dword [esi], edx
    je .found
    add esi, 5                          ; 每条 5 字节:dd 码位 + db 字模号
    dec ecx
    jmp .scan

.found:
    mov al, [esi + 4]                   ; 左半边
    call term_putc
    mov al, [esi + 4]
    inc al                              ; 右半边 = 左半边 + 1
    call term_putc
    jmp .done

.ascii:
    mov eax, edx
    call term_putc
    jmp .done

.missing:
    mov al, '?'                         ; 字库里没这个字
    call term_putc

.done:
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  term_print_zh:esi → 以 0 结尾的码位数组(见 font/vga-zh-strings.asm)
; ---------------------------------------------------------------------------
term_print_zh:
    push eax
    push esi
.next:
    mov eax, [esi]
    test eax, eax
    jz .done
    call term_print_cp
    add esi, 4
    jmp .next
.done:
    pop esi
    pop eax
    ret

; ---------------------------------------------------------------------------
;  数据:映射表 + 文案(都是 tools/unifont2bin.py 生成的)+ 4 KB 字模
; ---------------------------------------------------------------------------
%include "font/vga-zh-map.asm"
%include "font/vga-zh-strings.asm"

vga_font_blob:
    incbin "font/vga-font.bin"

seq01_saved db 0
seq02_saved db 0
seq03_saved db 0
seq04_saved db 0
gc05_saved  db 0
gc06_saved  db 0
