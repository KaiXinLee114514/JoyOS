; ============================================================================
;  COUNT.BIN — 用内核接口做点"计算"的示例
;  演示:打印十进制、打印十六进制、以及按码位打印(汉字从哪个码位开始连着打)
;
;  调用: run COUNT
; ============================================================================

[BITS 32]
[ORG 0x120000]

start:
    mov eax, 4
    mov ebx, 0x0E                       ; 亮黄
    int 0x30
    mov eax, 0
    mov esi, msg_head
    int 0x30

    ; ---- 1 到 10 ----
    mov ebx, 1
.loop:
    push ebx
    mov eax, 1                          ; 打印十进制
    int 0x30
    mov eax, 0
    mov esi, msg_space
    int 0x30
    pop ebx
    inc ebx
    cmp ebx, 10
    jbe .loop

    ; ---- 十六进制演示:0x20 的阶乘表头是假的,这里只显示个数 ----
    mov eax, 0
    mov esi, msg_hex
    int 0x30
    mov ebx, 0xDEADBEEF
    mov eax, 2                          ; 打印十六进制
    int 0x30

    ; ---- 按码位连着打 6 个汉字:从 U+4F60(你)开始 ----
    mov eax, 0
    mov esi, msg_cp
    int 0x30
    mov ebx, 0x4F60                     ; 你
    mov eax, 3
    int 0x30
    mov ebx, 0x597D                     ; 好
    mov eax, 3
    int 0x30
    mov ebx, 0xFF0C                     ; ，
    mov eax, 3
    int 0x30
    mov ebx, 0x4E16                     ; 世
    mov eax, 3
    int 0x30
    mov ebx, 0x754C                     ; 界
    mov eax, 3
    int 0x30
    mov ebx, 0xFF01                     ; ！
    mov eax, 3
    int 0x30

    mov eax, 4
    mov ebx, 0x07
    int 0x30
    mov eax, 0
    mov esi, msg_tail
    int 0x30
    ret

msg_head  db 'counting: ', 0
msg_space db ' ', 0
msg_hex   db 10, 'hex demo: ', 0
msg_cp    db 10, 'codepoints: ', 0
msg_tail  db 10, 0
