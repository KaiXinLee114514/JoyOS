; ============================================================================
;  KKernel — 顺序管道(pipe)的内核那一半
;
;  为什么是"顺序":现在一次只让一个 ring 3 程序跑(space 锁),没有"两个程序
;  同时在跑"这回事。所以管道不需要 Linux 那套"写满就睡/读空就睡/对方死了报
;  SIGPIPE"的等待队列 —— 直接把 A 的输出吃进缓冲,跑完 A 再跑 B 喂给它就行。
;
;  数据流:
;     A 跑的时候  term_putc / term_print 不再画屏幕
;                 → pipe_capture_byte / pipe_capture_str 往 pipe_out_buf 追加
;     A 跑完      → shell 拿到"这一坨字节",切成下一段的 stdin
;     B 跑的时候  程序调 int 0x30 功能 17 → pipe_read 从 pipe_in_buf 读字节
;
;  缓冲从物理页池借(pmem_alloc_pages),恒等映射在,物理地址就是虚拟地址,
;  直接当指针用。链跑完 shell 负责免费还回去(pmem_free_pages)。
;
;  截断策略:缓冲满了就丢后面的字节、置 pipe_out_trunc,链末尾 shell 提示一句。
;  没做"背压"——顺序执行下,生产者想快也快不到哪去,不需要。
; ============================================================================

; ---------------------------------------------------------------------------
;  捕获状态(生产者的输出往哪塞)
; ---------------------------------------------------------------------------
pipe_capture_on  dd 0                   ; 1 = 正在捕获(终端输出不画屏)
pipe_out_buf     dd 0                   ; 缓冲地址(物理/恒等映射地址)
pipe_out_len     dd 0                   ; 已写字节数
pipe_out_max     dd 0                   ; 上限(字节)
pipe_out_trunc   dd 0                   ; 1 = 满过,后面的字节被丢

; ---------------------------------------------------------------------------
;  输入状态(消费者的 stdin 从哪读)
; ---------------------------------------------------------------------------
pipe_in_on   dd 0                       ; 1 = 有输入可读
pipe_in_buf  dd 0                       ; 缓冲地址
pipe_in_len  dd 0                       ; 总字节数
pipe_in_pos  dd 0                       ; 读到哪

pipe_active  dd 0                       ; 1 = 正在跑一条管道链(shell 爱把提示信息静音)

; ---------------------------------------------------------------------------
;  pipe_reset:整条链结束后清干净(出错路径也要调)
; ---------------------------------------------------------------------------
pipe_reset:
    push eax
    mov dword [pipe_capture_on], 0
    mov dword [pipe_out_buf], 0
    mov dword [pipe_out_len], 0
    mov dword [pipe_out_max], 0
    mov dword [pipe_out_trunc], 0
    mov dword [pipe_in_on], 0
    mov dword [pipe_in_buf], 0
    mov dword [pipe_in_len], 0
    mov dword [pipe_in_pos], 0
    pop eax
    ret

; ---------------------------------------------------------------------------
;  pipe_out_begin:eax = 缓冲地址,ecx = 字节上限 → 开始捕获
; ---------------------------------------------------------------------------
pipe_out_begin:
    mov [pipe_out_buf], eax
    mov dword [pipe_out_len], 0
    mov [pipe_out_max], ecx
    mov dword [pipe_out_trunc], 0
    mov dword [pipe_capture_on], 1
    ret

; ---------------------------------------------------------------------------
;  pipe_out_end:停止捕获 → eax = 捕到多少字节,edx = 截断标记
; ---------------------------------------------------------------------------
pipe_out_end:
    mov dword [pipe_capture_on], 0
    mov eax, [pipe_out_len]
    mov edx, [pipe_out_trunc]
    ret

; ---------------------------------------------------------------------------
;  pipe_in_set:eax = 缓冲地址,ecx = 字节数 → 下一段程序从这里读
; ---------------------------------------------------------------------------
pipe_in_set:
    mov [pipe_in_buf], eax
    mov [pipe_in_len], ecx
    mov dword [pipe_in_pos], 0
    mov dword [pipe_in_on], 1
    ret

; ---------------------------------------------------------------------------
;  pipe_capture_byte:al = 一个字节 → 追加进输出缓冲
;  (调用方是 term_putc / term_print 的捕获分支)
; ---------------------------------------------------------------------------
pipe_capture_byte:
    cmp dword [pipe_capture_on], 0
    je .ret
    push ebx
    push edx
    mov ebx, [pipe_out_len]
    cmp ebx, [pipe_out_max]
    jae .full
    mov edx, [pipe_out_buf]
    mov [edx + ebx], al
    inc ebx
    mov [pipe_out_len], ebx
    pop edx
    pop ebx
