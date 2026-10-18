; ============================================================================
;  JoyOS — 简易拼音输入法(单字)
;
;  ── 它是什么 ────────────────────────────────────────────────────────────
;  一个能用的单字拼音输入法:按一下 **Shift**(只按、不带别的键)切中英;
;  中文状态下敲拼音 → 空格出候选 → 左右键挑、空格/数字选定 → 汉字进命令行。
;
;      > shuang
;        1.双 2.爽 3.霜        ← 空格之后长这样,左右键移动,回车/空格选
;      > 双
;
;  ── 数据从哪来 ──────────────────────────────────────────────────────────
;  开机时从磁盘读 PINYIN.BIN(tools/mkpinyin.py 生成,约 17 KB):
;      0     "PIME"
;      4     u32 音节个数
;      8     u32 字条目个数
;      12    音节表:每个 8 字节(ASCII,补 0)
;      ...   字条目:每个 5 字节 = 2 字节音节号 + 3 字节 UTF-8 汉字
;  字条目的顺序就是"常用度"(生成时按词频排),所以第一个候选永远是最常用的那个。
;
;  ── 为什么放磁盘不放内核 ────────────────────────────────────────────────
;  17 KB 的拼音表塞进内核会白占半个内核区,而且改字表就得重编内核;
;  放 FAT16 里跟字库一个待遇,换字表 = 换文件。
; ============================================================================

PINYIN_ADDR    equ 0x3B0000            ; 字库(0x200000 + 1.7 MB)后面那段空着的
PINYIN_MAX     equ 32768
IME_BUF_MAX    equ 12                  ; 一个音节最长 7 个字母,留点余量
IME_CAND_PAGE  equ 9                   ; 一屏最多 9 个候选

; ---------------------------------------------------------------------------
;  ime_load:开机读 PINYIN.BIN(没有就安静地关掉输入法)
; ---------------------------------------------------------------------------
ime_load:
    pushad
    mov dword [ime_ok], 0
    cmp byte [fat_ok], 0
    je .out
    mov esi, msg_ime_file
    mov edi, PINYIN_ADDR
    call fat_read_file
    cmp eax, 16
    jle .out                            ; 太小了,不可能是拼音表
    cmp eax, PINYIN_MAX
    ja .out
    cmp dword [PINYIN_ADDR], 0x454D4950 ; 'PIME'
    jne .out
    mov esi, PINYIN_ADDR
    mov eax, [esi + 4]
    mov [ime_nsyll], eax
    mov eax, [esi + 8]
    mov [ime_nchar], eax
    mov dword [ime_ok], 1
.out:
    popad
    ret

; ---------------------------------------------------------------------------
;  ime_strcmp8:edi = 表里的 8 字节音节(补 0),esi = 输入的拼音串 → eax = 1/0
; ---------------------------------------------------------------------------
ime_strcmp8:
    push esi
    push edi
.loop:
    mov al, [edi]
    test al, al
    jz .tail
    cmp al, [esi]
    jne .diff
    inc edi
    inc esi
    jmp .loop
.tail:
    cmp byte [esi], 0                   ; 输入必须刚好到这为止
    jne .diff
    mov eax, 1
    jmp .out
.diff:
    xor eax, eax
.out:
    pop edi
    pop esi
    ret

; ---------------------------------------------------------------------------
;  ime_lookup:esi = 拼音串(0 结尾)→ eax = 音节号(-1 = 表里没有)
; ---------------------------------------------------------------------------
ime_lookup:
    pushad
    mov ebx, PINYIN_ADDR
    add ebx, 12
    xor ecx, ecx
.syl:
    cmp ecx, [ime_nsyll]
    jae .no
    push ecx
    push ebx
    push esi
    mov edi, ebx
    call ime_strcmp8
    pop esi
    pop ebx
    pop ecx
    test eax, eax
    jnz .hit
    add ebx, 8
    inc ecx
    jmp .syl
.hit:
    mov [esp + 28], ecx
    jmp .out
.no:
    mov dword [esp + 28], -1
.out:
    popad
    ret

; ---------------------------------------------------------------------------
;  ime_begin:esi = 拼音串 → eax = 候选个数(0 = 没这个音)
;            顺便把 ime_first / ime_count / ime_sel 都安排好
; ---------------------------------------------------------------------------
ime_begin:
    pushad
    mov dword [ime_count], 0
    mov dword [ime_sel], 0
    mov dword [ime_first], 0
    call ime_lookup
    cmp eax, -1
    je .out
    mov [ime_syl], eax
    ; 字条目表 = PINYIN_ADDR + 12 + 音节数*8
    mov ebx, [ime_nsyll]
    imul ebx, 8
    add ebx, 12
    add ebx, PINYIN_ADDR
    xor edx, edx
    mov dword [ime_first], -1
.scan:
    cmp edx, [ime_nchar]
    jae .done
    mov eax, edx
    imul eax, 5
    movzx ecx, word [ebx + eax]
    cmp ecx, [ime_syl]
    jne .next
    cmp dword [ime_first], -1
    jne .count
    mov [ime_first], edx
.count:
    inc dword [ime_count]
