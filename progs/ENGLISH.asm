; ============================================================================
;  ENGLISH.BIN — 英文示例程序(磁盘上的演示,和 UTF8.BIN 一个路子)
;
;  正文取自仓库根目录的 ensample.txt(莎士比亚 Sonnet 18),用 int 0x30 打印,
;  证明英文文本也能直接画在 VBE 屏上。改诗就改 ensample.txt 再同步这里。
;  编译: nasm -f bin progs/ENGLISH.asm -o build/ENGLISH.BIN
;  调用: shell 里  run ENGLISH
; ============================================================================

[BITS 32]
[ORG 0x120000]

start:
    ; ---- 标题:亮青 ----
    mov eax, 4
    mov ebx, 0x0B
    int 0x30
    mov eax, 0
    mov esi, msg_head
    int 0x30

    ; ---- 正文:浅灰 ----
    mov eax, 4
    mov ebx, 0x07
    int 0x30
    mov eax, 0
    mov esi, msg_body
    int 0x30

    ret

msg_head db 10, '           Sonnet 18', 10, '        William Shakespeare', 10, 10, 0
msg_body db \
    "Shall I compare thee to a summer's day?", 10, \
    'Thou art more lovely and more temperate:', 10, \
    'Rough winds do shake the darling buds of May,', 10, \
    "And summer's lease hath all too short a date:", 10, \
    'Sometime too hot the eye of heaven shines,', 10, \
    'And often is his gold complexion dimmed,', 10, \
    'And every fair from fair sometime declines,', 10, \
    "By chance or nature's changing course untrimmed:", 10, \
    'But thy eternal summer shall not fade,', 10, \
    "Nor lose possession of that fair thou ow'st,", 10, \
    "Nor shall death brag thou wander'st in his shade,", 10, \
    "When in eternal lines to time thou grow'st:", 10, \
    'So long as men can breathe or eyes can see,', 10, \
    'So long lives this, and this gives life to thee.', 10, \
    10, 0
