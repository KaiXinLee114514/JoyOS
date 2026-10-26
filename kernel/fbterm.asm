; ============================================================================
;  JoyOS — 帧缓冲终端(图形模式下自己画字)
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
FB_LINE_PAGES equ 13                    ; 行缓冲要的页数:13 × 4096 = 53248 B
                                        ;   (800 像素 × 16 扫描行 × 4 B = 51200 B,
                                        ;    多要的那一页是给 pitch 留的余量)

; ---------------------------------------------------------------------------
;  fb_color_of:属性字节(和文本模式一样的 0x0B 那种)→ 0x00RRGGBB
; ---------------------------------------------------------------------------
fb_color_of:
    ; ★ 属性字节(VGA 那套)里有两位信息:低半字节 = 背景,高半字节 = 前景。
    ;   以前只取"低半字节"当前景色 —— 普通文字 0x07(浅灰)刚好等于低半字节 7,
    ;   所以一直没露馅;但**反白/高亮**是 0x70(高半字节 7、低半字节 0)⇒ 被当成
    ;   黑色 ⇒ 黑底黑字,整行看不见(vi 的状态行、计算器标题栏就是这么消失的)。
    ;   现在:高半字节非 0 就用它(高亮可见),否则退回低半字节(普通文字)。
    mov dl, al
    shr al, 4
    and al, 0x07
    jnz .have
    mov al, dl
    and al, 0x0F
.have:
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
    ; ★ 行缓冲里攒的东西现在和显存对不上了 —— 但整屏都要黑,没必要刷,
    ;   直接作废(脏标志清零 + 行号失效,下一笔字来了重新认领)。
    ;   千万**不能**留着脏标志:留着的话下次刷的时候会把擦屏前的旧像素
    ;   糊回干净的屏幕上(现象:清屏之后屏幕上还挂着半行字)。
    call fb_lb_forget
    call fb_home
    popad
    ret

; ---------------------------------------------------------------------------
;  fb_scroll:整屏往上滚 FB_CELL_H 行,底部清空
; ---------------------------------------------------------------------------
fb_scroll:
    pushad
    call fb_flush                       ; ★ 先把当前行落盘:要滚的是显存里的东西,
                                        ;   脏着滚就等于把最后一行扔了
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
    ; 滚过之后,缓冲里那一行已经不是显存里的那一行了(显存整体上移了一行)——
    ; 脏标志和行号都作废。虽然刚刷过(dirty=0),但行号必须失效,
    ; 否则光标落回最后一行时会被错当成"还在缓冲里",把旧像素刷到底行去。
    call fb_lb_forget
    popad
    ret

; ---------------------------------------------------------------------------
;  fb_lb_forget:丢掉行缓冲的记账(脏标志清零 + 行号失效)
;  用在"显存被整块改掉"的地方(擦屏、滚屏):缓冲里的内容不再可信。
; ---------------------------------------------------------------------------
fb_lb_forget:
    pushad
    mov dword [fb_dirty_line], 0
    mov dword [fb_lb_row], -1
    mov eax, [fb_width]
    mov [fb_lb_x0], eax                 ; 脏区清成空区间(起点 = 屏宽,终点 = 0)
    mov dword [fb_lb_x1], 0
    popad
    ret

