; ============================================================================
;  JoyOS (胡闹OS) — 那个很土的 shell
;
;  能干的:
;      help            列出命令
;      echo <文字>     把文字打回来
;      clear           清屏
;      info            系统信息(CR0/CR3/IDT/段寄存器/读盘方式...)
;      debug <什么>    诊断/自检:page / pmem / pmap / pumap / ptest / fault
;                      (演示类命令都收在这条下面;中文演示在磁盘程序 UTF8.BIN)
;      reboot          重启(通过 8042 键盘控制器)
;      ls              列 FAT16 根目录
;      cat <文件>      把一个文本文件(UTF-8)打出来,中文能直接看
;      write <文件> <内容>  写文件(创建或覆盖,真的落到磁盘上)
;      run <文件>      把程序从磁盘读进内存跑(.BIN,平铺二进制)
;
;  注意:键盘直接给字节,没有输入法 —— 命令行本身只能打 ASCII。
;  想看中文就用 cat(文件里存的是 UTF-8),或者让程序自己打(run UTF8)。
;
;  结构:读一行(shell_readline)→ 切成"命令 + 参数"(shell_execute)→ 查表跳转。
;  多 shell:4 条 shell 各是一条内核线程(见 shell_main / shell_switch_to),
;  Ctrl+←/→ 在键盘中断里换手,活动的那条才读键盘;换过去会重画半行。
;  行编辑只有退格和回车 —— 光标键要先处理 0xE0 前缀,留给你自己加。
; ============================================================================

SHELL_LINE_MAX equ 64

SH_MAX         equ 4                    ; 一共几条 shell(每条 = 一条内核线程,0 号就是主线程)
SH_BUF_SZ      equ SHELL_LINE_MAX + 4   ; 每条 shell 备份一整个输入缓冲(多留几字节放结尾 0)
SH_DIR_SZ      equ 64                   ; 和 cwd_str 一样大

; ---------------------------------------------------------------------------
;  shell_main:打招呼 → 循环(等轮到我 → 提示符 → 读一行 → 执行)
;
;  多 shell:每条 shell 就是一条内核线程,入口都是这里。键盘归谁由 [sh_active]
;  说了算(Ctrl+←/→ 或 shell <n> 改它)。没轮到的线程在下面 hlt 睡着;被切过去
;  的时候状态由中断装好,醒来的这条只负责把标题 / 提示符 / 没敲完的半行重画一遍。
; ---------------------------------------------------------------------------
shell_main:
    cmp dword [sched_cur], 0            ; 欢迎词只让 1 号 shell 打
    jne .loop
    mov al, 10
    call term_putc
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_shell_hello
    call term_print

.loop:
    ; ---- 等轮到我:不是活动 shell 就睡着,让中断把 CPU 收走 ----
    mov eax, [sched_cur]
    cmp eax, [sh_active]
    je .mine
    hlt
    jmp .loop

.mine:
    ; ---- 刚被切过来:印标题 + 提示符,再把没敲完的那半行恢复出来 ----
    cmp dword [sh_switch_flag], 0
    je .fresh
    mov dword [sh_switch_flag], 0
    mov al, 10
    call term_putc                        ; 先换行:标题别接在上一条 shell 的半行后面
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_sh_switch
    call term_print
    mov eax, [sh_active]
    inc eax
    call term_print_dec
    mov esi, msg_sh_switch2
    call term_print
    call shell_print_prompt
    mov esi, shell_buf                  ; 恢复出来的半行(备份时补过结尾 0)
    call term_print
    call shell_readline_resume
    jmp .after_line
.fresh:
    call shell_print_prompt
    call shell_readline
.after_line:
    ; ---- 读到的这行还是我的吗?中途被换走就丢掉,回上面接着等 ----
    mov eax, [sched_cur]
    cmp eax, [sh_active]
    jne .loop
    call shell_execute
    ; 这行已经执行完了,清掉:换回来时不该把上一条命令重新印出来
    ; (不清的话提示符后面挂着一截旧命令,接着打字就串成怪命令 —— 踩过)
    mov dword [shell_len], 0
    mov byte [shell_buf], 0
    jmp .loop

; ---------------------------------------------------------------------------
;  shell_print_prompt:活动 shell 的提示符(1 号是 "> ",别的打 "2> ")
; ---------------------------------------------------------------------------
shell_print_prompt:
    mov al, COL_HEADER
    call term_set_color
    cmp byte [cwd_str], 0
    je .arrow
    mov esi, cwd_str
    call term_print
.arrow:
    mov eax, [sh_active]
    test eax, eax
    jz .plain
    inc eax
    call term_print_dec
.plain:
    mov esi, msg_prompt
    call term_print
    ret

; ---------------------------------------------------------------------------
;  shell_switch_to:把键盘交给 eax 号 shell(0..SH_MAX-1)
;
;  这是**在键盘中断里**跑的,所以绝对不能打印、不能阻塞:
;    1. 把当前活动 shell 的 输入缓冲 / 长度 / 当前目录 备份进它自己的格子
;    2. 改 [sh_active],并把新活动 shell 的那份装回全局
;       (立刻装:连按两下 Ctrl+→ 也不会把状态串到别人身上)
;    3. 立 [sh_switch_flag]:它醒来时知道要重画
;    4. 往键盘缓冲塞一个 0x00 —— 还在 kbd_getchar 里睡着的那条会被叫醒,
;       醒来先看"我还是活动的吗",不是就回主循环接着睡(0x00 是控制字符,行编辑会丢)
; ---------------------------------------------------------------------------
shell_switch_to:
    cmp eax, [sh_active]
    je .done                            ; 本来就归它
    pushad
    mov [sh_target], eax

    ; ---- 1) 备份当前活动 shell ----
    mov ebx, [sh_active]
    mov edi, ebx
    imul edi, SH_BUF_SZ
    add edi, sh_nbuf
    mov esi, shell_buf
    mov ecx, SHELL_LINE_MAX
    rep movsb
    mov byte [edi], 0                   ; 槽比行大 4 字节,顺手补上结尾
    mov eax, [shell_len]
    mov [sh_nlen + ebx * 4], eax
    mov edi, ebx
    imul edi, SH_DIR_SZ
    add edi, sh_ndir
    mov esi, cwd_str
    mov ecx, SH_DIR_SZ
    rep movsb

    ; ---- 2) 换主人,把它的状态装回全局 ----
    mov eax, [sh_target]
    mov [sh_active], eax
    mov ebx, eax
    mov esi, ebx
    imul esi, SH_BUF_SZ
    add esi, sh_nbuf
    mov edi, shell_buf
    mov ecx, SHELL_LINE_MAX
    rep movsb
    mov eax, [sh_nlen + ebx * 4]
    mov [shell_len], eax
    mov esi, ebx
    imul esi, SH_DIR_SZ
    add esi, sh_ndir
    mov edi, cwd_str
    mov ecx, SH_DIR_SZ
    rep movsb
    mov dword [sh_switch_flag], 1

    ; ---- 3) 叫醒可能正睡在 kbd_getchar 里的那条 ----
    xor al, al
    call kbd_push
    popad
.done:
    ret

; ---------------------------------------------------------------------------
;  shell_switch_step:al = ±1 → 从当前这条往前/往后挪一条(热键用)
; ---------------------------------------------------------------------------
shell_switch_step:
    movsx eax, al
    add eax, [sh_active]
    and eax, SH_MAX - 1                 ; SH_MAX 是 2 的幂,直接绕圈
    jmp shell_switch_to

; ---------------------------------------------------------------------------
;  shell_spawn_extra:开机时再起 SH_MAX-1 条 shell 线程(0 号就是主线程)
; ---------------------------------------------------------------------------
shell_spawn_extra:
    pushad
    mov ebp, 1
.next:
    cmp ebp, SH_MAX
    jae .done
    mov eax, shell_main
    mov ebx, sh_names
    mov ebx, [ebx + ebp * 4]
    call sched_spawn
    jc .done                            ; 页池空了就只能少起几条
    inc ebp
    jmp .next
.done:
    popad
    ret