.ret:
    ret
.full:
    mov dword [pipe_out_trunc], 1
    pop edx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  pipe_capture_str:esi = 以 0 结尾的串 → 原样追加(UTF-8 字节一个不改)
;  为什么是"原样":term_print 本来就是按 UTF-8 解成码位再画的,这里提前截住,
;  直接把程序写出来的字节存下来,消费者拿到的和程序想输出的一模一样。
; ---------------------------------------------------------------------------
pipe_capture_str:
    push eax
    push esi
.loop:
    mov al, [esi]
    test al, al
    jz .done
    call pipe_capture_byte
    inc esi
    jmp .loop
.done:
    pop esi
    pop eax
    ret

; ---------------------------------------------------------------------------
;  pipe_capture_cp:eax = Unicode 码位 → 编成 UTF-8 再追加
;  (程序用 int 0x30 功能 3 打单字时走这里;功能 0 的整串走 pipe_capture_str)
; ---------------------------------------------------------------------------
pipe_capture_cp:
    cmp dword [pipe_capture_on], 0
    je .ret
    push eax
    push ebx
    push ecx
    push edx
    ; ---- 按码位大小选 1~4 字节 ----
    cmp eax, 0x80
    jae .try2
    ; 1 字节:0xxxxxxx
    call pipe_capture_byte
    jmp .out
.try2:
    cmp eax, 0x800
    jae .try3
    ; 2 字节:110xxxxx 10xxxxxx
    mov ebx, eax
    shr ebx, 6
    and bl, 0x1F
    or  bl, 0xC0
    mov ecx, eax
    and cl, 0x3F
    or  cl, 0x80
    mov al, bl
    call pipe_capture_byte
    mov al, cl
    call pipe_capture_byte
    jmp .out
.try3:
    cmp eax, 0x10000
    jae .four
    ; 3 字节:1110xxxx 10xxxxxx 10xxxxxx
    mov edx, eax
    shr edx, 12
    and dl, 0x0F
    or  dl, 0xE0
    mov ebx, eax
    shr ebx, 6
    and bl, 0x3F
    or  bl, 0x80
    mov ecx, eax
    and cl, 0x3F
    or  cl, 0x80
    mov al, dl
    call pipe_capture_byte
    mov al, bl
    call pipe_capture_byte
    mov al, cl
    call pipe_capture_byte
    jmp .out
.four:
    ; 4 字节:11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
    mov edx, eax
    shr edx, 18
    and dl, 0x07
    or  dl, 0xF0
    push eax
    mov ebx, eax
    shr ebx, 12
    and bl, 0x3F
    or  bl, 0x80
    mov ecx, eax
    shr ecx, 6
    and cl, 0x3F
    or  cl, 0x80
    and al, 0x3F
    or  al, 0x80
    mov [pipe_cp_tmp], al
    mov al, dl
    call pipe_capture_byte
    mov al, bl
    call pipe_capture_byte
    mov al, cl
    call pipe_capture_byte
    mov al, [pipe_cp_tmp]
    call pipe_capture_byte
    pop eax
.out:
    pop edx
    pop ecx
    pop ebx
    pop eax
.ret:
    ret

pipe_cp_tmp dd 0

; ---------------------------------------------------------------------------
;  pipe_read:int 0x30 功能 17 —— 读 stdin(管道输入)
;      edi = 缓冲区,ecx = 最多读多少 → eax = 实际读到多少(0 = EOF)
;  没有管道输入时直接返 0:工具程序在普通命令行里跑会立刻看到 EOF。
; ---------------------------------------------------------------------------
pipe_read:
    push ebx
    push edx
    push esi
    push edi
    xor eax, eax
    cmp dword [pipe_in_on], 0
    je .done
    mov ebx, [pipe_in_pos]
    mov edx, [pipe_in_len]
    sub edx, ebx                        ; edx = 还剩多少字节
    jbe .done                           ; 读光了 → EOF
    cmp edx, ecx                        ; 最多给调用方要的那么多
    jbe .len_ok
    mov edx, ecx
.len_ok:
    test edx, edx
    jz .done
    mov esi, [pipe_in_buf]
    add esi, ebx
    push ecx
    mov ecx, edx
    rep movsb
    pop ecx
    add dword [pipe_in_pos], edx
    mov eax, edx
.done:
    pop edi
    pop esi
    pop edx
    pop ebx
    ret
