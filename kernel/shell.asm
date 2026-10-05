; ============================================================================
;  JoyOS (胡闹OS) — 那个很土的 shell
;
;  能干的:
;      help            列出命令
;      echo <文字>     把文字打回来
;      zh              显示中文(点阵字库,直接往帧缓冲里 blit)
;      clear           清屏
;      info            系统信息(CR0/CR3/IDT/段寄存器/读盘方式...)
;      page <十六进制> 查一个虚拟地址被映射到哪(页目录 + 页表逐级查)
;      fault           故意踩一个没映射的地址,看页错误 panic 屏
;      reboot          重启(通过 8042 键盘控制器)
;      ls              列 FAT16 根目录
;      cat <文件>      把一个文本文件(UTF-8)打出来,中文能直接看
;      write <文件> <内容>  写文件(创建或覆盖,真的落到磁盘上)
;      run <文件>      把程序从磁盘读进内存跑(.BIN,平铺二进制)
;
;  注意:键盘直接给字节,没有输入法 —— 命令行本身只能打 ASCII。
;  想看中文就用 cat(文件里存的是 UTF-8),或者让程序自己打。
;
;  结构:读一行(shell_readline)→ 切成"命令 + 参数"(shell_execute)→ 查表跳转。
;  行编辑只有退格和回车 —— 光标键要先处理 0xE0 前缀,留给你自己加。
; ============================================================================

SHELL_LINE_MAX equ 64

; ---------------------------------------------------------------------------
;  shell_main:打招呼 → 循环(提示符 → 读一行 → 执行)
; ---------------------------------------------------------------------------
shell_main:
    mov al, 10
    call term_putc
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_shell_hello
    call term_print

.prompt:
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_prompt
    call term_print
    call shell_readline
    call shell_execute
    jmp .prompt

; ---------------------------------------------------------------------------
;  shell_readline:读一行到 shell_buf(带退格),回车结束
; ---------------------------------------------------------------------------
shell_readline:
    mov dword [shell_len], 0
    mov al, COL_NORMAL
    call term_set_color
.next:
    call kbd_getchar                      ; 没有按键就睡着等
    cmp al, 13                            ; Enter
    je .done
    cmp al, 8                             ; Backspace
    je .backspace
    cmp al, 32                            ; 其它控制字符先不管
    jb .next
    cmp dword [shell_len], SHELL_LINE_MAX - 1
    jae .next                             ; 满了就丢(不给它撑爆的机会)
    mov ebx, [shell_len]
    mov [shell_buf + ebx], al
    inc dword [shell_len]
    call term_putc                        ; 回显
    jmp .next

.backspace:
    cmp dword [shell_len], 0
    je .next
    dec dword [shell_len]
    mov al, 8
    call term_putc
    jmp .next

.done:
    mov ebx, [shell_len]
    mov byte [shell_buf + ebx], 0         ; 补个结尾,方便当字符串用
    mov al, 10
    call term_putc
    ret

; ---------------------------------------------------------------------------
;  shell_execute:把 shell_buf 切成命令 + 参数
; ---------------------------------------------------------------------------
shell_execute:
    ; ---- 跳过开头的空格 ----
    mov esi, shell_buf
.skip:
    cmp byte [esi], ' '
    jne .have_start
    inc esi
    jmp .skip
.have_start:
    cmp byte [esi], 0                     ; 空行 → 什么都不做
    je .ret

    ; ---- 找命令词的结尾 ----
    mov edi, esi                          ; edi = 命令词开头
.find_end:
    mov al, [esi]
    test al, al
    jz .end_found
    cmp al, ' '
    je .end_found
    inc esi
    jmp .find_end
.end_found:
    mov ecx, esi
    sub ecx, edi                          ; ecx = 命令词长度
    mov [cmd_len], ecx

    ; ---- 参数从哪开始(跳过命令词后的空格) ----
.arg_skip:
    cmp byte [esi], ' '
    jne .arg_ready
    inc esi
    jmp .arg_skip
.arg_ready:
    mov [cmd_arg], esi

    ; ---- 拿命令词去表里对名字 ----
    mov ebx, cmd_table
