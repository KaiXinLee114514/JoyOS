; ============================================================================
;  JoyOS (胡闹OS) — 帧缓冲终端(图形模式下自己画字)
;
;  图形模式和文本模式的根本区别:文本模式把"字符码+颜色"两个字节写进 0xB8000,
;  字形由显卡的字模表决定(所以我们才要跟 plane 2、map A/B 那一堆寄存器较劲);
;  图形模式下**屏幕就是一块显存**,写进去的就是像素 —— 字怎么画、画多大、画什么颜色,
;  全由我们自己决定。代价是终端(光标、换行、滚屏)得自己实现。
;
;  像素格式:VBE 32 位色,每像素 4 字节,顺序 0x00RRGGBB(标准 VBE 直接色模式的位域:
;  红在 bit16、绿在 bit8、蓝在 bit0 —— 这台的 BOOTINFO 里也是这么报的)。
;  每行不是 width*4 字节就完了,要用 BOOTINFO 给的 pitch(扫描线字节数)来定位下一行。
;
;  字模数据:font/font-joyf.bin(tools/unifont2bin.py 生成)
;       +0  'J''O''Y''F'   +4 版本   +8 字形数   +12 数据区偏移
;       每项 12 字节:码位(4) 宽(1) 高(1) 保留(2) 数据偏移(4),按码位升序 → 二分查找
;      8 宽(ASCII)每行 1 字节,16 宽(汉字)每行 2 字节,最高位在最左
; ============================================================================

FB_CELL_H   equ 16                      ; 字符格高(像素)

; ---------------------------------------------------------------------------
;  fb_color_of:属性字节(和文本模式一样的 0x0B 那种)→ 0x00RRGGBB
; ---------------------------------------------------------------------------
fb_color_of:
    and al, 0x0F
    movzx eax, al
    mov eax, [fb_palette + eax * 4]
    ret

; ---------------------------------------------------------------------------
;  fb_set_pos:把光标(字符格坐标)换算成像素坐标
; ---------------------------------------------------------------------------
fb_home:
    mov dword [fb_cur_x], 0
    mov dword [fb_cur_y], 0
    ret

; ---------------------------------------------------------------------------
;  fb_clear:整屏涂黑,光标回左上
; ---------------------------------------------------------------------------
fb_clear:
    pushad
    mov edi, [fb_phys]
    mov ecx, [fb_height]
.row:
    push ecx
    push edi
    mov ecx, [fb_pitch]
    shr ecx, 2                          ; 每行像素数(= dword 数)
    xor eax, eax
    rep stosd
    pop edi
    add edi, [fb_pitch]
    pop ecx
    dec ecx
    jnz .row
    call fb_home
    popad
    ret

; ---------------------------------------------------------------------------
;  fb_scroll:整屏往上滚 FB_CELL_H 行,底部清空
; ---------------------------------------------------------------------------
fb_scroll:
    pushad
    mov esi, [fb_phys]
    mov eax, [fb_pitch]
    imul eax, FB_CELL_H
    add esi, eax                        ; 源 = 第 16 行开始
    mov edi, [fb_phys]                  ; 目标 = 第 0 行
    mov eax, [fb_height]
    sub eax, FB_CELL_H
    imul eax, [fb_pitch]                ; 要搬的字节数
    shr eax, 2
    mov ecx, eax
    rep movsd
    ; 底部 16 行清黑
    mov edi, [fb_phys]
    mov eax, [fb_pitch]
    mov edx, [fb_height]
    sub edx, FB_CELL_H
    imul eax, edx
    add edi, eax
    mov ecx, [fb_pitch]
    shr ecx, 2
    imul ecx, FB_CELL_H
    xor eax, eax
    rep stosd
    popad
    ret

; ---------------------------------------------------------------------------
;  fb_blit:把字模点阵画到屏幕上
;    eax = x(像素) ebx = y(像素) esi = 点阵数据 ecx = 宽(8 或 16) edx = 颜色
; ---------------------------------------------------------------------------
fb_blit:
    pushad
    mov [blit_x], eax
    mov [blit_y], ebx
    mov [blit_data], esi
    mov [blit_w], ecx
    mov [blit_color], edx

    ; ---- 先涂黑这块矩形(相当于"擦掉原来的字")----
    xor ebp, ebp                        ; 行
.bg_row:
    mov edi, [fb_phys]
    mov eax, [fb_pitch]
    mov ecx, [blit_y]
    add ecx, ebp
    imul eax, ecx
    add edi, eax
    mov eax, [blit_x]
    lea edi, [edi + eax * 4]
    mov ecx, [blit_w]
    xor eax, eax
.bg_px:
    mov [edi], eax
    add edi, 4
    dec ecx
    jnz .bg_px
    inc ebp
    cmp ebp, FB_CELL_H
    jb .bg_row

    ; ---- 再画有点的像素 ----
    xor ebp, ebp                        ; 行号
.row:
    mov esi, [blit_data]
    cmp dword [blit_w], 8
    jne .wide
    movzx eax, byte [esi + ebp]         ; 8 宽:每行 1 字节
    shl eax, 8                          ; 挪到高位,和 16 宽统一用 bit15 开始判断
    mov ecx, 8
    jmp .draw