; ---------------------------------------------------------------------------
;  cmd_shell:不带参数 → 列一下;带编号 → 直接跳过去
; ---------------------------------------------------------------------------
cmd_shell:
    pushad
    call strip_name
    mov esi, [cmd_arg]
    cmp byte [esi], 0
    je .list
    call parse_dec
    jc .usage
    cmp eax, 1
    jb .usage
    cmp eax, SH_MAX
    ja .usage
    dec eax
    cmp eax, [sh_active]
    je .same
    ; 这条命令本身已经用掉了,先清掉,免得备份进我的格子再被印出来
    mov dword [shell_len], 0
    mov byte [shell_buf], 0
    call shell_switch_to                ; 交出去:这条马上会回主循环睡着
    popad
    ret
.same:
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_shell_same
    call term_print
    popad
    ret
.list:
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_shell_list
    call term_print
    mov eax, SH_MAX
    call term_print_dec
    mov esi, msg_shell_list2
    call term_print
    mov eax, [sh_active]
    inc eax
    call term_print_dec
    mov esi, msg_shell_list3
    call term_print
    xor ebp, ebp
.row:
    cmp ebp, SH_MAX
    jae .rows_done
    mov al, COL_NORMAL
    call term_set_color
    mov esi, msg_shell_row
    call term_print
    mov eax, ebp
    inc eax
    call term_print_dec
    mov esi, msg_shell_row2
    call term_print
    mov eax, ebp
    call sched_name
    call term_print
    mov al, COL_HEADER
    call term_set_color
    cmp ebp, [sh_active]
    jne .row_next
    mov esi, msg_shell_active
    call term_print
.row_next:
    mov al, 10
    call term_putc
    inc ebp
    jmp .row
.rows_done:
    mov al, COL_NORMAL
    call term_set_color
    mov esi, msg_shell_hint
    call term_print
    popad
    ret
.usage:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_shell_usage
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    popad
    ret

; ---------------------------------------------------------------------------
;  shell_readline:读一行到 shell_buf(带退格),回车结束
; ---------------------------------------------------------------------------
shell_readline:
    mov dword [shell_len], 0
; ---------------------------------------------------------------------------
;  shell_readline_resume:接着编辑已经躺在 shell_buf 里的那半行(换回来时用)
; ---------------------------------------------------------------------------
shell_readline_resume:
    mov al, COL_NORMAL
    call term_set_color
.next:
    ; ---- 中途被换走了?这一行就不归我了:立刻退出,别碰全局状态 ----
    ;      (全局的 shell_buf/shell_len 此刻已经是新活动 shell 的了)
    mov eax, [sched_cur]
    cmp eax, [sh_active]
    jne .yield
    call shell_wait_key                   ; 只为活动 shell 等键(见上面的说明)
    cmp al, 13                            ; Enter
    je .done
    cmp al, 8                             ; Backspace
    je .backspace
    cmp al, 32                            ; 其它控制字符先不管
    jb .next
    cmp al, 0x80                          ; ≥0x80 = 多字节 UTF-8 的首字节
    jae .multibyte
    cmp dword [shell_len], SHELL_LINE_MAX - 1
    jae .next                             ; 满了就丢(不给它撑爆的机会)
    mov ebx, [shell_len]
    mov [shell_buf + ebx], al
    inc dword [shell_len]
    call term_putc                        ; 回显
    jmp .next
.multibyte:
    call shell_read_mb                    ; 中文/日文/韩文/emoji:整串一起收、一起画
    jmp .next

.backspace:
    cmp dword [shell_len], 0
    je .next
    ; 从尾巴往前跳过"续字节"(0x80~0xBF):一个汉字三个字节必须一起删,
    ; 只删一个字节的话缓冲区里会剩半个序列,下次重画就成方块了(踩过)
    mov ecx, [shell_len]
    dec ecx
.skip_cont:
    cmp ecx, 0
    jbe .cut
    mov al, [shell_buf + ecx]
    and al, 0xC0
    cmp al, 0x80
    jne .cut
    dec ecx
    jmp .skip_cont
.cut:
    mov ebx, ecx                          ; ebx = 这个字符的第一个字节
    mov eax, [shell_len]
    sub eax, ebx                          ; eax = 它占了几个字节
    mov [shell_len], ebx
    mov byte [shell_buf + ebx], 0
    ; 屏幕上按宽度擦:ASCII 1 格,多字节按 2 格(字库里的都是宽字形)
    cmp eax, 1
    jne .erase_wide
    mov al, 8
    call term_putc
    mov al, ' '
    call term_putc
    mov al, 8
    call term_putc
    jmp .next
.erase_wide:
    mov al, 8
    call term_putc
    mov al, 8
    call term_putc
    mov al, ' '
    call term_putc
    mov al, ' '
    call term_putc
    mov al, 8
    call term_putc
    mov al, 8
    call term_putc
    jmp .next

.yield:
    ret                                 ; 换 shell 了:缓冲区现在是别人的,直接走

.done:
    mov ebx, [shell_len]
    mov byte [shell_buf + ebx], 0         ; 补个结尾,方便当字符串用
    mov al, 10
    call term_putc
    ret

; ---------------------------------------------------------------------------
;  shell_read_mb:al = UTF-8 首字节 → 把这个字符整个收进 shell_buf 并回显
;
;  为什么不能像 ASCII 那样一个字节一个字节画:一个汉字是 3 个字节,
;  分开画的话每个字节都单独解码,全都不合法 → 屏幕上三个"缺字形方块"
;  (Alt 码位输入打中文时一眼就能看见)。所以这里按首字节算出长度,把整串
;  一起交给 term_print(它认 UTF-8,会画出真正的字形、也会按宽度推进光标)。
; ---------------------------------------------------------------------------
shell_read_mb:
    push eax
    push ebx
    push ecx
    push edx
    mov [mb_first], al                    ; 首字节(别留在 bl 里:下面要用 ebx)
    movzx eax, al
    mov ebx, 1                            ; 先当单字节(不认识的字节就原样画)
    cmp al, 0xC0
    jb .have_len
    mov ebx, 2
    cmp al, 0xE0
    jb .have_len
    mov ebx, 3
    cmp al, 0xF0
    jb .have_len
    mov ebx, 4
.have_len:
    ; ⚠ 长度必须放内存里:kbd_getchar 会冲掉 ecx(踩过,结果画出来是两个方块)
    mov [mb_len], ebx
    mov eax, [shell_len]
    add eax, ebx
    cmp eax, SHELL_LINE_MAX - 1
    jae .done                            ; 放不下就整个丢掉
    mov eax, [shell_len]
    mov dl, [mb_first]
    mov [shell_buf + eax], dl
    inc dword [shell_len]
    mov dword [mb_got], 1                 ; 已经收进来几个字节
.more:
    mov eax, [mb_got]
    cmp eax, [mb_len]
    jae .echo
    call shell_wait_key                   ; 续字节(Alt 码位输入是一次性推进来的)
    mov ecx, [sched_cur]                  ; 收到一半被换走了:这个字符就不要了
    cmp ecx, [sh_active]
    jne .done
    mov ebx, [shell_len]
    mov [shell_buf + ebx], al
    inc dword [shell_len]
    inc dword [mb_got]
    jmp .more

.echo:
    mov ebx, [shell_len]
    sub ebx, [mb_len]                     ; 这个字符在缓冲里的起点
    mov eax, [mb_len]
    mov byte [shell_buf + ebx + eax], 0   ; 临时收尾(在 len 之外,不影响数据)
    lea esi, [shell_buf + ebx]
    call term_print
.done:
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  shell_wait_key:等一个字符 —— 但只为"当前活动的那条 shell"等
;   · 不是活动 shell   → 立刻返回(al = 0,调用方查了活动状态就会走人)
;   · 是活动的,但没键 → hlt 睡着(定时器一响就醒,绝不会卡死在一个键上)
;   · 有键             → 才真的调 kbd_getchar 取走
;  为什么要自己包一层:如果让非活动 shell 睡在 kbd_getchar 内部的 hlt 上,
;  它会跟活动 shell 抢"叫醒用的那个字节",抢到就继续在里面等键 —— 结果
;  换回来时不重画提示符,还会把本该给别人的按键吃掉(踩过)。
; ---------------------------------------------------------------------------
shell_wait_key:
    mov eax, [sched_cur]
    cmp eax, [sh_active]
    jne .gone
    call kbd_avail
    test eax, eax
    jz .sleep
    call kbd_getchar                      ; 确实有货,取了就走,不会卡在里面
    push eax
    mov eax, [sched_cur]                  ; 取键那一瞬间被换走?这个键就不要了,
    cmp eax, [sh_active]                  ; 免得写进别人的行缓冲(窗口极窄但真会发生)
    pop eax
    jne .drop
    ret