.try:
    mov edx, [ebx]                        ; edx = 命令名字符串
    test edx, edx
    jz .unknown                           ; 表尾 → 不认识
    mov esi, edi
    mov ecx, [cmd_len]
    call str_eq                           ; eax = 1 相同
    test eax, eax
    jnz .run
    add ebx, 8                            ; 下一项:名字 + 处理函数
    jmp .try
.run:
    mov eax, [ebx + 4]
    call eax
    jmp .ret
.unknown:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_shell_unknown
    call term_print
    mov esi, shell_buf
    call term_print
    mov al, 10
    call term_putc
    mov al, COL_NORMAL
    call term_set_color
.ret:
    ret

; ---------------------------------------------------------------------------
;  str_eq:esi = 一个词,ecx = 词长,edx = 以 0 结尾的命令名 → eax = 1/0
; ---------------------------------------------------------------------------
str_eq:
    push esi
    push edi
    push ecx
    push ebx                              ; 调用者拿 ebx 当命令表指针,别毁它
    mov edi, edx
.next:
    test ecx, ecx                         ; 词读完了
    jz .tail
    mov al, [esi]
    mov bl, [edi]
    test bl, bl                           ; 名字先到头 → 不相等
    jz .no
    cmp al, bl
    jne .no
    inc esi
    inc edi
    dec ecx
    jmp .next
.tail:
    cmp byte [edi], 0                     ; 名字也必须正好到头
    jne .no
    mov eax, 1
    jmp .out
.no:
    xor eax, eax
.out:
    pop ebx
    pop ecx
    pop edi
    pop esi
    ret

; ===========================================================================
;  各个命令
; ===========================================================================

cmd_help:
    mov esi, msg_help
    call term_print
    ret

; ---------------------------------------------------------------------------
;  ls:列根目录
; ---------------------------------------------------------------------------
cmd_ls:
    cmp byte [fat_ok], 0
    je .nomount
    call fat_list
    ret
.nomount:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_no_fat
    call term_print
    ret

; ---------------------------------------------------------------------------
;  cat <文件>:把文件内容原样打出来(UTF-8 文本可以直接看)
; ---------------------------------------------------------------------------
cmd_cat:
    cmp byte [fat_ok], 0
    je cmd_ls.nomount
    mov esi, [cmd_arg]
    call strip_name                    ; 去掉尾巴上的空格
    mov esi, [cmd_arg]
    ; ---- 支持路径:DOCS/NOTE.TXT 这样先把前面的目录一层层进去 ----
    mov dword [fat_dir], 0
    call fat_path
    jc .notfound
    mov esi, eax                        ; 剩下的那截才是文件名
    call fat_stat                       ; 先看大小:缓冲区只到 PROG_ARG_ADDR 为止
    cmp eax, -1
    je .notfound
    cmp eax, FILE_MAX
    ja .toobig
    mov esi, [cmd_arg]
    mov edi, FILE_BUF
    call fat_read_file
    cmp eax, -1
    je .notfound
    mov [file_size], eax
    mov dword [fat_dir], 0
    mov esi, FILE_BUF
    call term_print                     ; 内容是 UTF-8,term_print 直接吃
    cmp byte [FILE_BUF + 0], 0          ; 空文件就算了
    jne .newline
    ret
.newline:
    mov al, 10
    call term_putc
    ret
.toobig:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_file_toobig
    call term_print
    ret
.notfound:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_no_file
    call term_print
    ret

; ---------------------------------------------------------------------------
;  write <文件> <内容>:写文件(创建或覆盖)
; ---------------------------------------------------------------------------
cmd_write:
    cmp byte [fat_ok], 0
    je cmd_ls.nomount
    ; 先把文件名从参数里切出来(到空格为止),再写内容
    mov esi, [cmd_arg]
    mov edi, name_buf
    xor ecx, ecx
.copy_name:
    lodsb
    test al, al
    jz .empty
    cmp al, ' '
    je .name_done
    mov [edi], al
    inc edi
    inc ecx
    cmp ecx, 12                         ; 8.3 最多 12 个字符(含点)
    jb .copy_name