.wide:
    movzx eax, word [esi + ebp * 2]     ; 16 宽:每行 2 字节
    rol ax, 8                           ; ★ 把左右两半换回来:低地址那个字节才是左半边,
    ;                                    而它在这个 16 位字里是**低位**,不换的话
    ;                                    笔画会左右颠倒(bit15 是右半边的最高位)
    mov ecx, 16
.draw:
    ; eax = 该行的位图,ecx = 位数,从最高位开始画
    mov edx, ecx                        ; edx 当位计数
.bit:
    test eax, 0x8000                    ; 用 16 位判断,8 宽时高位自然是 0
    jz .next_bit
    ; 画一个像素:位置 = (blit_x + (位数 - 剩余位), blit_y + 行号)
    push eax
    mov edi, [fb_phys]
    mov eax, [fb_pitch]
    mov ecx, [blit_y]
    add ecx, ebp
    imul eax, ecx
    add edi, eax
    mov eax, [blit_w]
    mov ecx, edx                        ; 剩余位数 → 当前列 = 总列数 - 剩余
    mov ecx, [blit_w]
    sub ecx, edx
    add ecx, [blit_x]
    lea edi, [edi + ecx * 4]
    mov eax, [blit_color]
    mov [edi], eax
    pop eax
.next_bit:
    shl eax, 1
    dec edx
    jnz .bit
    inc ebp
    cmp ebp, FB_CELL_H
    jb .row

    popad
    ret

; ---------------------------------------------------------------------------
;  fb_glyph:按 Unicode 码位查字模 → eax = 点阵地址, ecx = 宽(8/16);没找到返回 eax=0
;  二分查找(表按码位升序)
; ---------------------------------------------------------------------------
fb_glyph:
    push ebx
    push edx
    push esi
    push edi
    mov [want_cp], eax
    mov ebx, [font_base]                ; 默认是内建子集;读了磁盘字库就换成它
    mov edx, [ebx + 8]                  ; 字形数
    mov edi, [ebx + 12]                 ; 数据区偏移
    add edi, ebx                        ; edi = 数据区基址
    mov esi, 16                         ; 表项从 +16 开始,每项 12 字节
    xor ecx, ecx                        ; 左
    mov eax, edx                        ; 右(不含)
.find:
    cmp ecx, eax
    jae .miss
    mov edx, eax
    sub edx, ecx
    shr edx, 1
    add edx, ecx                        ; mid
    mov ebx, edx
    imul ebx, 12
    add ebx, 16
    add ebx, [font_base]                ; → 表项地址
    mov eax, [ebx]                      ; 该项的码位
    cmp eax, [want_cp]
    je .hit
    jb .go_right
    mov eax, edx                        ; 在左半区
    jmp .find
.go_right:
    lea ecx, [edx + 1]
    mov eax, [font_base]
    mov eax, [eax + 8]
    jmp .find
.hit:
    movzx ecx, byte [ebx + 4]           ; 宽
    mov eax, [ebx + 8]                  ; 数据偏移
    add eax, edi
    jmp .out
.miss:
    xor eax, eax
    xor ecx, ecx
.out:
    pop edi
    pop esi
    pop edx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  fb_putc:al = 字符(支持 \n \r \b;>=0x80 当 Unicode 码位走汉字路径)
; ---------------------------------------------------------------------------
fb_putc:
    pushad
    movzx eax, al
    cmp al, 10
    je .newline
    cmp al, 13
    je .cr
    cmp al, 8
    je .bs

    movzx eax, al
    call fb_putcp
    jmp .done

.newline:
    call fb_newline
    jmp .done
.cr:
    mov dword [fb_cur_x], 0
    jmp .done
.bs:
    mov eax, [fb_cur_x]
    test eax, eax
    jz .done
    sub eax, 8                          ; 退一格(汉字 16 宽时退半格,够用了)
    mov [fb_cur_x], eax
    mov esi, blank_glyph
    mov eax, [fb_cur_x]
    mov ebx, [fb_cur_y]
    mov edx, [term_fb_color]
    mov ecx, 8
    call fb_blit
.done:
    popad
    ret

; ---------------------------------------------------------------------------
;  fb_putcp:eax = Unicode 码位 → 画出这个字并推进光标(自动换行)
;  这就是图形模式的好处:码位直接查表,不用管什么字体表 A/B、字模号 0x80 起那些事
; ---------------------------------------------------------------------------
fb_putcp:
    pushad
    call fb_glyph                       ; eax = 点阵地址, ecx = 宽
    test eax, eax
    jz .miss
    mov [cur_glyph_w], ecx
    mov esi, eax
    mov eax, [fb_cur_x]
    mov ebx, [fb_cur_y]
    mov edx, [term_fb_color]
    call fb_blit
    mov eax, [cur_glyph_w]
    add [fb_cur_x], eax
    mov eax, [fb_width]
    cmp [fb_cur_x], eax
    jb .done
    call fb_newline
    jmp .done