.sleep:
    hlt                                   ; 键盘/定时器中断都会把这里叫醒
    jmp shell_wait_key
.gone:
.drop:
    xor al, al
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
    mov eax, [fat_dir]                    ; 命令把 cwd 借去用(fat_path 会一层层进去)
    mov [saved_dir], eax
    mov eax, [ebx + 4]
    call eax
    mov eax, [saved_dir]                  ; 用完还回来;cd 会改写 saved_dir
    mov [fat_dir], eax
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
;  debug <what>:诊断/自检类命令都收在这一条下面
;  子命令的实现原样复用(它们都从 [cmd_arg] 读参数),所以先把 [cmd_arg] 挪到
;  子命令后面那截再尾调用过去 —— 它们看到的参数和以前单敲时一样:
;      debug page 0x400000   → cmd_page 拿到的是 "0x400000"
;      debug pmem            → cmd_pmem 拿到空串(它本来也不看参数)
; ---------------------------------------------------------------------------
cmd_debug:
    push esi
    push edi
    push ecx
    push ebx
    mov esi, [cmd_arg]
    cmp byte [esi], 0                   ; 光敲 debug → 列用法
    je .usage

    mov edi, esi                        ; edi = 子命令词开头
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
    sub ecx, edi                        ; ecx = 子命令词长
.arg_skip:
    cmp byte [esi], ' '                 ; 参数从后面的空格之后开始
    jne .arg_ready
    inc esi
    jmp .arg_skip
.arg_ready:
    mov [dbg_arg], esi                  ; 先存好:下面每比一次都要重设 esi
    mov esi, edi
    mov edx, n_page
    call str_eq
    test eax, eax
    jnz .page
    mov esi, edi
    mov edx, n_pmem
    call str_eq
    test eax, eax
    jnz .pmem
    mov esi, edi
    mov edx, n_pmap
    call str_eq
    test eax, eax
    jnz .pmap
    mov esi, edi
    mov edx, n_pumap
    call str_eq
    test eax, eax
    jnz .pumap
    mov esi, edi
    mov edx, n_ptest
    call str_eq
    test eax, eax
    jnz .ptest
    mov esi, edi
    mov edx, n_fault
    call str_eq
    test eax, eax
    jnz .fault
    jmp .usage

.page:
    mov eax, cmd_page
    jmp .go
.pmem:
    mov eax, cmd_pmem
    jmp .go
.pmap:
    mov eax, cmd_pmap
    jmp .go
.pumap:
    mov eax, cmd_pumap
    jmp .go
.ptest:
    mov eax, cmd_ptest
    jmp .go
.fault:
    mov eax, cmd_fault
.go:
    mov ecx, [dbg_arg]                  ; 把参数挪到子命令处理函数看的地方
    mov [cmd_arg], ecx
    pop ebx
    pop ecx
    pop edi
    pop esi
    jmp eax                             ; 尾调用:它的 ret 直接回 shell_execute
.usage:
    mov esi, msg_debug_usage
    call term_print
    pop ebx
    pop ecx
    pop edi
    pop esi
    ret


; ---------------------------------------------------------------------------
;  ls:列根目录
; ---------------------------------------------------------------------------
; ---------------------------------------------------------------------------
;  cd <目录>:换当前目录(不带参数或 / = 回根目录,.. = 上一层)
;  命令跑完后 shell 会把 fat_dir 还原成 saved_dir,所以 cd 要把新目录写进 saved_dir
; ---------------------------------------------------------------------------
cmd_cd:
    cmp byte [fat_ok], 0
    je cmd_ls.nomount
    mov esi, [cmd_arg]
    call strip_name
    mov esi, [cmd_arg]
    cmp byte [esi], 0
    je .root
    cmp byte [esi], '/'
    je .abs
    ; ---- ".." → 父目录 ----
    cmp byte [esi], '.'
    jne .rel
    cmp byte [esi + 1], '.'
    jne .rel
    cmp byte [esi + 2], 0
    jne .rel
    call fat_dotdot
    mov [saved_dir], eax
    call cwd_pop
    ret
.abs:
    inc esi
    cmp byte [esi], 0
    je .root
    mov [cmd_arg], esi                    ; "/DOCS" → 从根开始找 "DOCS"
    mov dword [saved_dir], 0
    mov dword [fat_dir], 0
    mov byte [cwd_str], 0
    jmp .rel
.root:
    mov dword [saved_dir], 0
    mov dword [fat_dir], 0
    mov byte [cwd_str], 0
    ret
.rel:
    mov esi, [cmd_arg]
    call fat_path                         ; 中间几层先进去
    jc .nofound
    cmp byte [eax], 0
    je .joined                            ; 路径以 / 收尾:已经站在里面了
    mov esi, eax
    call fat_chdir                        ; 最后一层
    jc .nofound
.joined:
    mov esi, [cmd_arg]
    call cwd_push
    mov eax, [fat_dir]
    mov [saved_dir], eax
    ret
.nofound:
    mov dword [saved_dir], 0
    mov dword [fat_dir], 0
    mov byte [cwd_str], 0
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_no_dir
    call term_print
    ret

; --- cwd_str 末尾接上一段(esi 指向那段名字) ---
cwd_push:
    push esi
    push edi
    push ecx
    mov edi, cwd_str
.cp_end:
    cmp byte [edi], 0
    je .cp_at_end
    inc edi
    jmp .cp_end
.cp_at_end:
    cmp edi, cwd_str
    je .cp_copy
    mov byte [edi], '/'
    inc edi
.cp_copy:
    mov ecx, 48
.cp_loop:
    lodsb
    test al, al
    jz .cp_done
    cmp al, ' '
    je .cp_done
    cmp al, '/'
    je .cp_done                           ; 尾巴上的斜杠不要
    mov [edi], al
    inc edi
    dec ecx
    jnz .cp_loop
.cp_done:
    mov byte [edi], 0
    pop ecx
    pop edi
    pop esi
    ret

; --- cwd_str 去掉最后一节(cd .. 用) ---
cwd_pop:
    push eax
    push ebx
    mov ebx, cwd_str
    mov eax, ebx
.cpop_scan:
    cmp byte [eax], 0
    je .cpop_cut
    cmp byte [eax], '/'
    jne .cpop_next
    mov ebx, eax                          ; 记住最后一个斜杠
.cpop_next:
    inc eax
    jmp .cpop_scan
.cpop_cut:
    mov byte [ebx], 0
    pop ebx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  mkdir <目录>:建目录
; ---------------------------------------------------------------------------
cmd_mkdir:
    cmp byte [fat_ok], 0
    je cmd_ls.nomount
    mov esi, [cmd_arg]
    call strip_name
    mov esi, [cmd_arg]
    cmp byte [esi], 0
    je .usage
    call fat_path                         ; 支持 mkdir A/B
    jc .fail
    cmp byte [eax], 0
    je .fail
    mov esi, eax
    call fat_mkdir
    test eax, eax
    jnz .fail
    mov al, COL_OK
    call term_set_color
    mov esi, msg_mkdir_ok
    call term_print
    mov esi, [cmd_arg]
    call term_print
    mov al, 10
    call term_putc
    ret
.usage:
    mov esi, msg_mkdir_use
    call term_print
    ret
.fail:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_mkdir_bad
    call term_print
    ret

; ---------------------------------------------------------------------------
;  rmdir <目录>:删空目录
; ---------------------------------------------------------------------------
cmd_rmdir:
    cmp byte [fat_ok], 0
    je cmd_ls.nomount
    mov esi, [cmd_arg]
    call strip_name
    mov esi, [cmd_arg]
    cmp byte [esi], 0
    je .usage
    call fat_path
    jc .fail
    cmp byte [eax], 0
    je .fail
    mov esi, eax
    call fat_rmdir
    test eax, eax
    jz .ok
    cmp eax, -2
    je .notempty
.fail:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_rmdir_bad
    call term_print
    ret
.notempty:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_rmdir_notempty
    call term_print
    ret