.name_done:
    mov byte [edi], 0
    ; 跳过空格,内容从这里开始
.skip:
    lodsb
    test al, al
    jz .no_content
    cmp al, ' '
    je .skip
    dec esi                             ; 退回这个字符
    mov edi, esi                        ; 内容是 UTF-8,原样写
    call strlen
    mov ecx, eax
    mov esi, name_buf
    call fat_write_file
    cmp eax, -1
    je .failed
    mov al, COL_OK
    call term_set_color
    mov esi, msg_wrote
    call term_print
    mov esi, name_buf
    call term_print
    mov al, 10
    call term_putc
    ret
.empty:
.no_content:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_write_usage
    call term_print
    ret
.failed:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_write_fail
    call term_print
    ret

; ---------------------------------------------------------------------------
;  run <文件>:把程序读进 PROG_ADDR 然后 call 进去
;  名字不带点就自动补 .BIN(所以 run HELLO 和 run HELLO.BIN 一样)
;
;  ★ 加载地址为什么是 0x120000 而不是看起来更顺眼的 0x300000:
;    完整字库是读到 0x200000 的,1.7 MB 一直铺到 0x3AF110 ——
;    0x300000 正好落在字库的**点阵数据中间**!程序一载入就把几个汉字的点阵改掉了
;    (实测被踩掉的是 U+BF11~U+BF16 六个谚文字,屏幕上那几个字会变成花屏)。
;    现在选 0x120000:上有 FILE_BUF(0x110000),下有字库(0x200000),
;    中间 896 KB 都是空的,程序再大也踩不到字库(超了就直接拒绝,见 PROG_MAX_SIZE)。
; ---------------------------------------------------------------------------
cmd_run:
    cmp byte [fat_ok], 0
    je cmd_ls.nomount
    ; ★ 这里**不能**调 strip_name:它会把第一个空格改成 0,而空格后面的那截
    ;   正是要传给程序的参数(`run EDIT NOTES.TXT`)—— 一改参数就没了(踩过)。
    ;   文件名在下面抄进 name_buf,到空格自然就停了。
    mov esi, [cmd_arg]
    cmp byte [esi], 0
    je .usage                           ; 光敲 run 就说说程序怎么写
    mov dword [PROG_ARG_ADDR], 0        ; 参数先当"没有"(上一条命令可能留了残渣)
    mov byte [PROG_ARG_STR], 0
    ; 把名字抄进 name_buf,顺便看有没有带 '.'
    ; (之前这里写反了方向:从空缓冲往命令参数抄,结果名字变成空的 → file not found)
    mov esi, [cmd_arg]
    mov edi, name_buf
    xor ecx, ecx
    xor edx, edx                        ; edx = 有没有点
.cpy:
    lodsb
    test al, al
    jz .copied
    cmp al, ' '                         ; 空格之后那截是"给程序的参数"
    je .args
    cmp al, '.'
    jne .cpy_store
    mov edx, 1
.cpy_store:
    mov [edi], al
    inc edi
    inc ecx
    cmp ecx, 12                         ; 8.3 最多 12 个字符
    jb .cpy

.copied:
    mov byte [edi], 0
    test edx, edx
    jnz .no_ext
    ; 没写扩展名就补 .BIN(run hello 等于 run hello.bin)
    mov byte [edi], '.'
    mov byte [edi + 1], 'B'
    mov byte [edi + 2], 'I'
    mov byte [edi + 3], 'N'
    mov byte [edi + 4], 0
    jmp .no_ext

.args:
    ; 名字到这里结束,剩下的是参数:`run EDIT NOTES.TXT` 里的 NOTES.TXT
    mov byte [edi], 0
    push edx                            ; edx/edi 后面还要用来补 .BIN,先存一下
    push edi
.skip_sp:
    cmp byte [esi], ' '
    jne .copy_args
    inc esi
    jmp .skip_sp
.copy_args:
    mov edi, PROG_ARG_STR
    mov ecx, PROG_ARG_MAX - 1
.loop_args:
    lodsb
    test al, al
    jz .args_done
    mov [edi], al
    inc edi
    dec ecx
    jnz .loop_args