.next:
    inc edx
    jmp .scan
.done:
    cmp dword [ime_first], -1
    jne .ok
    mov dword [ime_count], 0
.ok:
    mov eax, [ime_count]
    mov [esp + 28], eax
.out:
    popad
    ret

; ---------------------------------------------------------------------------
;  ime_char_ptr:eax = 候选序号(0 起)→ eax = 指向那 3 个 UTF-8 字节
; ---------------------------------------------------------------------------
ime_char_ptr:
    add eax, [ime_first]
    imul eax, 5
    mov edx, [ime_nsyll]
    imul edx, 8
    add edx, 12
    add edx, PINYIN_ADDR
    add eax, edx
    add eax, 2                          ; 跳过 2 字节音节号
    ret

; ---------------------------------------------------------------------------
;  ime_show:把候选那一行打出来(当前选中的反白)
; ---------------------------------------------------------------------------
ime_show:
    pushad
    ; 窗口起点 = (sel / 9) * 9
    mov eax, [ime_sel]
    xor edx, edx
    mov ecx, IME_CAND_PAGE
    div ecx
    imul eax, IME_CAND_PAGE
    mov [ime_win], eax
    mov al, 10
    call term_putc
    xor ebx, ebx                        ; ebx = 这一屏的第几个
.row:
    cmp ebx, IME_CAND_PAGE
    jae .tail
    mov eax, [ime_win]
    add eax, ebx
    cmp eax, [ime_count]
    jae .tail
    mov [ime_tmp], eax
    ; 选中的反白
    mov al, COL_NORMAL
    cmp dword [ime_tmp], 0
    jl .color
    mov eax, [ime_tmp]
    cmp eax, [ime_sel]
    jne .color
    mov al, 0x70                        ; 黑底白字 = 选中
.color:
    call term_set_color
    mov al, ' '
    call term_putc
    mov eax, [ime_tmp]
    inc eax
    call term_print_dec                 ; "1." ~ "9."
    mov al, '.'
    call term_putc
    mov eax, [ime_tmp]
    call ime_char_ptr
    mov esi, eax
    mov edi, ime_ch
    mov ecx, 3
    rep movsb
    mov byte [ime_ch + 3], 0
    mov esi, ime_ch
    call term_print
    inc ebx
    jmp .row
.tail:
    mov al, COL_NORMAL
    call term_set_color
    mov esi, msg_ime_hint
    call term_print
    popad
    ret

; ---------------------------------------------------------------------------
;  ime_move:eax = ±1 → 把选中项左右挪一格(到头绕回去),再重画一行
; ---------------------------------------------------------------------------
ime_move:
    add [ime_sel], eax
    cmp dword [ime_sel], 0
    jge .hi
    mov eax, [ime_count]
    dec eax
    mov [ime_sel], eax
.hi:
    mov eax, [ime_sel]
    cmp eax, [ime_count]
    jb .show
    mov dword [ime_sel], 0
.show:
    call ime_show
    ret

; ---------------------------------------------------------------------------
;  ime_pick:eax = 候选序号 → 把那个汉字塞进 shell_buf、重画提示行
;  (候选序号越界就当没选)
; ---------------------------------------------------------------------------
ime_pick:
    cmp eax, [ime_count]
    jae .out
    mov [ime_sel], eax
    call ime_char_ptr
    ; ---- 追加到命令行缓冲 ----
    mov ebx, [shell_len]
    cmp ebx, SHELL_LINE_MAX - 3
    jae .out
    mov dl, [eax]
    mov [shell_buf + ebx], dl
    mov dl, [eax + 1]
    mov [shell_buf + ebx + 1], dl
    mov dl, [eax + 2]
    mov [shell_buf + ebx + 2], dl
    add ebx, 3
    mov [shell_len], ebx
    mov byte [shell_buf + ebx], 0
    ; ---- 屏幕上重画:换行 + 提示符 + 已经打进去的整行 ----
    mov al, 10
    call term_putc
    call shell_print_prompt
    mov esi, shell_buf
    call term_print
.out:
    ret

; ---------------------------------------------------------------------------
;  ime_reset:清掉拼音缓冲(切换模式 / 取消时用)
; ---------------------------------------------------------------------------
ime_reset:
    mov dword [ime_len], 0
    mov byte [ime_buf], 0
    ret

; ---------------------------------------------------------------------------
;  数据
; ---------------------------------------------------------------------------
msg_ime_none    db '  (没有这个音 —— 或者盘上没有 PINYIN.BIN)', 10, 0
msg_ime_file    db 'PINYIN.BIN', 0
msg_ime_hint    db '   1-9 pick, space/enter pick first, Esc cancel', 10, 0

ime_ok          dd 0
ime_on          dd 0
ime_state       dd 0                    ; 0 = 敲拼音,1 = 挑候选
ime_nsyll       dd 0
ime_nchar       dd 0
ime_syl         dd 0
ime_first       dd 0
ime_count       dd 0
ime_sel         dd 0
ime_win         dd 0
ime_tmp         dd 0
ime_len         dd 0
ime_buf         times IME_BUF_MAX db 0
ime_ch          times 4 db 0