; ---------------------------------------------------------------------------
;  fb_flush:把行缓冲里"脏"的那一段刷进显存
;
;  行缓冲模式下**这是唯一的显存出口**:平时画字只往 RAM 里写,到这里才把
;  "这一行里被改过的那段横坐标区间 × 16 个扫描行"一次性搬过去:
;      每扫描行一次 rep movsd,共 16 次
;  对比以前:每个字就要 16 次 32/64 字节的散写 —— 一行 40 个字就是 640 次。
;  搬的字节数差不多,但**段数**从"每字 16 段"降到"每行 16 段",而且每段
;  长得多(整行的 4~3200 字节,而不是 32 字节),在 QEMU 的 TCG 里差好几倍。
;
;  只刷"脏段"而不是整行 3200 字节:画的字都在游标走过的区间里,
;  区间的左右边界在 fb_blit 里顺手记下来(见 fb_lb_x0 / fb_lb_x1)。
;  这样既不碰屏幕上没画过的像素(不会把背景糊掉),字节数也更省。
;
;  没有行缓冲(页池要不到 52 KiB → 退回逐字直写)或没有脏数据时,直接返回。
; ---------------------------------------------------------------------------
fb_flush:
    pushad
    cmp dword [fb_dirty_line], 0
    je .out
    mov dword [fb_dirty_line], 0        ; 先清标志:下面就算是空区间也不会再刷
    mov esi, [fb_lb_base]
    test esi, esi
    jz .out
    mov ebx, [fb_lb_x1]
    sub ebx, [fb_lb_x0]                 ; 脏段宽度(像素 = dword 数)
    jbe .reset

    ; ---- 源:缓冲只装"当前这一行",所以永远是缓冲开头 + x0 像素 ----
    ;   (这里**不能**再加行号 × 16 × pitch 的偏移:缓冲里只有一行,
    ;    加了就等于去读分配区外面的野内存 —— 现象是只有第 0 行能显示。)
    mov eax, [fb_lb_x0]
    lea esi, [esi + eax * 4]
    ; ---- 目标:显存里同一行同一段 ----
    mov edi, [fb_phys]
    mov eax, [fb_lb_row]
    shl eax, 4
    imul eax, [fb_pitch]
    add edi, eax
    mov eax, [fb_lb_x0]
    lea edi, [edi + eax * 4]
    ; ---- 16 个扫描行,每行一次 rep movsd ----
    mov ebp, FB_CELL_H
.row:
    mov ecx, ebx
    push esi
    push edi
    rep movsd
    pop edi
    pop esi
    add esi, [fb_pitch]
    add edi, [fb_pitch]
    dec ebp
    jnz .row
.reset:
    mov eax, [fb_width]
    mov [fb_lb_x0], eax
    mov dword [fb_lb_x1], 0
.out:
    popad
    ret

; ---------------------------------------------------------------------------
;  fb_blit:把字模点阵画到屏幕上
;    eax = x(像素) ebx = y(像素) esi = 点阵数据 ecx = 宽(8 或 16) edx = 颜色
; ---------------------------------------------------------------------------
fb_blit:
    pushad
    ; ★ 越界保护:坐标或宽度离谱就什么都不画。
    ;   (以前没有这层保护:一旦算出来的 x/y 是野值,像素就写到帧缓冲外面,
    ;    运气不好正好写进内核自己的内存 —— 表现为"整块内存被写成同一个值"。)
    cmp eax, [fb_width]
    jae .skip
    cmp ebx, [fb_height]
    jae .skip
    cmp ecx, 16
    ja .skip
    test ecx, ecx
    jz .skip
    mov [blit_x], eax
    mov [blit_y], ebx
    mov [blit_data], esi
    mov [blit_w], ecx
    mov [blit_color], edx

    ; ---- 目标:行缓冲(有的话)还是显存 ----
    ;   ★ 有行缓冲时,字先画进 RAM 里的"当前行"(13 页 = 52 KiB,见 fb_init),
    ;     显存一个字节都不碰,只记下"这一行的哪一段被改了";等换行 / 滚屏 /
    ;     光标跳行 / 等待按键的时候由 fb_flush 一次性搬过去。
    ;     这就是这次重构的核心:把"每个字 16 次显存散写"摊成"每行 16 次整段搬"。
    mov edi, [fb_lb_base]
    test edi, edi
    jz .vram
    mov eax, [blit_y]
    shr eax, 4                          ; 目标行号(字符行)
    cmp eax, [fb_lb_row]
    je .adopt_done
    ; 换了一行(换行 / 光标跳行 / puts_at 换行):先把上一行的脏段落盘
    call fb_flush
    mov eax, [blit_y]
    shr eax, 4
    mov [fb_lb_row], eax                ; 认领这一行:缓冲里那段内容随画随覆盖,
                                        ; 只有记下来的脏段才会被刷进显存
.adopt_done:
    mov edi, [fb_lb_base]
    mov eax, [blit_y]
    and eax, FB_CELL_H - 1              ; 行内是第几个扫描行(0..15)
    imul eax, [fb_pitch]
    add edi, eax
    mov eax, [blit_x]
    lea edi, [edi + eax * 4]
    ; ---- 顺手把脏段的左右边界扩一下(fb_flush 只刷这一段)----
    mov eax, [blit_x]
    cmp eax, [fb_lb_x0]
    jae .x0_ok
    mov [fb_lb_x0], eax
