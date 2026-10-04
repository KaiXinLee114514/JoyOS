; ============================================================================
;  HELLO.BIN — 磁盘上的示例程序
;
;  它证明了三件事:文件系统能按名字读出程序、内核能把它加载到 0x120000 执行、
;  程序能通过 int 0x30 调用内核功能。
;
;  编译: nasm -f bin progs/HELLO.asm -o build/HELLO.BIN
;  调用: shell 里  run HELLO
;
;  注意 [ORG 0x120000] 必须和内核里的加载地址一致(见 kernel/shell.asm 的 PROG_ADDR)
; ============================================================================

[BITS 32]
[ORG 0x120000]

start:
    ; ---- 打印一行英文 ----
    mov eax, 0                          ; 功能 0:打印字符串
    mov esi, msg_en
    int 0x30

    ; ---- 打印一行中文(程序里直接写 UTF-8 就行)----
    mov eax, 4                          ; 功能 4:设颜色
    mov ebx, 0x0B                       ; 亮青
    int 0x30
    mov eax, 0
    mov esi, msg_zh
    int 0x30

    ; ---- 顺手证明"程序没踩坏字库" ----
    ; U+7830 的点阵正好落在"以前那个加载地址 0x300000"上(见 kernel/shell.asm 的注释):
    ; 加载地址要是选在那儿,这个字会被程序自己的代码盖掉,屏幕上就是花屏。
    mov eax, 4
    mov ebx, 0x07                       ; 变回浅灰
    int 0x30
    mov eax, 0
    mov esi, msg_font
    int 0x30
    mov eax, 3                          ; 功能 3:按码位打印
    mov ebx, 0x7830                     ; 砰
    int 0x30

    mov eax, 0                          ; 换个行(接口里没有"打印一个字符")
    mov esi, msg_nl
    int 0x30

    ret                                 ; 返回 shell

msg_en  db 'Hello from HELLO.BIN - I was loaded from the FAT16 disk!', 10, 0
msg_zh  db '我是从磁盘上的 HELLO.BIN 里跑起来的程序,这一行是 UTF-8 中文。', 10, 0
msg_font db 'font still intact: ', 0
msg_nl  db 10, 0