.args_done:
    mov byte [edi], 0
    mov dword [PROG_ARG_ADDR], 'JARG'   ; 告诉程序"这次真有参数"
    pop edi
    pop edx
    jmp .copied
.no_ext:
    ; 先只看目录项里的大小:太大就别读了,免得把字库盖掉一半
    mov dword [fat_dir], 0
    mov esi, name_buf
    call fat_path                       ; 支持 run DOCS/PROG.BIN
    jc .notfound
    mov [prog_name_ptr], eax            ; 前面的目录已经进去了,这截才是文件名
    mov esi, eax
    call fat_stat
    cmp eax, -1
    je .notfound
    cmp eax, PROG_MAX_SIZE
    ja .toobig
    mov esi, [prog_name_ptr]
    mov edi, PROG_ADDR
    call fat_read_file
    cmp eax, -1
    je .notfound
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_running
    call term_print
    mov esi, name_buf
    call term_print
    mov al, 10
    call term_putc
    mov al, COL_NORMAL
    call term_set_color
    pushad
    call PROG_ADDR                      ; ← 程序在这里跑,它 ret 就回来
    popad
    mov al, 10
    call term_putc
    mov al, COL_OK
    call term_set_color
    mov esi, msg_prog_done
    call term_print
    ret
.notfound:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_no_file
    call term_print
    ret
.toobig:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_prog_toobig
    call term_print
    ret
.usage:
    mov al, COL_NORMAL
    call term_set_color
    mov esi, api_usage
    call term_print
    ret

; strip_name:把 [cmd_arg] 尾巴上的空格改成 0(顺便去掉换行)
strip_name:
    push eax
    push esi
    mov esi, [cmd_arg]
.next:
    mov al, [esi]
    test al, al
    jz .done
    cmp al, ' '
    je .cut
    inc esi
    jmp .next
.cut:
    mov byte [esi], 0
.done:
    pop esi
    pop eax
    ret

; strlen:esi → eax(不含结尾 0)
strlen:
    push esi
    xor eax, eax
.loop:
    cmp byte [esi], 0
    je .done
    inc esi
    inc eax
    jmp .loop
.done:
    pop esi
    ret

cmd_zh:
    mov al, COL_NORMAL
    call term_set_color
    mov esi, msg_zh_note
    call term_print
    xor ecx, ecx                        ; 一条一条打
.next:
    cmp ecx, zh_str_count
    jae .done
    mov esi, zh_str_table
    mov esi, [esi + ecx * 4]
    push ecx
    call term_print                     ; UTF-8 字节串,走的是统一的那条路
    mov al, 10
    call term_putc
    pop ecx
    inc ecx
    jmp .next
.done:
    ; ---- 顺手演示两件事 ----
    ; (1) 4 字节 UTF-8:emoji 的码位在 U+1F600 以上,得走 4 字节那条分支
    mov esi, msg_zh_emoji
    call term_print
    ; (2) 故意坏的 UTF-8:截断的 3 字节序列 + 一个孤立延续字节
    ;     → 应该画出两个替换字符 U+FFFD(�),而且后面的文字还能继续显示
    mov esi, msg_zh_broken
    call term_print
    mov esi, msg_zh_broken2
    call term_print
    mov al, 10
    call term_putc
    ret

cmd_echo:
    mov esi, [cmd_arg]
    call term_print
    mov al, 10
    call term_putc
    ret

cmd_clear:
    call term_clear
    ret

cmd_info:
    mov esi, msg_info_head
    call term_print

    ; ---- 读盘方式 / 内核区 ----
    mov esi, msg_info_disk
    call term_print
    cmp dword [boot_mode], 0
    je .chs
    mov esi, msg_disk_lba
    jmp .d1
.chs:
    mov esi, msg_disk_chs