.ok:
    mov al, COL_OK
    call term_set_color
    mov esi, msg_rmdir_ok
    call term_print
    mov esi, [cmd_arg]
    call term_print
    mov al, 10
    call term_putc
    ret
.usage:
    mov esi, msg_rmdir_use
    call term_print
    ret

cmd_ls:
    cmp byte [fat_ok], 0
    je .nomount
    mov esi, [cmd_arg]
    call strip_name
    mov esi, [cmd_arg]
    cmp byte [esi], 0
    je .list                            ; 没参数:列当前目录
    call fat_path                       ; 前面的目录先进去,剩最后一截
    jc .nofound
    cmp byte [eax], 0
    je .list                            ; 路径以 / 收尾,已经站在里面了
    mov esi, eax
    call fat_chdir                      ; 最后一截也当目录进
    jc .nofound
.list:
    call fat_list
    ret
.nofound:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_no_dir
    call term_print
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
    call fat_path
    jc .notfound
    mov esi, eax                        ; 剩下的那截才是文件名
    mov [cat_name_ptr], eax             ; 读的时候也要用这一截,别又拿整条路径
    call fat_stat                       ; 先看大小:缓冲区只到 PROG_ARG_ADDR 为止
    cmp eax, -1
    je .notfound
    cmp eax, FILE_MAX
    ja .toobig
    mov esi, [cat_name_ptr]
    mov edi, FILE_BUF
    call fat_read_file
    cmp eax, -1
    je .notfound
    mov [file_size], eax
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
    cmp ecx, 60                         ; 8.3 是 12 个字符,但带上目录就长了(PP_MAX=64)(含点)
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
;  run <文件>:把程序读进 PROG_ADDR(暂存区)→ 建一套空的程序地址空间 →
;             切 CR3 跑 → 跑完把页全还给页池
;  名字不带点就自动补 .BIN(所以 run HELLO 和 run HELLO.BIN 一样)
;
;  ★ 现在程序是**按需分页**:文件读进 0x120000 之后就留在那儿当"页面来源",
;    程序第一次碰某一页时才从页池拿页、把那一页的内容从暂存区拷过去。
;    HELLO.BIN 这种小程序实际只拿走 1 页镜像,不再一上来就占 208 页(见 paging.asm)。
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
    ; ---- 一次只让一条 shell 跑程序:space_* 那套地址空间状态还是全局的 ----
    mov eax, [prog_owner]
    cmp eax, -1
    je .owner_ok
    cmp eax, [sched_cur]
    je .owner_ok
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_run_busy
    call term_print
    mov eax, [prog_owner]
    call term_print_dec
    mov esi, msg_run_busy2
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    ret
.owner_ok:
    mov eax, [sched_cur]
    mov [prog_owner], eax
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
    cmp ecx, 60                         ; 8.3 是 12 个字符,但带上目录就长了(PP_MAX=64)
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
    mov esi, name_buf
    call fat_path                       ; 支持 run DOCS/PROG.BIN
    jc .notfound
    mov [prog_name_ptr], eax            ; 前面的目录已经进去了,这截才是文件名
    mov esi, eax
    call fat_stat
    cmp eax, -1
    je .notfound
    mov [prog_size], eax
    cmp eax, SPACE_IMG_PAGES * 4096     ; 镜像窗口只有 512 KiB(128 页)
    ja .toobig
    mov esi, [prog_name_ptr]
    mov edi, PROG_ADDR
    call fat_read_file                  ; 读进暂存区 —— 它就留在这儿当"页面来源"
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

    ; ---- 建一套空地址空间:页目录 + 页表两页,窗口里的页一页都不给 ----
    ; 文件也不往私有页里拷了:程序第一次碰到哪一页,页错误处理才从暂存区
    ; 把那一页拷过去(见 paging.asm 的 page_fault_try_handle)。
    ; ★ 顺序:先 create(建页表、重置这趟的计数),再 set_image 把镜像大小写进去。
    ;   space_create 特意**不碰** space_img_bytes —— 早期版本在 create 里顺手清它,
    ;   结果大小被清成 0,整个镜像窗口都算成 `.bss`(零页),程序跑的是 0 字节,
    ;   一路乱跳到野地址崩溃(见 README 6.10)。这个坑踩过。
    call space_create
    test eax, eax
    jz .nomem
    mov eax, [prog_size]
    call space_set_image                ; 告诉分页层镜像多大(决定 `.bss` 从哪页开始)
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_space_head
    call term_print
    mov eax, [space_pd]
    call term_print_hex
    mov esi, msg_space_tail
    call term_print
    mov al, COL_NORMAL
    call term_set_color

    ; ---- 切到程序自己的页目录,跳进去跑;它 ret 回来后再切回内核的 ----
    ; (按需分页的开关和 CR3 是在 space_activate / space_deactivate 里成对切的)
    pushad
    call space_activate                 ; ★ 从这里开始,0x120000 是"空的"
    call PROG_ADDR                      ; ← 程序在这里跑,它 ret 就回来
    call space_deactivate
    popad

    mov al, 10
    call term_putc
    ; ---- 收摊:按需给出去的页 + 私有页表 + 页目录,全还给页池 ----
    call space_destroy
    mov [space_freed], eax
    mov al, COL_OK
    call term_set_color
    mov esi, msg_prog_done
    call term_print
    mov esi, msg_space_gone
    call term_print
    mov eax, [space_freed]
    call term_print_dec
    mov esi, msg_space_back
    call term_print
    mov al, 10
    call term_putc

    ; ---- 按需分页的账:这一趟只补了程序真正碰过的页 ----
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_demand
    call term_print
    mov eax, [space_pf_run]
    call term_print_dec
    mov esi, msg_demand_split
    call term_print
    mov eax, [space_pf_img]
    call term_print_dec
    mov esi, msg_demand_and
    call term_print
    mov eax, [space_pf_heap]
    call term_print_dec
    mov esi, msg_demand_first
    call term_print
    mov eax, [space_first_pa]
    call term_print_hex
    mov al, 10
    call term_putc
    mov al, COL_NORMAL
    call term_set_color
    mov dword [prog_owner], -1          ; 程序跑完了:别的 shell 也能跑了
    ret
.nomem:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_space_nomem
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
    ; 内核区大小/起始 LBA 都从 BOOTINFO 来(boot_sectors/boot_lba 是 kmain 抄的)——
    ; 这里以前写死 "+32 KiB (64 sectors)",KERNEL_SECTS 改成 256 以后就一直显示错数字。
    mov esi, msg_info_kernel_plus
    call term_print
    mov eax, [boot_sectors]
    shr eax, 1                          ; 扇区 × 512 B ÷ 1024 = KiB
    call term_print_dec
    mov esi, msg_info_kernel_kib
    call term_print
    mov eax, [boot_sectors]
    call term_print_dec
    mov esi, msg_info_kernel_sect
    call term_print
    mov eax, [boot_lba]
    call term_print_dec
    mov esi, msg_info_kernel_end
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

; ---------------------------------------------------------------------------
;  pmem:看一眼物理页池(位图分配器,细节在 kernel/pmem.asm)
; ---------------------------------------------------------------------------
cmd_pmem:
    mov esi, msg_pmem_head
    call term_print
    mov esi, msg_pmem_pool
    call term_print
    mov eax, PMEM_START
    call term_print_hex
    mov esi, msg_pmem_dash
    call term_print
    mov eax, PMEM_END
    call term_print_hex
    mov esi, msg_pmem_lparen
    call term_print
    mov eax, PMEM_MIB
    call term_print_dec
    mov esi, msg_pmem_mib
    call term_print

    mov esi, msg_pmem_total
    call term_print
    mov eax, PMEM_TOTAL
    call term_print_dec
    mov esi, msg_pmem_pages
    call term_print

    mov esi, msg_pmem_used
    call term_print
    mov eax, [pmem_alloced]
    call term_print_dec
    mov esi, msg_pmem_free_lbl
    call term_print
    mov eax, [pmem_free_count]
    call term_print_dec
    mov esi, msg_pmem_pages_end
    call term_print

    mov esi, msg_pmem_hi
    call term_print
    mov eax, [pmem_hi]
    call term_print_hex
    mov esi, msg_pmem_bitmap
    call term_print
    mov eax, PMEM_BITMAP
    call term_print_hex
    mov al, 10
    call term_putc
    ret

