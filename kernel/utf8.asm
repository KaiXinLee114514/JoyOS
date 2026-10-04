; ============================================================================
;  JoyOS (胡闹OS) — UTF-8 解码
;
;  为什么要它:内核里以前存中文是"每个码位一个 u32"的数组,查表快,但**和外界不一致** ——
;  磁盘上的文本文件、编辑器、git 全都是 UTF-8,想让别人不用学我们这套,就得吃 UTF-8。
;
;  UTF-8 规则(一个字符 1~4 字节):
;      0xxxxxxx                                      ASCII(码位 < 0x80)
;      110xxxxx 10xxxxxx                             2 字节(码位 < 0x800)
;      1110xxxx 10xxxxxx 10xxxxxx                    3 字节(码位 < 0x10000,汉字在这里)
;      11110xxx 10xxxxxx 10xxxxxx 10xxxxxx           4 字节(码位 < 0x110000,emoji 在这里)
;  后跟的字节必须以 10 开头(0x80~0xBF),否则就是坏序列。
;
;  解码器遇到坏序列返回 U+FFFD(替换字符,屏幕上画成 �)并**只前进一个字节**,
;  这样即使数据中间烂了一段,后面的文字也还能继续显示,不会卡死。
;  顺带做两个合法性检查:过长编码(用 2 字节编码一个 ASCII)和代理区(D800-DFFF,UTF-8 里非法)。
;
;  入口/出口:
;      utf8_decode:esi = 字节流 → eax = 码位(0 表示遇到字符串结尾),esi 自动前进
; ============================================================================

UTF8_REPLACEMENT equ 0x0000FFFD

; ---------------------------------------------------------------------------
;  utf8_decode
; ---------------------------------------------------------------------------
utf8_decode:
    push ebx
    push ecx
    push edx
    movzx eax, byte [esi]
    test al, al
    jz .end_of_string
    cmp al, 0x80
    jb .ascii
    cmp al, 0xC0
    jb .bad                             ; 10xxxxxx 不能当首字节
    cmp al, 0xE0
    jb .len2
    cmp al, 0xF0
    jb .len3
    cmp al, 0xF8
    jb .len4
    jmp .bad                            ; 0xF8 以上不是合法首字节

.ascii:
    inc esi
    jmp .out

.len2:
    and eax, 0x1F
    mov ecx, 1
    mov dword [utf8_min], 0x80
    jmp .collect
.len3:
    and eax, 0x0F
    mov ecx, 2
    mov dword [utf8_min], 0x800
    jmp .collect
.len4:
    and eax, 0x07
    mov ecx, 3
    mov dword [utf8_min], 0x10000

.collect:
    mov ebx, eax
    inc esi
.next:
    movzx eax, byte [esi]
    mov edx, eax
    and edx, 0xC0
    cmp edx, 0x80                       ; 后续字节必须是 10xxxxxx
    jne .bad
    and eax, 0x3F
    shl ebx, 6
    or  ebx, eax
    inc esi
    dec ecx
    jnz .next
    mov eax, ebx
    cmp eax, [utf8_min]                 ; 过长编码(比如 C0 80 冒充 NUL)
    jb .bad
    cmp eax, 0xD800                     ; 代理区在 UTF-8 里非法
    jb .range_ok
    cmp eax, 0xDFFF
    jbe .bad
.range_ok:
    cmp eax, 0x10FFFF
    ja .bad
    jmp .out

.end_of_string:
    xor eax, eax
    jmp .out

.bad:
    mov eax, UTF8_REPLACEMENT
    inc esi                             ; 只跳一个字节,后面的内容还能接着显示
.out:
    pop edx
    pop ecx
    pop ebx
    ret

utf8_min dd 0