.d1:
    call term_print

    mov esi, msg_info_kernel
    call term_print
    mov eax, kmain
    call term_print_hex
    mov esi, msg_info_kernel2
    call term_print

    ; ---- 控制寄存器 ----
    mov esi, msg_info_cr0
    call term_print
    mov eax, cr0
    call term_print_hex
    mov esi, msg_info_cr3
    call term_print
    mov eax, cr3
    call term_print_hex
    mov al, 10
    call term_putc

    mov esi, msg_info_cr2
    call term_print
    mov eax, cr2
    call term_print_hex
    mov esi, msg_info_cr4
    call term_print
    mov eax, cr4
    call term_print_hex
    mov al, 10
    call term_putc

    ; ---- IDT 的基址和限长(sidt 把它写到内存里)----
    sidt [idtr_buf]
    mov esi, msg_info_idt
    call term_print
    mov eax, [idtr_buf + 2]               ; 基址
    call term_print_hex
    mov esi, msg_info_idt2
    call term_print
    movzx eax, word [idtr_buf]            ; 限长
    call term_print_hex
    mov esi, msg_info_idt3
    call term_print

    ; ---- 段寄存器 ----
    mov esi, msg_info_seg
    call term_print
    xor eax, eax
    mov ax, cs
    call term_print_hex
    mov esi, msg_info_seg2
    call term_print
    mov ax, ds
    movzx eax, ax
    call term_print_hex
    mov esi, msg_info_seg3
    call term_print

    ; ---- 页表 ----
    mov esi, msg_info_page
    call term_print
    ret

cmd_page:
    mov esi, [cmd_arg]
    call parse_hex                        ; eax = 地址,CF=1 表示没解析出
    jnc .ok
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_page_usage
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    ret
.ok:
    mov [page_va], eax
    mov esi, msg_page_va
    call term_print
    mov eax, [page_va]
    call term_print_hex
    mov al, 10
    call term_putc

    ; ---- 第一级:页目录 ----
    mov eax, [page_va]
    shr eax, 22                           ; 页目录索引(高 10 位)
    and eax, 0x3FF
    mov [page_pde_idx], eax
    mov esi, msg_page_pde
    call term_print
    call term_print_hex
    mov esi, msg_page_lbracket
    call term_print
    call term_print_dec
    mov esi, msg_page_rbracket
    call term_print
    mov esi, msg_page_equals
    call term_print

    mov ebx, cr3                          ; 页目录的物理地址
    mov eax, [page_pde_idx]
    mov eax, [ebx + eax * 4]              ; PDE
    mov [page_pde], eax
    call term_print_hex
    test eax, 1                           ; bit0 P
    jz .no_pde
    mov esi, msg_page_present
    call term_print
    test eax, 2
    jz .pde_ro
    mov esi, msg_page_writable
    jmp .pde_flags_done
.pde_ro:
    mov esi, msg_page_readonly
.pde_flags_done:
    call term_print
    mov al, 10
    call term_putc

    ; ---- 第二级:页表 ----
    mov eax, [page_pde]
    and eax, 0xFFFFF000                   ; 页表物理地址
    mov ebx, eax
    mov eax, [page_va]
    shr eax, 12
    and eax, 0x3FF                        ; 页表索引(中间 10 位)
    mov [page_pte_idx], eax
    mov esi, msg_page_pte
    call term_print
    call term_print_hex
    mov esi, msg_page_lbracket
    call term_print
    call term_print_dec
    mov esi, msg_page_rbracket
    call term_print
    mov esi, msg_page_equals
    call term_print
    mov eax, [page_pte_idx]
    mov eax, [ebx + eax * 4]              ; PTE
    call term_print_hex
    test eax, 1
    jz .no_pte
    mov esi, msg_page_present
    call term_print
    mov al, 10
    call term_putc

    ; ---- 翻译结果:物理地址 ----
    and eax, 0xFFFFF000
    mov ebx, [page_va]
    and ebx, 0xFFF                        ; 页内偏移(低 12 位)
    add eax, ebx
    mov esi, msg_page_phys
    call term_print
    call term_print_hex
    mov al, 10
    call term_putc
    ret

.no_pde:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_page_npde
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    ret
.no_pte:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_page_npte
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    ret

; 故意踩没映射的地址 → 14 号页错误,panic 屏里会打出 CR2
cmd_fault:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_fault
    call term_print
    mov eax, [0x00800000]                 ; 4 MiB 之外,页目录里没有这一项
    ret                                   ; 走不到这里