; ---------------------------------------------------------------------------
;  pmap <va>:从页池拿一页映到虚拟地址 va —— 页表不存在就现建一张(动态建表)
; ---------------------------------------------------------------------------
cmd_pmap:
    mov esi, [cmd_arg]
    call parse_hex
    jnc .ok
    mov esi, msg_pmap_usage
    jmp .err
.ok:
    test eax, 0xFFF                     ; 得 4 KiB 对齐
    jnz .bad
    mov [pmap_va], eax
    call pmem_alloc
    test eax, eax
    jz .bad                              ; 页池空了
    mov [pmap_pa], eax
    mov ebx, eax
    mov eax, [pmap_va]
    mov ecx, PAGE_P | PAGE_RW
    call paging_map
    jc .bad
    mov esi, msg_pmap_head
    call term_print
    mov eax, [pmap_va]
    call term_print_hex
    mov esi, msg_pmap_arrow
    call term_print
    mov eax, [pmap_pa]
    call term_print_hex
    mov esi, msg_pmap_ok
    call term_print
    ret
.bad:
    mov esi, msg_pmap_bad
.err:
    mov al, COL_ERR
    call term_set_color
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    ret

; ---------------------------------------------------------------------------
;  pumap <va>:解掉映射,把那页还回页池(对 pmap 用)
; ---------------------------------------------------------------------------
cmd_pumap:
    mov esi, [cmd_arg]
    call parse_hex
    jnc .ok
    mov esi, msg_pumap_usage
    jmp .err
.ok:
    call paging_unmap                   ; eax = 原来映到的物理地址(0 = 没映)
    test eax, eax
    jz .none
    mov [pmap_pa], eax
    call pmem_free                      ; 还给页池(不是池里的会被拒,无所谓)
    mov esi, msg_pumap_head
    call term_print
    mov eax, [pmap_pa]
    call term_print_hex
    mov esi, msg_pumap_done
    call term_print
    ret
.none:
    mov esi, msg_pumap_none
.err:
    mov al, COL_ERR
    call term_set_color
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    ret

; ---------------------------------------------------------------------------
;  ptest:动态建表 + 页池的自动测试(跑完自己收拾干净,不留泄漏)
;    1. 记下页池空闲页数
;    2. 分配两页,映到 16 MiB 处 —— 那里本来连页表都没有,必须现建
;    3. 通过**虚拟地址**写,通过**物理地址**读:是同一个页才读得到
;    4. 解映射 + 归还,空闲页数必须回到开头(顺带验证页表被回收)
; ---------------------------------------------------------------------------
PTEST_VA    equ 0x01000000             ; 16 MiB:恒等映射之外,页目录第 4 项本来是空的
PTEST_MAGIC  equ 0x5A5A1234            ; 写进去的标记值
PTEST_MAGIC2 equ 0xC3C3ABCD

cmd_ptest:
    mov esi, msg_ptest_head
    call term_print
    mov eax, [pmem_free_count]
    mov [ptest_free0], eax
    mov esi, msg_ptest_free0
    call term_print
    call term_print_dec
    mov al, 10
    call term_putc

    ; ---- 1) 从页池拿两页 ----
    call pmem_alloc
    test eax, eax
    jz .fail_alloc
    mov [ptest_pa0], eax
    call pmem_alloc
    test eax, eax
    jz .fail_alloc
    mov [ptest_pa1], eax
    mov esi, msg_ptest_alloc
    call term_print
    mov eax, [ptest_pa0]
    call term_print_hex
    mov al, ' '
    call term_putc
    mov eax, [ptest_pa1]
    call term_print_hex
    mov al, 10
    call term_putc

    ; ---- 2) 映射到虚拟 16 MiB(页表要现建)----
    mov eax, PTEST_VA
    mov ebx, [ptest_pa0]
    mov ecx, PAGE_P | PAGE_RW
    call paging_map
    jc .fail_map
    mov eax, PTEST_VA + 4096
    mov ebx, [ptest_pa1]
    mov ecx, PAGE_P | PAGE_RW
    call paging_map
    jc .fail_map
    mov esi, msg_ptest_map
    call term_print

    ; ---- 3) 虚拟地址写 → 物理地址读 ----
    mov eax, PTEST_VA
    mov ebx, PTEST_MAGIC
    mov [eax], ebx
    mov eax, [ptest_pa0]
    mov eax, [eax]
    cmp eax, PTEST_MAGIC
    jne .fail_rw
    mov eax, PTEST_VA + 4096
    mov ebx, PTEST_MAGIC2
    mov [eax], ebx
    mov eax, [ptest_pa1]
    mov eax, [eax]
    cmp eax, PTEST_MAGIC2
    jne .fail_rw
    mov esi, msg_ptest_rw
    call term_print

    ; ---- 4) translate 对得上,而且虚拟 != 物理 ----
    mov eax, PTEST_VA
    call paging_translate
    cmp eax, [ptest_pa0]
    jne .fail_tr
    mov esi, msg_ptest_xlate
    call term_print
    mov eax, PTEST_VA
    call term_print_hex
    mov esi, msg_ptest_arrow
    call term_print
    mov eax, [ptest_pa0]
    call term_print_hex
    mov esi, msg_ptest_ne
    call term_print

    ; ---- 5) 收拾干净 ----
    mov eax, PTEST_VA
    call paging_unmap
    call pmem_free                       ; unmap 返回的旧物理地址就在 eax 里
    mov eax, PTEST_VA + 4096
    call paging_unmap
    call pmem_free
    mov esi, msg_ptest_free1
    call term_print
    mov eax, [pmem_free_count]
    call term_print_dec
    mov esi, msg_ptest_slash
    call term_print
    mov eax, [ptest_free0]
    call term_print_dec
    mov esi, msg_ptest_pages
    call term_print
    mov eax, [pmem_free_count]
    cmp eax, [ptest_free0]
    jne .fail_leak
    mov eax, PTEST_VA                    ; 解映射之后不该再能翻译出来
    call paging_translate
    test eax, eax
    jnz .fail_leak

    mov al, COL_OK
    call term_set_color
    mov esi, msg_ptest_pass
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    ret

.fail_alloc:
    mov esi, msg_ptest_fail_alloc
    jmp .err
.fail_map:
    mov esi, msg_ptest_fail_map
    jmp .err
.fail_rw:
    mov esi, msg_ptest_fail_rw
    jmp .err
.fail_tr:
    mov esi, msg_ptest_fail_tr
    jmp .err
.fail_leak:
    mov esi, msg_ptest_fail_leak
.err:
    push esi
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_ptest_fail_pre
    call term_print
    pop esi
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
    mov eax, [0x02000000]                 ; 32 MiB:恒等映射(16 MiB)之外,页目录里没这一项
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
;  cmd_uptime:开机以来过了多久 —— 数的是 PIT 的心跳(tick),不是墙钟
; ---------------------------------------------------------------------------
cmd_uptime:
    call pit_get_ticks                    ; eax = tick 数
    mov ebx, eax                          ; 留着待会儿还要再打一遍
    xor edx, edx
    mov ecx, TICK_HZ
    div ecx                               ; eax = 秒,edx = 不到一秒的零头
    mov esi, msg_uptime_1
    call term_print
    call term_print_dec                   ; 秒数
    mov esi, msg_uptime_2
    call term_print
    mov eax, ebx
    call term_print_dec                   ; tick 数(100 Hz:一秒一百个)
    mov esi, msg_uptime_3
    call term_print
    ret

; ---------------------------------------------------------------------------
;  cmd_date:读 CMOS 时钟 —— 日期 / 时间 / 星期
;  和 uptime 不是一回事:uptime 数的是"开机后过了多久",date 读的是"现在几点"
;     date          完整:YYYY-MM-DD HH:MM:SS 星期X + 一行当前模式
;     date ymd      2026-10-07
;     date mdy      10/07/2026(月/日/年)
;     date dmy      07/10/2026(日/月/年)
;     date time     11:00:24
; ---------------------------------------------------------------------------
cmd_date:
    call rtc_get
    mov esi, [cmd_arg]
    call strip_name                       ; 参数去尾空格(顺手把换行干掉)
    mov esi, [cmd_arg]
    cmp byte [esi], 0
    je .full                              ; 裸 date:老样子

    ; 量一下这个词多长,喂给 str_eq
    mov edi, esi
    xor ecx, ecx