.miss:
    ; 字库里没有:画一个方框占位,免得整行错位
    mov esi, missing_glyph
    mov eax, [fb_cur_x]
    mov ebx, [fb_cur_y]
    mov edx, [term_fb_color]
    mov ecx, 8
    call fb_blit
    add dword [fb_cur_x], 8
.done:
    popad
    ret

; ---------------------------------------------------------------------------
;  fb_putcp_at:eax = 码位,ebx = 行,ecx = 列 → 就画在那一格上(不动全局光标)
;      → [pa_cells] = 这个字占了几格(ASCII 1 格,汉字 2 格)
;  全屏程序(编辑器)用它重画指定位置,和 fb_putcp 的区别就是"光标不动、不换行"。
; ---------------------------------------------------------------------------
fb_putcp_at:
    push esi                            ; ★ 必须保住调用方的 esi:term_puts_at 把它当 UTF-8 游标用,
    ;                                     而下面要 esi = 点阵地址。不存的话第一轮循环之后
    ;                                     游标就飘进点阵里了 —— 现象是"一行只画出第一个字"。
    mov [pa_cp], eax
    mov [pa_row], ebx
    mov [pa_col], ecx
    call fb_glyph                       ; eax = 点阵, ecx = 宽(像素)
    test eax, eax
    jz .miss
    mov esi, eax
    mov [pa_w], ecx
    mov eax, [pa_col]
    shl eax, 3                          ; 列 → 像素
    mov ebx, [pa_row]
    shl ebx, 4                          ; 行 → 像素
    mov edx, [term_fb_color]
    mov ecx, [pa_w]
    call fb_blit
    mov eax, [pa_w]
    shr eax, 3                          ; 像素宽 → 格数
    mov [pa_cells], eax
    pop esi
    ret
.miss:
    ; 字库里没这个字:画方框占一格,免得整行错位
    mov esi, missing_glyph
    mov eax, [pa_col]
    shl eax, 3
    mov ebx, [pa_row]
    shl ebx, 4
    mov edx, [term_fb_color]
    mov ecx, 8
    call fb_blit
    mov dword [pa_cells], 1
    pop esi
    ret

fb_newline:
    mov dword [fb_cur_x], 0
    mov eax, [fb_cur_y]
    add eax, FB_CELL_H
    mov [fb_cur_y], eax
    ; ★ 底边必须"夹到 16 的整数倍":屏幕高度不一定能被 16 整除
    ;   (800×600 → 600 = 37×16 + 8,最下面 8 像素是半个格子)。
    ;   以前这里夹到 600-16 = 584,584 % 16 = 8 —— 一旦滚屏,新写的每一行
    ;   都比滚上去的旧行低 8 像素,于是"两代字叠在一起":QEMU 里表现为
    ;   上下各半行的重影,VirtualBox 里相位越滚越乱、整屏花掉(踩过)。
    ;   先把高度按 16 对齐,再减一行,光标就永远落在格子线上。
    mov ebx, [fb_height]
    and ebx, ~(FB_CELL_H - 1)           ; 向下取整到 16 的倍数:600 → 592
    sub ebx, FB_CELL_H                  ; 最后一行的起点:592-16 = 576 = 36×16
    cmp eax, ebx
    jbe .ok
    mov [fb_cur_y], ebx
    call fb_scroll
.ok:
    ret

; ---------------------------------------------------------------------------
;  fb_init:记下参数 + 清屏
; ---------------------------------------------------------------------------
fb_init:
    mov eax, [fb_phys]
    mov [fb_cur_x], dword 0
    mov [fb_cur_y], dword 0
    mov [term_fb_color], dword 0x00AAAAAA
    call fb_clear
    ret

; ---------------------------------------------------------------- 数据
fb_palette:
    dd 0x00000000, 0x000000AA, 0x0000AA00, 0x0000AAAA
    dd 0x00AA0000, 0x00AA00AA, 0x00AA5500, 0x00AAAAAA
    dd 0x00555555, 0x005555FF, 0x0055FF55, 0x0055FFFF
    dd 0x00FF5555, 0x00FF55FF, 0x00FFFF55, 0x00FFFFFF

blank_glyph: times 16 db 0
; 字库缺字时画的占位框(8×16 空心框)
missing_glyph:
    db 0xFF, 0x81, 0x81, 0x81, 0x81, 0x81, 0x81, 0x81
    db 0x81, 0x81, 0x81, 0x81, 0x81, 0x81, 0x81, 0xFF

fb_cur_x        dd 0
fb_cur_y        dd 0
cur_glyph_w     dd 8
term_fb_color   dd 0x00AAAAAA

; fb_putcp_at 用的临时变量(不能借用 fb_cur_x/y —— 那两个字要保住)
pa_cp           dd 0
pa_row          dd 0
pa_col          dd 0
pa_w            dd 8
pa_cells        dd 1
blit_x          dd 0
blit_y          dd 0
blit_w          dd 8
blit_color      dd 0
blit_data       dd 0
want_cp         dd 0

; 内建字库(小):ASCII + 三百来个常用汉字。磁盘字库读成功后 font_base 会指向它
font_blob:
    incbin "font/font-joyf.bin"