; 重启:传统做法是让 8042 键盘控制器拉复位线(0xFE)
cmd_reboot:
    mov esi, msg_reboot
    call term_print
    mov al, 0xFE
    out 0x64, al
    ; 万一 8042 不理我们,就三重故障自杀:空 IDT + 故意中断
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_reboot_fail
    call term_print
    cli
    lidt [empty_idt]
    int 0x20
    hlt                                   ; 真到这儿就只能拔电了

; ---------------------------------------------------------------------------
;  parse_hex:把 [cmd_arg] 当十六进制数解析(可以带 0x),返 eax + CF
; ---------------------------------------------------------------------------
parse_hex:
    push esi
    push ebx
    push ecx
    mov esi, [cmd_arg]
    ; 允许前缀 0x
    cmp byte [esi], '0'
    jne .digits
    mov al, [esi + 1]
    or  al, 0x20                          ; 小写化
    cmp al, 'x'
    jne .digits
    add esi, 2
.digits:
    xor eax, eax
    xor ecx, ecx                          ; 数字位数
.next:
    mov bl, [esi]
    test bl, bl
    jz .end
    cmp bl, ' '
    je .end
    ; 转数值
    cmp bl, '0'
    jb .bad
    cmp bl, '9'
    jbe .digit
    or  bl, 0x20
    cmp bl, 'a'
    jb .bad
    cmp bl, 'f'
    ja .bad
    sub bl, 'a' - 10
    jmp .accum
.digit:
    sub bl, '0'
.accum:
    shl eax, 4
    movzx ebx, bl
    add eax, ebx
    inc ecx
    cmp ecx, 8                            ; 32 位了,再长就溢出了
    ja .bad
    inc esi
    jmp .next
.end:
    test ecx, ecx
    jz .bad                               ; 一个数字都没有
    clc
    jmp .out
.bad:
    stc
.out:
    pop ecx
    pop ebx
    pop esi
    ret

; ---------------------------------------------------------------------------
;  命令表:名字 + 处理函数(名字为 0 表示表尾)
; ---------------------------------------------------------------------------
n_help   db 'help', 0
n_echo   db 'echo', 0
n_zh     db 'zh', 0
n_ls     db 'ls', 0
n_cat    db 'cat', 0
n_write  db 'write', 0
n_run    db 'run', 0
n_clear  db 'clear', 0
n_info   db 'info', 0
n_page   db 'page', 0
n_fault  db 'fault', 0
n_reboot db 'reboot', 0

cmd_table:
    dd n_help,   cmd_help
    dd n_echo,   cmd_echo
    dd n_zh,     cmd_zh
    dd n_ls,     cmd_ls
    dd n_cat,    cmd_cat
    dd n_write,  cmd_write
    dd n_run,    cmd_run
    dd n_clear,  cmd_clear
    dd n_info,   cmd_info
    dd n_page,   cmd_page
    dd n_fault,  cmd_fault
    dd n_reboot, cmd_reboot
    dd 0, 0

; ---------------------------------------------------------------------------
;  数据
; ---------------------------------------------------------------------------
msg_shell_hello db 'type "help" for commands.', 10, 0
msg_prompt      db '> ', 0
msg_shell_unknown db 'unknown command: ', 0
msg_zh_note     db 'zh: glyphs from GNU Unifont, blitted straight into the VBE framebuffer', 10, 0
msg_zh_emoji    db 'emoji (4-byte UTF-8): 😀', 10, 0
msg_zh_broken   db 'broken UTF-8: [', 0xE4, 0xBD, 0x20, 0x80, '] (should be two', 0
msg_zh_broken2  db ' replacement chars, and this text still shows)', 10, 0
msg_fault       db 'touching an unmapped address on purpose...', 10, 0
msg_reboot      db 'rebooting...', 10, 0
msg_reboot_fail db '8042 did not reset, trying triple fault...', 10, 0