.x0_ok:
    mov eax, [blit_x]
    add eax, [blit_w]
    cmp eax, [fb_lb_x1]
    jbe .x1_ok
    mov [fb_lb_x1], eax
.x1_ok:
    mov dword [fb_dirty_line], 1
    jmp .draw
.vram:
    ; 没有行缓冲(页池要不到 52 KiB):退回老路子,逐字直写显存(慢但不挂)
    mov edi, [fb_phys]
    mov eax, [blit_y]
    imul eax, [fb_pitch]
    add edi, eax
    mov eax, [blit_x]
    lea edi, [edi + eax * 4]

.draw:
    xor ebp, ebp                        ; 行号
.row:
    mov esi, [blit_data]
    mov edx, [blit_color]
    cmp dword [blit_w], 8
    jne .wide
    movzx eax, byte [esi + ebp]         ; 8 宽:1 字节 = 8 个像素
    call .byte8
    jmp .row_done
.wide:
    movzx eax, word [esi + ebp * 2]     ; 16 宽:2 字节 = 16 个像素
    rol ax, 8                           ; 低地址的字节是左半边
    push eax
    shr eax, 8                          ; 高字节 → 左边 8 格
    call .byte8
    pop eax
    and eax, 0xFF                       ; 低字节 → 右边 8 格
    call .byte8
.row_done:
    ; ★ 以前这里先把这一行攒进 fb_rowbuf、再 rep movsd 进显存;
    ;   现在 .byte8 直接写在目标上(行缓冲 / 显存),少一趟中转、少 16 次 rep movsd。
    add edi, [fb_pitch]
    mov eax, [blit_w]
    shl eax, 2
    sub edi, eax
    inc ebp
    cmp ebp, FB_CELL_H
    jb .row

    popad
    ret

; ---- 把 al 里的一个字节展开成 8 个像素,写到 [edi](写 8 个 dword)----
;   edx = 颜色,edi 自动前进 32 字节;表 fb_mask8 每项 8 个 dword
.byte8:
    movzx ecx, al
    shl ecx, 5                          ; 每项 8 dword = 32 字节
    add ecx, fb_mask8
    mov eax, [ecx + 0]
    and eax, edx
    mov [edi + 0], eax
    mov eax, [ecx + 4]
    and eax, edx
    mov [edi + 4], eax
    mov eax, [ecx + 8]
    and eax, edx
    mov [edi + 8], eax
    mov eax, [ecx + 12]
    and eax, edx
    mov [edi + 12], eax
    mov eax, [ecx + 16]
    and eax, edx
    mov [edi + 16], eax
    mov eax, [ecx + 20]
    and eax, edx
    mov [edi + 20], eax
    mov eax, [ecx + 24]
    and eax, edx
    mov [edi + 24], eax
    mov eax, [ecx + 28]
    and eax, edx
    mov [edi + 28], eax
    add edi, 32
    ret

.skip:
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
    cmp ecx, 8                          ; 只有 8 和 16 两种宽度
    jb .miss
    cmp ecx, 16
    ja .miss
    mov eax, [ebx + 8]                  ; 数据偏移
    add eax, edi
    ; ★ 越界保护:点阵必须落在字库区里(字库读了一半/表被写坏时,
    ;   这个指针会是野值,画出来的就是随机内存内容,甚至写到别处去)
    cmp eax, [font_base]
    jb .miss
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
    ; ★ 这里以前**没有**右边越界检查:一行里缺字多了,x 会一路涨出屏幕,
    ;   后面的像素就画到帧缓冲外面去了。和正常字一样,到边就换行。
    mov eax, [fb_width]
    cmp [fb_cur_x], eax
    jb .done
    call fb_newline
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
    call fb_flush                       ; ★ 换行 = 这一行写完了:先把它刷进显存
                                        ;   (以前是每个字直接写显存,没有这一步)
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
    mov [fb_cur_x], dword 0
    mov [fb_cur_y], dword 0
    mov [term_fb_color], dword 0x00AAAAAA
    ; ---- 行缓冲:找页池要 13 页连续的物理页(52 KiB)当"当前行" ----
    ;   ★ 为什么不放内核静态数据区:内核上限 128 KiB(boot 扇区只读 256 个扇区),
    ;     现在内容已经 ~85 KiB,再塞 51200 字节就顶死了;而 0x3B0000 往上
    ;     被 PINYIN 表和页池占着(页池从 0x400000 起)。所以走 pmem。
    ;   页池的位图在 0x3D0000、页从 4 MiB 起,都在恒等映射范围内,指针就是物理地址。
    call fb_lb_forget                   ; 先记成"没有缓冲"
    mov dword [fb_lb_base], 0
    mov eax, [fb_pitch]
    test eax, eax
    jz .no_buf
    cmp eax, FB_LINE_PAGES * 4096 / FB_CELL_H   ; 一行 16 个扫描行塞得进 52 KiB?
    ja .no_buf                                  ; 塞不进(比如 pitch > 3200)→ 不用缓冲
    mov ecx, FB_LINE_PAGES
    call pmem_alloc_pages
    test eax, eax
    jz .no_buf                          ; 页池没页了 → 退回逐字直写,绝不能挂
    mov [fb_lb_base], eax
