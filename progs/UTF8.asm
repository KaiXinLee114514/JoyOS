; ============================================================================
;  UTF8.BIN — 演示程序:中文 / UTF-8 在图形模式下怎么画出来
;
;  以前这是 shell 里的一条内置命令(zh),现在改成磁盘上的普通程序:
;  shell 里只留正经命令,演示归演示。跑法:
;
;      run UTF8
;
;  它演示四件事:
;    1. 16×16 点阵汉字直接 blit 到 VBE 帧缓冲(UTF-8 三字节)
;    2. 四字节 UTF-8(emoji,U+1F600)也画得出来
;    3. 故意写坏的 UTF-8(截断的三字节 + 孤立延续字节)→ 两个替换字符 U+FFFD,
;       而且后面的文字还继续显示(解码器不会卡死)
;    4. 文案全走 int 0x30,程序自己不用知道帧缓冲在哪、字库在哪
;
;  编译: nasm -f bin progs/UTF8.asm -o build/UTF8.BIN
;  [ORG] 必须和内核的加载地址一致(见 kernel/shell.asm 的 SPACE_IMG_VA)
; ============================================================================

[BITS 32]
[ORG 0x120000]

API_PRINT     equ 0                     ; 功能 0:esi = 以 0 结尾的字节串
API_COLOR     equ 4                     ; 功能 4:bl = 颜色

start:
    mov eax, API_COLOR                  ; 浅灰
    mov ebx, 0x07
    int 0x30

    mov esi, msg_note
    call print_line

    ; ---- 一条条打(文案和以前那条 zh 命令一模一样)----
    mov esi, zstr_1
    call print_line
    mov esi, zstr_2
    call print_line
    mov esi, zstr_3
    call print_line
    mov esi, zstr_4
    call print_line
    mov esi, zstr_5
    call print_line
    mov esi, zstr_6
    call print_line
    mov esi, zstr_7
    call print_line
    mov esi, zstr_8
    call print_line

    ; ---- 四字节 UTF-8:直接打字节串,内核会拆成码位去查字库 ----
    mov esi, msg_emoji
    call print_line

    ; ---- 故意坏的 UTF-8:截断的 3 字节序列 + 一个孤立的延续字节 ----
    ;      应该画出两个替换字符,而且后半句还在(这行是分两截打的)
    mov eax, API_PRINT
    mov esi, msg_broken1
    int 0x30
    mov esi, msg_broken2
    call print_line

    ret                                 ; 回 shell

; ---------------------------------------------------------------------------
;  print_line:esi = 字符串 → 打出来,再补一个换行
;  (接口里没有"打印一个字符",所以换行就是打一个字节 10 的串)
; ---------------------------------------------------------------------------
print_line:
    mov eax, API_PRINT
    int 0x30
    mov esi, msg_nl
    int 0x30
    ret

; ---------------------------------------------------------------------------
;  文案:UTF-8 字节串(汉字部分和 font/strings.txt 里那几条一致)
; ---------------------------------------------------------------------------
msg_note    db 'UTF8.BIN: glyphs from GNU Unifont, blitted straight into the VBE framebuffer', 0

zstr_1      db '你好，世界！', 0
zstr_2      db '这是 JoyOS 的中文显示。', 0
zstr_3      db '汉字是 16x16 点阵，在文本模式下用两个格拼成。', 0
zstr_4      db '点阵字库来自 GNU Unifont。', 0
zstr_5      db '现在换成图形模式：直接往线性帧缓冲写像素，不再有字模表和字符码那些限制。', 0
zstr_6      db '屏幕是 800x600 的 VBE 模式，每个像素四个字节。', 0
zstr_7      db '编码统一成 UTF-8：字符串和外界一致，别人不用再学一套。', 0
zstr_8      db '四字节序列也能画：😀', 0

msg_emoji   db 'emoji (4-byte UTF-8): 😀', 0
msg_broken1 db 'broken UTF-8: [', 0xE4, 0xBD, 0x20, 0x80, '] (should be two', 0
msg_broken2 db ' replacement chars, and this text still shows)', 0

msg_nl      db 10, 0