.len:
    cmp byte [edi], 0
    je .len_done
    inc edi
    inc ecx
    jmp .len
.len_done:
    mov edx, n_fmt_ymd
    call str_eq
    test eax, eax
    jnz .ymd
    mov esi, [cmd_arg]
    mov edx, n_fmt_mdy
    call str_eq
    test eax, eax
    jnz .mdy
    mov esi, [cmd_arg]
    mov edx, n_fmt_dmy
    call str_eq
    test eax, eax
    jnz .dmy
    mov esi, [cmd_arg]
    mov edx, n_fmt_time
    call str_eq
    test eax, eax
    jnz .time
    jmp .usage

.ymd:
    call rtc_print_ymd
    jmp .newline
.mdy:
    call rtc_print_mdy
    jmp .newline
.dmy:
    call rtc_print_dmy
    jmp .newline
.time:
    call rtc_print_hms
.newline:
    mov al, 10
    call term_putc
    ret

.full:
    call rtc_print_time
    call rtc_print_state
    ret

.usage:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_date_usage
    call term_print
    mov esi, [cmd_arg]
    call term_print
    mov esi, msg_date_usage_end
    call term_print
    mov al, 10
    call term_putc
    mov al, COL_NORMAL
    call term_set_color
    ret

; ---------------------------------------------------------------------------
;  cmd_sleep:睡 <秒> —— 等 PIT 的 tick,期间 hlt,不烧 CPU
;  上限 3600 秒:玩具归玩具,别让人一条命令把机器睡死过去
; ---------------------------------------------------------------------------
cmd_sleep:
    call parse_dec
    jc .usage
    cmp eax, 3600
    ja .too_long
    mov ecx, TICK_HZ
    mul ecx                               ; eax = 要等几个 tick
    mov [sleep_want], eax
    call pit_get_ticks
    mov [sleep_from], eax
    mov ecx, [sleep_want]
    call pit_wait_ticks
    call pit_get_ticks
    sub eax, [sleep_from]                 ; 实际等了几个 tick
    mov ebx, eax
    mov esi, msg_sleep_done
    call term_print
    mov eax, [sleep_want]
    xor edx, edx
    mov ecx, TICK_HZ
    div ecx                               ; 要的秒数
    call term_print_dec
    mov esi, msg_sleep_mid
    call term_print
    mov eax, ebx
    call term_print_dec                   ; 实际 tick 数(通常会多 0~1 个:hlt 的边界)
    mov esi, msg_sleep_tail
    call term_print
    ret
.usage:
    mov esi, msg_sleep_usage
    call term_print
    ret
.too_long:
    mov esi, msg_sleep_long
    call term_print
    ret

; ---------------------------------------------------------------------------
;  cmd_ps:列出所有线程(0 号是 shell 自己)
;  数字直接读调度器的 TCB:ticks = 它一共拿到过几个 tick,runs = 被调度上去过
;  几次 —— 两个都在涨,就说明这个线程真的在跑(不只是"存在")。
;  循环下标放在内存里:term_print / term_print_dec 会碰寄存器,不能指望 edi 活下来。
; ---------------------------------------------------------------------------
cmd_ps:
    pushad
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_ps_head
    call term_print
    mov eax, [sched_live]
    call term_print_dec
    mov esi, msg_ps_head2
    call term_print
    mov eax, SCHED_MAX
    call term_print_dec
    mov esi, msg_ps_head3
    call term_print
    mov eax, [sched_ticks]
    call term_print_dec
    mov esi, msg_ps_head4
    call term_print
    mov al, COL_NORMAL
    call term_set_color

    mov dword [ps_i], 0
.next:
    mov eax, [ps_i]
    cmp eax, SCHED_MAX
    jae .done
    shl eax, 5
    add eax, tcb_table
    cmp dword [eax + TCB_STATE], ST_EMPTY
    je .skip

    mov esi, msg_ps_id
    call term_print
    mov eax, [ps_i]
    call term_print_dec
    mov esi, msg_ps_name
    call term_print
    mov eax, [ps_i]
    shl eax, 5
    add eax, tcb_table
    mov esi, [eax + TCB_NAME]
    call term_print
    mov esi, msg_ps_ticks
    call term_print
    mov eax, [ps_i]
    shl eax, 5
    add eax, tcb_table
    mov eax, [eax + TCB_TICKS]
    call term_print_dec
    mov esi, msg_ps_runs
    call term_print
    mov eax, [ps_i]
    shl eax, 5
    add eax, tcb_table
    mov eax, [eax + TCB_RUNS]
    call term_print_dec
    mov al, 10
    call term_putc
.skip:
    inc dword [ps_i]
    jmp .next
.done:
    popad
    ret

; ---------------------------------------------------------------------------
;  cmd_spawn:起一个演示线程 —— spawn / spawn alpha / spawn beta
;  不带参数时 alpha、beta 轮流起,这样两条命令就能看到"两个东西同时在跑"。
; ---------------------------------------------------------------------------
cmd_spawn:
    pushad
    mov esi, [cmd_arg]
    cmp byte [esi], 0
    je .default
    mov edi, esi                          ; 参数词开头
    xor ecx, ecx
.len:
    cmp byte [esi], 0
    je .len_done
    cmp byte [esi], ' '
    je .len_done
    inc esi
    inc ecx
    jmp .len
.len_done:
    test ecx, ecx
    jz .default                           ; 只有空格也当没参数
    mov esi, edi
    mov edx, n_alpha
    call str_eq
    test eax, eax
    jnz .alpha
    mov esi, edi
    mov edx, n_beta
    call str_eq
    test eax, eax
    jnz .beta
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_spawn_usage
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    popad
    ret
.default:
    cmp dword [sched_next_demo], 0
    jne .beta
.alpha:
    mov eax, thread_alpha
    mov ebx, n_alpha
    mov dword [sched_next_demo], 1
    jmp .do
.beta:
    mov eax, thread_beta
    mov ebx, n_beta
    mov dword [sched_next_demo], 0
.do:
    call sched_spawn
    jc .full
    mov [spawn_id], eax
    mov al, COL_OK
    call term_set_color
    mov esi, msg_spawn_ok
    call term_print
    mov eax, [spawn_id]
    call term_print_dec
    mov esi, msg_spawn_lp
    call term_print
    mov eax, [spawn_id]
    call sched_name
    call term_print
    mov esi, msg_spawn_rp
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    popad
    ret
.full:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_spawn_full
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    popad
    ret

; ---------------------------------------------------------------------------
;  cmd_kill:kill <线程号> —— 杀掉一个线程,它的栈还给物理页池
;  0 号杀不掉:那就是 shell 自己,它还在那条栈上走路。
; ---------------------------------------------------------------------------
cmd_kill:
    pushad
    call parse_dec
    jc .usage
    mov [kill_id], eax
    test eax, eax
    jz .self
    ; shell 线程(0..SH_MAX-1)不能杀:键盘就挂在它们身上,杀了没人接手
    cmp eax, SH_MAX
    jb .is_shell
    cmp eax, SCHED_MAX
    jae .none
    mov ebx, eax
    shl ebx, 5
    add ebx, tcb_table
    cmp dword [ebx + TCB_STATE], ST_ALIVE
    jne .none

    mov eax, [kill_id]
    call sched_name
    mov [kill_name], esi                  ; 名字先记下来(杀完槽就空了)
    mov eax, [kill_id]
    call sched_kill
    jc .none
    ; 它要是正在跑程序,把"一次一个"的锁放掉(那套地址空间就漏了,见 known-issues)
    mov eax, [kill_id]
    cmp eax, [prog_owner]
    jne .not_owner
    mov dword [prog_owner], -1
.not_owner:
    mov al, COL_OK
    call term_set_color
    mov esi, msg_kill_ok
    call term_print
    mov eax, [kill_id]
    call term_print_dec
    mov esi, msg_kill_lp
    call term_print
    mov esi, [kill_name]
    call term_print
    mov esi, msg_kill_rp
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    popad
    ret
.self:
    mov esi, msg_kill_self
    jmp .err
.is_shell:
    mov esi, msg_kill_shell
    jmp .err
.none:
    mov esi, msg_kill_none
.err:
    mov al, COL_ERR
    call term_set_color
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    popad
    ret