.no_buf:
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

; ---- 行缓冲的记账(缓冲本身在页池里,fb_init 时申请,见上面)----
fb_lb_base      dd 0                    ; 行缓冲物理地址;0 = 没要到 → 退回逐字直写
fb_lb_row       dd -1                   ; 缓冲里装的是第几个字符行;-1 = 没认领/已作废
fb_dirty_line   dd 0                    ; 脏标志:1 = 缓冲里有没刷进显存的内容
fb_lb_x0        dd 800                  ; 脏段左边界(像素,含)
fb_lb_x1        dd 0                    ; 脏段右边界(像素,不含)
fb_mask8:                           ; 字节 → 8 个像素掩码(0 或 0xFFFFFFFF)
    dd 0, 0, 0, 0, 0, 0, 0, 0
    dd 0, 0, 0, 0, 0, 0, 0, 0xFFFFFFFF
    dd 0, 0, 0, 0, 0, 0, 0xFFFFFFFF, 0
    dd 0, 0, 0, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0, 0, 0, 0, 0xFFFFFFFF, 0, 0
    dd 0, 0, 0, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0, 0, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0, 0, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0, 0, 0, 0xFFFFFFFF, 0, 0, 0
    dd 0, 0, 0, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF
    dd 0, 0, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0
    dd 0, 0, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0
    dd 0, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0, 0, 0xFFFFFFFF, 0, 0, 0, 0
    dd 0, 0, 0, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF
    dd 0, 0, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0
    dd 0, 0, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0
    dd 0, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0
    dd 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF
    dd 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0
    dd 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0
    dd 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0, 0xFFFFFFFF, 0, 0, 0, 0, 0
    dd 0, 0, 0xFFFFFFFF, 0, 0, 0, 0, 0xFFFFFFFF
    dd 0, 0, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0
    dd 0, 0, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0
    dd 0, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0
    dd 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF
    dd 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0
    dd 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0
    dd 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0
    dd 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF
    dd 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0
    dd 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0
    dd 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0
    dd 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF
    dd 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0
    dd 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0
    dd 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0, 0, 0, 0, 0, 0
    dd 0, 0xFFFFFFFF, 0, 0, 0, 0, 0, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0, 0, 0, 0, 0xFFFFFFFF, 0
    dd 0, 0xFFFFFFFF, 0, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0, 0
    dd 0, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0, 0
    dd 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0
    dd 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0
    dd 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0, 0
    dd 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0
    dd 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0
    dd 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0
    dd 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0
    dd 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0
    dd 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0, 0
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0, 0, 0, 0, 0, 0
    dd 0xFFFFFFFF, 0, 0, 0, 0, 0, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0, 0, 0, 0, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0, 0, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0, 0, 0, 0xFFFFFFFF, 0, 0
    dd 0xFFFFFFFF, 0, 0, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0, 0, 0
    dd 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0
    dd 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0, 0, 0
    dd 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0
    dd 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0
    dd 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0
    dd 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0, 0, 0
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0, 0, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF

blit_color      dd 0
blit_data       dd 0
want_cp         dd 0

; 内建字库(小):ASCII + 三百来个常用汉字。磁盘字库读成功后 font_base 会指向它
font_blob:
    incbin "font/font-joyf.bin"