msg_help db \
    'help          show this list', 10, \
    'echo <text>   print the text back', 10, \
    'zh            print Chinese (bitmap glyphs from GNU Unifont)', 10, \
    'clear         clear the screen', 10, \
    'info          CPU / paging / IDT info', 10, \
    'page <hex>    walk the page tables, e.g. page 0x400000', 10, \
    'fault         touch an unmapped page on purpose', 10, \
    'reboot        restart the machine', 10, \
    'ls            list files on the FAT16 disk', 10, \
    'cat <file>    print a text file (UTF-8)', 10, \
    'write <f> <t> create/overwrite a file', 10, \
    'run <file>    run a program from disk (.BIN; bare "run" = the ABI)', 10, 0

msg_info_head    db '--- JoyOS info ---', 10, 0
msg_info_disk    db 'boot disk   : ', 0
msg_info_kernel  db 'kernel      : ', 0
msg_info_kernel2 db ' .. +32 KiB (64 sectors from LBA 1)', 10, 0
msg_info_cr0     db 'CR0 = ', 0
msg_info_cr3     db '   CR3 = ', 0
msg_info_cr2     db 'CR2 = ', 0
msg_info_cr4     db '   CR4 = ', 0
msg_info_idt     db 'IDT         : base = ', 0
msg_info_idt2    db '   limit = ', 0
msg_info_idt3    db '  (256 vectors)', 10, 0
msg_info_seg     db 'segments    : CS = ', 0
msg_info_seg2    db '   DS = ', 0
msg_info_seg3    db '  (flat: base 0, limit 4 GiB)', 10, 0
msg_info_page    db 'paging      : identity 0..4 MiB; 0x00400000 -> 0x00100000', 10, \
                    '              CR0.PG = 1 (bit31), CR4.PSE = 0 (4 KiB pages)', 10, 0

msg_page_usage   db 'usage: page <hex address>, e.g. page 0x400000', 10, 0
msg_page_va      db 'virtual      = ', 0
msg_page_pde     db 'PDE index    = ', 0
msg_page_pte     db 'PTE index    = ', 0
msg_page_equals  db ' = ', 0
msg_page_lbracket db ' [', 0
msg_page_rbracket db ']', 0
msg_page_present db '  present', 0
msg_page_writable db ' + writable', 0
msg_page_readonly db ' + read-only', 0
msg_page_npde    db '  PDE not present -> would page-fault', 10, 0
msg_page_npte    db '  PTE not present -> would page-fault', 10, 0
msg_page_phys    db 'physical     = ', 0

msg_no_fat      db 'no FAT16 filesystem (boot from the hard-disk image)', 10, 0
msg_no_file     db 'file not found', 10, 0
msg_wrote       db 'wrote ', 0
msg_write_usage db 'usage: write <name> <text>', 10, 0
msg_write_fail  db 'write failed (disk full?)', 10, 0
msg_running     db 'running ', 0
msg_prog_done   db 'program returned to the shell', 10, 0
msg_prog_toobig db 'program too big for the load area', 10, 0
msg_file_toobig db 'file too big to print (over 60 KiB)', 10, 0

PROG_ADDR      equ 0x120000             ; 程序加载地址(progs/*.asm 里的 ORG 要和它一致)
PROG_MAX_SIZE  equ FONT_LOAD_ADDR - PROG_ADDR
                                        ; 0xE0000 = 896 KB:再往上就是磁盘字库(0x200000)了
FILE_BUF       equ 0x110000             ; cat 用的文件缓冲(1 MiB 往上,别压到字库)
FILE_MAX       equ PROG_ARG_ADDR - FILE_BUF
                                        ; 0xF000 = 60 KB:再往上就是程序参数块(0x11F000)

name_buf   times 16 db 0
prog_name_ptr dd 0                      ; run 用的:去掉目录部分之后的程序名
file_size  dd 0

shell_buf  times SHELL_LINE_MAX db 0
shell_len  dd 0
cmd_len    dd 0
cmd_arg    dd 0

page_va      dd 0
page_pde     dd 0
page_pde_idx dd 0
page_pte_idx dd 0

idtr_buf   times 6 db 0
empty_idt  dw 0
           dd 0