.usage:
    mov esi, msg_kill_usage
    jmp .err

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
;  parse_dec:把 [cmd_arg] 当十进制数解析,返 eax + CF(CF=1 = 不是个合法的数)
;  和 parse_hex 是一对:只认无符号十进制,溢出就报错(不悄悄回绕)
; ---------------------------------------------------------------------------
parse_dec:
    push esi
    push ebx
    push ecx
    mov esi, [cmd_arg]
    xor eax, eax
    xor ecx, ecx                          ; 数字位数
.next:
    mov bl, [esi]
    test bl, bl
    jz .end
    cmp bl, ' '
    je .end
    cmp bl, '0'
    jb .bad
    cmp bl, '9'
    ja .bad
    ; ⚠ 别把刚取到的数字存在 bl 里然后 mov ebx, 10 —— 那样数字会被冲掉
    ;   (踩过:sleep 2 睡成了 10 秒)。先乘 10,再回读字符取数字。
    mov ebx, 10
    mul ebx                               ; eax = eax×10,高位落在 edx
    test edx, edx
    jnz .bad                              ; 乘 10 就溢出了 → 这个数根本放不下
    movzx ebx, byte [esi]
    sub ebx, '0'
    add eax, ebx
    inc ecx
    cmp ecx, 10
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
n_debug  db 'debug', 0
n_ls     db 'ls', 0
n_cat    db 'cat', 0
n_write  db 'write', 0
n_run    db 'run', 0
n_clear  db 'clear', 0
n_info   db 'info', 0
n_page   db 'page', 0
n_cd     db 'cd', 0
n_mkdir  db 'mkdir', 0
n_rmdir  db 'rmdir', 0
n_fault  db 'fault', 0
n_reboot db 'reboot', 0
n_pmem   db 'pmem', 0
n_pmap   db 'pmap', 0
n_pumap  db 'pumap', 0
n_ptest  db 'ptest', 0
n_uptime db 'uptime', 0
n_sleep  db 'sleep', 0
n_date   db 'date', 0
n_shell  db 'shell', 0
n_ps     db 'ps', 0
n_spawn  db 'spawn', 0
n_kill   db 'kill', 0
n_fmt_ymd  db 'ymd', 0
n_fmt_mdy  db 'mdy', 0
n_fmt_dmy  db 'dmy', 0
n_fmt_time db 'time', 0
msg_date_usage db 'date: unknown format, try ymd / mdy / dmy / time (got: ', 0
msg_date_usage_end db ')', 0

cmd_table:
    dd n_help,   cmd_help
    dd n_echo,   cmd_echo
    dd n_ls,     cmd_ls
    dd n_cd,     cmd_cd
    dd n_mkdir,  cmd_mkdir
    dd n_rmdir,  cmd_rmdir
    dd n_cat,    cmd_cat
    dd n_write,  cmd_write
    dd n_run,    cmd_run
    dd n_clear,  cmd_clear
    dd n_info,   cmd_info
    dd n_debug,  cmd_debug
    dd n_reboot, cmd_reboot
    dd n_uptime, cmd_uptime
    dd n_sleep,  cmd_sleep
    dd n_date,   cmd_date
    dd n_shell,  cmd_shell
    dd n_ps,     cmd_ps
    dd n_spawn,  cmd_spawn
    dd n_kill,   cmd_kill
    dd 0, 0

; ---------------------------------------------------------------------------
;  数据
; ---------------------------------------------------------------------------
msg_shell_hello db 'type "help" for commands.', 10, 0
msg_prompt      db '> ', 0
cwd_str         times 64 db 0          ; 当前目录(cd 用,空 = 根)
saved_dir       dd 0                   ; 命令借用目录时的"还回去"的值
dbg_arg         dd 0                   ; debug 子命令后面那截参数的指针
ps_i            dd 0                   ; ps 的循环下标(调用会碰寄存器,只能放内存)
spawn_id        dd 0                   ; 刚起的线程号
kill_id         dd 0                   ; 要杀的线程号
kill_name       dd 0                   ; 杀之前先记下的名字
msg_mkdir_ok    db 'created directory ', 0
msg_mkdir_bad   db 'mkdir failed (already exists or disk full)', 10, 0
msg_mkdir_use   db 'usage: mkdir <dir>', 10, 0
msg_rmdir_ok    db 'removed directory ', 0
msg_rmdir_bad   db 'rmdir failed (not found or not a directory)', 10, 0
msg_rmdir_notempty db 'rmdir failed (directory not empty)', 10, 0
msg_rmdir_use   db 'usage: rmdir <dir>', 10, 0
msg_shell_unknown db 'unknown command: ', 0
msg_fault       db 'touching an unmapped address on purpose...', 10, 0
msg_reboot      db 'rebooting...', 10, 0
msg_reboot_fail db '8042 did not reset, trying triple fault...', 10, 0

msg_uptime_1    db 'up ', 0
msg_uptime_2    db ' s (', 0
msg_uptime_3    db ' ticks at 100 Hz)', 10, 0
msg_sleep_done  db 'slept ', 0
msg_sleep_mid   db ' s (', 0
msg_sleep_tail  db ' ticks)', 10, 0
msg_sleep_usage db 'usage: sleep <seconds>, e.g. sleep 2 (max 3600)', 10, 0
msg_sleep_long  db 'sleep: too long (max 3600 seconds)', 10, 0

msg_debug_usage db 'usage: debug <what>  (what = page / pmem / pmap / pumap / ptest / fault)', 10, 0
msg_sh_switch   db '--- shell ', 0
msg_sh_switch2  db ' ---', 10, 0
msg_shell_list  db 'shells: ', 0
msg_shell_list2 db ' (you are in shell ', 0
msg_shell_list3 db ')', 10, 0
msg_shell_row   db '  [', 0
msg_shell_row2  db '] ', 0
msg_shell_active db '   <- keyboard here', 0
msg_shell_hint  db 'Ctrl+Left / Ctrl+Right switches, or: shell <n>', 10, 0
msg_shell_same  db 'already here', 10, 0
msg_shell_usage db 'usage: shell [1-4]  (no argument = list them)', 10, 0
msg_run_busy    db 'another shell is running a program (thread ', 0
msg_run_busy2   db ') - Ctrl+Left/Right to switch there, or kill it', 10, 0
msg_kill_shell  db 'shell threads cannot be killed: the keyboard lives on them', 10, 0
msg_ps_head    db 'ps: ', 0
msg_ps_head2   db ' alive / ', 0
msg_ps_head3   db ' slots, scheduled ticks ', 0
msg_ps_head4   db 10, 0
msg_ps_id      db '  [', 0
msg_ps_name    db '] ', 0
msg_ps_ticks   db '  ticks=', 0
msg_ps_runs    db '  runs=', 0
msg_spawn_ok   db 'spawned thread ', 0
msg_spawn_lp   db ' (', 0
msg_spawn_rp   db ')', 10, 0
msg_spawn_full db 'spawn: no free thread slot / out of physical pages', 10, 0
msg_spawn_usage db 'usage: spawn [alpha|beta]  (no arg = alpha, then beta)', 10, 0
msg_kill_ok    db 'killed thread ', 0
msg_kill_lp    db ' (', 0
msg_kill_rp    db ')', 10, 0
msg_kill_self  db 'kill: thread 0 is the shell itself, cannot kill that', 10, 0
msg_kill_none  db 'kill: no such thread', 10, 0
msg_kill_usage db 'usage: kill <id>  (get ids from ps)', 10, 0

msg_help db \
    'help          show this list', 10, \
    'echo <text>   print the text back', 10, \
    'clear         clear the screen', 10, \
    'info          CPU / paging / IDT info', 10, \
    'debug <what>  diagnostics: page / pmem / pmap / pumap / ptest / fault', 10, \
    'uptime        how long the PIT has been ticking', 10, \
    'sleep <sec>   sleep N seconds (hlt while waiting, max 3600)', 10, \
    'date [fmt]    read the CMOS clock: no arg = full, or ymd / mdy / dmy / time', 10, \
    'ps            list scheduler threads (id / name / ticks / runs)', 10, \
    'spawn [who]   start a demo kernel thread (no arg = alpha, then beta)', 10, \
    'kill <id>     kill a thread, give its stack back to the page pool', 10, \
    'shell [n]     list the 4 shells, or jump to one (Ctrl+Left / Ctrl+Right)', 10, \
    'reboot        restart the machine', 10, \
    'ls            list files on the FAT16 disk', 10, \
    'cat <file>    print a text file (UTF-8)', 10, \
    'write <f> <t> create/overwrite a file', 10, \
    'run <file>    run a program from disk (.BIN; bare "run" = the ABI)', 10, 0

msg_info_head    db '--- JoyOS info ---', 10, 0
msg_info_disk    db 'boot disk   : ', 0
msg_info_kernel  db 'kernel      : ', 0
msg_info_kernel_plus db ' .. +', 0
msg_info_kernel_kib  db ' KiB (', 0
msg_info_kernel_sect db ' sectors from LBA ', 0
msg_info_kernel_end  db ')', 10, 0
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
msg_info_page    db 'paging      : identity 0..16 MiB + VBE LFB high window', 10, \
                    '              page pool 0x00400000-0x00FFFFFF (debug pmem / debug ptest)', 10, \
                    '              CR0.PG = 1 (bit31), CR4.PSE = 0 (4 KiB pages)', 10, 0

msg_page_usage   db 'usage: debug page <hex address>, e.g. debug page 0x400000', 10, 0
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

; ---- pmem / pmap / pumap / ptest ----
msg_pmem_head    db '--- pmem: physical page pool ---', 10, 0
msg_pmem_pool    db 'pool        : ', 0
msg_pmem_dash    db ' - ', 0
msg_pmem_lparen  db '  (', 0
msg_pmem_mib     db ' MiB)', 10, 0
msg_pmem_total   db 'pages       : ', 0
msg_pmem_pages   db ' total (4 KiB each)', 10, 0
msg_pmem_used    db 'used        : ', 0
msg_pmem_free_lbl db '   free: ', 0
msg_pmem_pages_end db ' pages', 10, 0
msg_pmem_hi      db 'highest ever: ', 0
msg_pmem_bitmap  db '   bitmap @ ', 0

msg_pmap_usage   db 'usage: debug pmap <hex virtual address, 4 KiB aligned>, e.g. debug pmap 0x8000000', 10, 0
msg_pmap_head    db 'mapped ', 0
msg_pmap_arrow   db ' -> physical ', 0
msg_pmap_ok      db '  (page table created on demand; check with: debug page <va>)', 10, 0
msg_pmap_bad     db 'pmap failed (pool empty, or address not 4 KiB aligned)', 10, 0

msg_pumap_usage  db 'usage: debug pumap <hex virtual address>', 10, 0
msg_pumap_head   db 'unmapped, gave back ', 0
msg_pumap_done   db '  (page returned to the pool; empty page table recycled)', 10, 0
msg_pumap_none   db 'pumap: that address was not mapped', 10, 0

msg_ptest_head   db '--- ptest: dynamic page tables + page pool ---', 10, 0
msg_ptest_free0  db 'pool free before : ', 0
msg_ptest_alloc  db 'got two pages    : ', 0
msg_ptest_map    db 'mapped them at 0x1000000 (page table built on demand)', 10, 0
msg_ptest_rw     db 'write via virtual, read via physical: OK', 10, 0
msg_ptest_xlate  db 'translate ', 0
msg_ptest_arrow  db ' -> ', 0
msg_ptest_ne     db '   (virtual != physical)', 10, 0
msg_ptest_free1  db 'pool free after  : ', 0
msg_ptest_slash  db ' / ', 0
msg_ptest_pages  db ' pages', 10, 0
msg_ptest_pass   db 'ptest: all good (page table and both pages returned, no leak)', 10, 0
msg_ptest_fail_pre      db 'ptest FAILED: ', 0
msg_ptest_fail_alloc    db 'could not allocate pages from the pool', 10, 0
msg_ptest_fail_map      db 'paging_map failed', 10, 0
msg_ptest_fail_rw       db 'value written via virtual address not seen at the physical address', 10, 0
msg_ptest_fail_tr       db 'paging_translate does not match the allocated page', 10, 0
msg_ptest_fail_leak     db 'pool did not return to its starting count (leak) or unmap left it translatable', 10, 0

msg_no_fat      db 'no FAT16 filesystem (boot from the hard-disk image)', 10, 0
msg_no_file     db 'file not found', 10, 0
msg_no_dir      db 'not a directory', 10, 0
msg_wrote       db 'wrote ', 0
msg_write_usage db 'usage: write <name> <text>', 10, 0
msg_write_fail  db 'write failed (disk full?)', 10, 0
msg_running     db 'running ', 0
msg_prog_done   db 'program returned to the shell', 10, 0
msg_prog_toobig db 'program too big for the load area', 10, 0
msg_space_head  db 'address space: CR3 = ', 0
msg_space_tail  db '  (own page directory + demand paging)', 10, 0
msg_space_gone  db 'address space destroyed: ', 0
msg_space_back  db ' page(s) back to the pool', 0
msg_demand      db 'demand paging: ', 0
msg_demand_split db ' page(s) faulted in (image ', 0
msg_demand_and  db ' + heap ', 0
msg_demand_first db '), first page ', 0
msg_space_nomem db 'no free physical pages: cannot build an address space for the program', 10, 0
msg_file_toobig db 'file too big to print (over 60 KiB)', 10, 0

PROG_ADDR      equ 0x120000             ; 程序加载地址(progs/*.asm 里的 ORG 要和它一致)
PROG_MAX_SIZE  equ FONT_LOAD_ADDR - PROG_ADDR
                                        ; 0xE0000 = 896 KB:再往上就是磁盘字库(0x200000)了
FILE_BUF       equ 0x110000             ; cat 用的文件缓冲(1 MiB 往上,别压到字库)
FILE_MAX       equ PROG_ARG_ADDR - FILE_BUF
                                        ; 0xF000 = 60 KB:再往上就是程序参数块(0x11F000)

name_buf   times 64 db 0              ; 名字里可能带目录(DOCS/NOTE.TXT),留宽一点
prog_name_ptr dd 0                      ; run 用的:去掉目录部分之后的程序名
prog_size   dd 0                        ; run 用的:程序文件多大(按它往私有页里拷)
space_freed dd 0                        ; run 用的:收摊时还回去的页数
cat_name_ptr dd 0                       ; cat 用的:去掉目录部分之后的文件名
file_size  dd 0

; ---- 多 shell:每条自己的状态格子 + 两个全局 ----
;  全局的 shell_buf / shell_len / cwd_str 永远是"当前活动 shell 的",换手时由
;  shell_switch_to(键盘中断里)整份搬进 / 搬出下面这些格子。
sh_active      dd 0                     ; 键盘现在归哪条 shell(线程号)
sh_switch_flag dd 0                     ; 1 = 刚换过来,醒来要重画标题和半行
sh_target      dd 0                     ; shell_switch_to 的临时变量
prog_owner     dd -1                    ; 正在跑程序的线程号,-1 = 没人跑
sh_nbuf        times SH_MAX * SH_BUF_SZ db 0
sh_nlen        times SH_MAX dd 0
sh_ndir        times SH_MAX * SH_DIR_SZ db 0
nm_sh2         db 'shell2', 0
nm_sh3         db 'shell3', 0
nm_sh4         db 'shell4', 0
sh_names       dd nm_main, nm_sh2, nm_sh3, nm_sh4

shell_buf  times SHELL_LINE_MAX db 0
shell_len  dd 0
mb_len     dd 0                       ; 正在收的多字节 UTF-8 字符占几个字节
mb_got     dd 0                       ; 已经收进来几个字节
mb_first   db 0                       ; 这个字符的首字节
cmd_len    dd 0
cmd_arg    dd 0
sleep_want dd 0                          ; sleep 要等几个 tick
sleep_from dd 0                          ; sleep 开始时的 tick 数

page_va      dd 0
page_pde     dd 0
page_pde_idx dd 0
pmap_va      dd 0                      ; pmap / pumap 的虚拟地址
pmap_pa      dd 0                      ; 对应的物理页
ptest_pa0    dd 0                      ; ptest 临时用的两页
ptest_pa1    dd 0
ptest_free0  dd 0                      ; ptest 开始前的空闲页数(用来对比有没有泄漏)
page_pte_idx dd 0

idtr_buf   times 6 db 0
empty_idt  dw 0
           dd 0
