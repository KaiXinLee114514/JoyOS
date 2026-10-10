; ============================================================================
;  rc.asm:rc.conf 式的配置(RC.CONF)+ 内核事件账本
;
;  为什么有这个东西
;  ----------------
;  内核里现在有一堆"什么时候发生了什么事"的散点:程序跑完了、程序崩了、
;  线程被 kill 了、键盘换到另一条 shell 了……以前这些事只有当时那一行打印,
;  打完就没了 —— 你想回头问"刚才那个程序是怎么死的"就只能翻屏幕。
;
;  这里做两件小事:
;    · **事件账本**:内核里任何人调 evt_log(事件号, 参数),就把这件事
;      连时间(tick)一起记进一个 16 格的环。shell 里 `rc log` 能翻这本账。
;    · **配置**:磁盘根目录的 RC.CONF,rc.conf 风格(**纯 key=value**,一行一个),
;      能改主机名、开机提示、要不要开机自动起服务、程序崩了怎么办;
;      也能把磁盘上的程序登记成"服务",用 `rc start N` 跑起来。
;
;  为什么不用 systemd 那套:unit 文件 + 依赖图 + 并行启动是另一门语言,
;  这个玩具不需要。rc.conf 就是一行一个 key=value —— 用 shell 的 `write` 命令
;  就能改,改完 `rc reload` 立刻生效(不用重做镜像)。
;
;  RC.CONF 长这样(空行和 # 开头的行忽略,值可以带双引号):
;      # JoyOS 的配置
;      hostname="joyos"
;      boot_msg="hello from rc.conf"
;      autostart="NO"                ; YES = 开机把启用的服务跑一遍
;      on_crash="log"                ; log(默认)/ reboot
;      service_1="HELLO.BIN"         ; 服务 1 跑哪个程序
;      service_1_enable="YES"
;      service_1_args="hello"
;
;  服务就是"磁盘上的程序":跑的时候走的是 shell 里 `run` 那条一模一样的路
;  (私有地址空间 + ring 3 + 按需分页),所以服务崩了内核也照样没事。
; ============================================================================

; ★ RC.CONF 读进 rc_buf(内核自己的静态缓冲,见数据区)。
;   第一版把它放在固定地址 0x10C000,结果**压在 FAT_BUF(0x100000-0x10FFFF)里**:
;   fat_read_file 一边读扇区一边往 FAT_BUF 拷,目的地就在那里面,于是读回来是 0 字节
;   (症状:开机那次能读到 9 个 key,因为那时没人动过 FAT_BUF;`write` 之后再 reload 就 0 keys)。
RC_MAX      equ 4096
RC_KEYS     equ 32                  ; 最多认 32 个 key
RC_SVCS     equ 8                   ; service_1 .. service_8(一位数,好解析)
RC_EVENTS   equ 16                  ; 事件环格数(必须是 2 的幂,掩码取模)
RC_RUNBUF   equ 64                  ; '程序名 参数' 拼在这儿

; 事件号:每加一种事,记得在 evt_names 表里加一行名字
EV_BOOT       equ 0
EV_RCCONF     equ 1
EV_SVC_START  equ 2
EV_SVC_OK     equ 3
EV_SVC_FAIL   equ 4
EV_PROG_EXIT  equ 5
EV_PROG_CRASH equ 6
EV_KILL       equ 7
EV_SHELL      equ 8
EV_COUNT      equ 9                 ; 一共几种事(evt_names 表的长度)

; ============================================================================
;  evt_log:eax = 事件号,ebx = 附带的一个数(地址/线程号/服务号,随便)
;  记一笔就走,不改任何寄存器(所以中断里、崩溃路径里都能放心调)
; ============================================================================
evt_log:
    pushad
    mov ecx, [rc_evt_n]
    mov edx, ecx
    and edx, RC_EVENTS - 1          ; 环:新的一格盖掉最老的
    mov [rc_evt_id + edx * 4], eax
    mov [rc_evt_arg + edx * 4], ebx
    mov eax, [pit_ticks]
    mov [rc_evt_tick + edx * 4], eax
    inc ecx
    mov [rc_evt_n], ecx
    popad
    ret

; ============================================================================
;  rc_load:读 RC.CONF → 解析 → 打一行开机日志
;  文件不在也不报错:告诉用户"用内置默认值",然后照常开机
; ============================================================================
rc_load:
    pushad
    mov dword [rc_ok], 0
    mov dword [rc_keys], 0
    mov dword [rc_len], 0
    mov esi, rc_fname
    mov edi, rc_buf
    call fat_read_file
    cmp eax, -1
    je .no_file
    mov [rc_len], eax
    mov dword [rc_ok], 1
    call rc_parse
    jmp .report
.no_file:
    mov al, COL_NORMAL
    call term_set_color
    mov esi, msg_rc_nofile
    call term_print
.report:
    call rc_svc_scan                ; 数一数有几个服务、几个是启用的
    mov eax, EV_RCCONF
    xor ebx, ebx
    call evt_log
    call rc_print_boot
    popad
    ret

; ============================================================================
;  rc_parse:就地把 rc_buf 里的 'key=value' 拆开
;  就地改写(把 '=' 和行尾改成 0),所以解析完 key/value 都是普通 C 字符串,
;  后面 rc_get 直接拿指针比较就行 —— 不额外分配内存。
; ============================================================================
rc_parse:
    pushad
    mov esi, rc_buf
    mov edi, [rc_len]
    add edi, rc_buf                 ; 缓冲区结尾
.line:
    cmp esi, edi
    jae .done
.skip_lead:
    cmp esi, edi
    jae .done
    mov al, [esi]
    cmp al, ' '
    je .skip1
    cmp al, 9
    je .skip1
    cmp al, 13
    je .skip1
    jmp .check
.skip1:
    inc esi
    jmp .skip_lead
.check:
    cmp al, 10                      ; 空行
    je .next_line
    cmp al, '#'                     ; 注释
    je .to_eol
    mov [rc_kstart], esi            ; 这一行的 key 从这里开始
.find_eq:
    cmp esi, edi
    jae .done
    mov al, [esi]
    cmp al, 10
    je .to_eol
    cmp al, '='
    je .have_eq
    inc esi
    jmp .find_eq
.have_eq:
    mov byte [esi], 0               ; key 到此为止
    mov ebx, esi                    ; 回去削 key 尾巴上的空格
.trim_key:
    cmp ebx, [rc_kstart]
    jbe .key_done
    mov al, [ebx - 1]
    cmp al, ' '
    je .key_trim1
    cmp al, 9
    je .key_trim1
    jmp .key_done
.key_trim1:
    mov byte [ebx - 1], 0
    dec ebx
    jmp .trim_key
.key_done:
    inc esi                         ; 跳过 '='
.val_lead:
    cmp esi, edi
    jae .done
    mov al, [esi]
    cmp al, ' '
    je .val_lead1
    cmp al, 9
    je .val_lead1
    jmp .val_scan
.val_lead1:
    inc esi
    jmp .val_lead
.val_scan:
    mov [rc_vstart], esi
    mov ebx, esi                    ; ebx = 值结尾(不含 0)
.scan:
    cmp esi, edi
    jae .val_end_eob
    mov al, [esi]
    cmp al, 10
    je .val_end
    cmp al, 13
    je .val_end
    inc esi
    mov ebx, esi
    jmp .scan
.val_end_eob:
    ; 文件末尾没有换行:直接收尾
.val_end:
    mov byte [esi], 0               ; 先把行尾变成 0(下面的指针就不怕越界了)
    ; 削值尾巴的空格
.trim_val:
    cmp ebx, [rc_vstart]
    jbe .trim_val_done
    mov al, [ebx - 1]
    cmp al, ' '
    je .val_trim1
    cmp al, 9
    je .val_trim1
    jmp .trim_val_done
.val_trim1:
    mov byte [ebx - 1], 0
    dec ebx
    jmp .trim_val
.trim_val_done:
    ; 值收尾:引号值就找配对的收尾引号(后面的注释一起丢掉);
    ; 没引号的值遇到 " #" 就在那儿截断 —— 不然 `autostart="NO"  # 注释`
    ; 会把整行注释当成值的一部分(第一版就是这样,rc 概要里打出了一整行)。
    mov ebx, [rc_vstart]
    cmp byte [ebx], '"'
    jne .strip_comment
    lea eax, [ebx + 1]
.quote_scan:
    mov cl, [eax]
    test cl, cl
    jz .store                       ; 没有收尾引号:照原样留着(不猜)
    cmp cl, '"'
    je .unquote
    inc eax
    jmp .quote_scan
.unquote:
    mov byte [eax], 0               ; 收尾引号 → 0,后面的注释自然被丢掉
    inc ebx
    mov [rc_vstart], ebx
    jmp .store
.strip_comment:
    mov eax, ebx
.scan_comment:
    mov cl, [eax]
    test cl, cl
    jz .store
    cmp cl, ' '
    jne .sc_next
    cmp byte [eax + 1], '#'
    jne .sc_next
    mov byte [eax], 0
    jmp .store
.sc_next:
    inc eax
    jmp .scan_comment
.store:
    cmp byte [rc_kstart], 0         ; 空 key 不要
    je .next_line
    mov ecx, [rc_keys]
    cmp ecx, RC_KEYS                ; 表满了就忽略后面(不崩)
    jae .next_line
    mov eax, [rc_kstart]
    mov [rc_kptr + ecx * 4], eax
    mov eax, [rc_vstart]
    mov [rc_vptr + ecx * 4], eax
    inc dword [rc_keys]
.next_line:
    ; esi 现在指在 0 上(行尾标记),往后走到下一行
    cmp esi, edi
    jae .done
    mov al, [esi]
    test al, al
    jz .adv
    ; 理论上不会走到这儿,稳妥起见也往前挪
.adv:
    inc esi
    jmp .line
.to_eol:
    cmp esi, edi
    jae .done
    mov al, [esi]
    inc esi
    cmp al, 10
    jne .to_eol
    jmp .line
.done:
    popad
    ret

; ============================================================================
;  rc_get:esi = key(0 结尾)→ eax = 值指针,没这个 key 就 0
;  key 比较不分大小写(HOSTNAME 和 hostname 一样)—— 手写惯了 Shell 的人
;  不该被大小写坑第二次
; ============================================================================
rc_get:
    pushad
    mov ebx, esi
    xor ecx, ecx
.loop:
    cmp ecx, [rc_keys]
    jae .none
    push ecx
    mov esi, [rc_kptr + ecx * 4]
    mov edi, ebx
    call rc_streq_nocase
    pop ecx
    test eax, eax
    jnz .hit
    inc ecx
    jmp .loop
.hit:
    mov eax, [rc_vptr + ecx * 4]
    mov [esp + 28], eax             ; pushad 里 eax 在 [esp+28]
    jmp .done
.none:
    mov dword [esp + 28], 0
.done:
    popad
    ret

; ---------------------------------------------------------------------------
;  rc_streq_nocase:esi 和 edi 两个 0 结尾字符串比一比(大小写无关)→ eax = 1/0
; ---------------------------------------------------------------------------
rc_streq_nocase:
    push esi
    push edi
    push ebx                            ; ★ rc_get 拿 ebx 存 key 指针,这里必须保住它
                                        ;   (第一版没保,于是只有第 1 个 key 能查到,
                                        ;    表现成"hostname 有、autostart 没有")
.loop:
    mov al, [esi]
    mov bl, [edi]
    ; 小写化:只在 'A'..'Z' 上 +0x20
    cmp al, 'A'
    jb .al_done
    cmp al, 'Z'
    ja .al_done
    add al, 0x20
.al_done:
    cmp bl, 'A'
    jb .bl_done
    cmp bl, 'Z'
    ja .bl_done
    add bl, 0x20
.bl_done:
    cmp al, bl
    jne .no
    test al, al
    jz .yes
    inc esi
    inc edi
    jmp .loop
.no:
    xor eax, eax
    jmp .out
.yes:
    mov eax, 1
.out:
    pop ebx
    pop edi
    pop esi
    ret

; ============================================================================
;  rc_make_key:ecx = 服务号(1..RC_SVCS),edx = 后缀 → rc_keybuf 里拼出
;              'service_<N><后缀>'(比如 service_3_enable)
; ============================================================================
rc_make_key:
    pushad
    mov edi, rc_keybuf
    mov esi, rc_k_svc
.cp1:
    mov al, [esi]
    test al, al
    jz .digit
    mov [edi], al
    inc esi
    inc edi
    jmp .cp1
.digit:
    mov eax, ecx
    add eax, '0'
    mov [edi], al
    inc edi
.cp2:
    mov al, [edx]
    test al, al
    jz .end
    mov [edi], al
    inc edx
    inc edi
    jmp .cp2
.end:
    mov byte [edi], 0
    popad
    ret

; ---------------------------------------------------------------------------
;  rc_svc_prog:  ecx = N → eax = 程序名(service_N 的值),没有就是 0
;  rc_svc_args:  ecx = N → eax = 参数(service_N_args),没有就是 0
;  rc_svc_enable:ecx = N → eax = 1/0(YES / yes / 1 都算启用)
; ---------------------------------------------------------------------------
rc_svc_prog:
    pushad
    mov edx, rc_suf_none
    call rc_make_key
    mov esi, rc_keybuf
    call rc_get
    mov [esp + 28], eax
    popad
    ret

rc_svc_args:
    pushad
    mov edx, rc_suf_args
    call rc_make_key
    mov esi, rc_keybuf
    call rc_get
    mov [esp + 28], eax
    popad
    ret

rc_svc_enable:
    pushad
    mov edx, rc_suf_enable
    call rc_make_key
    mov esi, rc_keybuf
    call rc_get
    test eax, eax
    jz .no
    mov esi, eax
    mov al, [esi]
    cmp al, '1'
    je .yes
    or al, 0x20                     ; 'Y'/'y' 都行
    cmp al, 'y'
    je .yes
.no:
    mov dword [esp + 28], 0
    jmp .done
.yes:
    mov dword [esp + 28], 1
.done:
    popad
    ret

; ---------------------------------------------------------------------------
;  rc_svc_scan:数服务 —— rc_svc_n = 登记了几个,rc_svc_en = 其中启用了几个
; ---------------------------------------------------------------------------
rc_svc_scan:
    pushad
    mov dword [rc_svc_n], 0
    mov dword [rc_svc_en], 0
    mov ecx, 1
.loop:
    cmp ecx, RC_SVCS
    ja .done
    call rc_svc_prog
    test eax, eax
    jz .next
    inc dword [rc_svc_n]
    call rc_svc_enable
    test eax, eax
    jz .next
    inc dword [rc_svc_en]
.next:
    inc ecx
    jmp .loop
.done:
    popad
    ret

; ============================================================================
;  rc_print_boot:开机那一行(告诉用户配置读到了什么)
; ============================================================================
rc_print_boot:
    pushad
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_rc_head
    call term_print
    cmp dword [rc_ok], 0
    je .builtin
    mov esi, rc_fname
    call term_print
    mov esi, msg_rc_comma
    call term_print
    mov eax, [rc_keys]
    call term_print_dec
    mov esi, msg_rc_keys
    call term_print
    jmp .host
.builtin:
    mov esi, msg_rc_builtin
    call term_print
.host:
    mov esi, msg_rc_hostname
    call term_print
    mov esi, rc_k_hostname
    call rc_get
    test eax, eax
    jnz .have_host
    mov eax, rc_def_host
.have_host:
    mov esi, eax
    call term_print
    mov esi, msg_rc_svcs
    call term_print
    mov eax, [rc_svc_n]
    call term_print_dec
    mov esi, msg_rc_enabled
    call term_print
    mov eax, [rc_svc_en]
    call term_print_dec
    mov esi, msg_rc_rparen_nl
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    popad
    ret

; ---------------------------------------------------------------------------
;  rc_print_bootmsg:把配置里的 boot_msg 打出来(配置见效的肉眼证明)
; ---------------------------------------------------------------------------
rc_print_bootmsg:
    pushad
    mov esi, rc_k_bootmsg
    call rc_get
    test eax, eax
    jz .done
    mov al, COL_OK
    call term_set_color
    mov esi, msg_rc_bootmsg
    call term_print
    mov esi, [rc_vptr]              ; 占位(下面重新取,别用这个)
    mov esi, rc_k_bootmsg
    call rc_get
    mov esi, eax
    call term_print
    mov al, 10
    call term_putc
    mov al, COL_NORMAL
    call term_set_color
.done:
    popad
    ret

; ============================================================================
;  rc_dec:esi = 十进制字符串 → eax = 数,CF = 1 表示不是个数
; ============================================================================
rc_dec:
    push esi
    push ebx
    push ecx
    xor eax, eax
    xor ecx, ecx
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
    imul eax, eax, 10
    sub bl, '0'
    movzx ebx, bl
    add eax, ebx
    inc ecx
    inc esi
    cmp ecx, 9                      ; 别溢出(服务号就一位数,足够)
    ja .bad
    jmp .next
.end:
    test ecx, ecx
    jz .bad                         ; 空串不是数
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
;  rc_rest:esi → 跳过第一个词和它后面的空格 → eax = 剩下的开头(可能指向 0)
; ---------------------------------------------------------------------------
rc_rest:
    push esi
.skiptok:
    mov al, [esi]
    test al, al
    jz .out
    cmp al, ' '
    je .spaces
    inc esi
    jmp .skiptok
.spaces:
    mov al, [esi]
    cmp al, ' '
    jne .out
    inc esi
    jmp .spaces
.out:
    mov eax, esi
    pop esi
    ret

; ============================================================================
;  rc_run_service:ecx = 服务号 → 跑它的程序(和 shell 的 run 一条路)
;  返回值:eax = 1 跑了,0 = 没这个服务
; ============================================================================
rc_run_service:
    pushad
    mov [rc_run_num], ecx           ; ★ 服务号存内存:cmd_run 回来以后 ecx 早被冲了,
                                    ;   第一版拿它当 evt_log 的附带数,账本里出现 0x7F0 这种野值
    push ecx
    call rc_svc_prog
    pop ecx
    test eax, eax
    jz .none
    ; 事件:服务开始
    push eax
    mov ebx, [rc_run_num]           ; 附带服务号
    mov eax, EV_SVC_START
    call evt_log
    pop eax
    ; 拼 '程序名 参数' 到 rc_runbuf
    call rc_build_runbuf            ; ecx = N
    ; 借用 shell 的 run:把 [cmd_arg] 临时换成我们拼好的这行
    mov eax, [cmd_arg]
    mov [rc_saved_arg], eax
    mov dword [cmd_arg], rc_runbuf
    call cmd_run
    mov eax, [rc_saved_arg]
    mov [cmd_arg], eax
    ; 收尾事件:正常回来了 / 被杀
    mov eax, EV_SVC_OK
    cmp dword [run_status], 0
    je .log
    mov eax, EV_SVC_FAIL
.log:
    mov ebx, [rc_run_num]
    call evt_log
    mov dword [esp + 28], 1
    jmp .done
.none:
    mov dword [esp + 28], 0
.done:
    popad
    ret

; ---------------------------------------------------------------------------
;  rc_build_runbuf:ecx = N → rc_runbuf = '程序名' + ' ' + '参数'(没有参数就不加)
; ---------------------------------------------------------------------------
rc_build_runbuf:
    pushad
    mov edi, rc_runbuf
    push ecx
    call rc_svc_prog
    mov esi, eax
    mov [rc_run_prog], eax
    pop ecx
.cp:
    mov al, [esi]
    test al, al
    jz .args
    mov [edi], al
    inc esi
    inc edi
    jmp .cp
.args:
    push ecx
    call rc_svc_args
    pop ecx
    test eax, eax
    jz .end
    cmp byte [eax], 0
    je .end
    mov esi, eax
    mov al, ' '
    mov [edi], al
    inc edi
.cp2:
    mov al, [esi]
    test al, al
    jz .end
    mov [edi], al
    inc esi
    inc edi
    jmp .cp2
.end:
    mov byte [edi], 0
    popad
    ret

; ============================================================================
;  rc_autostart:配置里 autostart="YES" 时,开机把启用的服务按顺序跑一遍
;  (默认是 NO:开机会卡在服务里,玩具 OS 不适合)
; ============================================================================
rc_autostart:
    pushad
    mov esi, rc_k_autostart
    call rc_get
    test eax, eax
    jz .done
    mov esi, eax
    mov al, [esi]
    or al, 0x20
    cmp al, 'y'
    jne .done
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_rc_autostart
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    mov ecx, 1
.loop:
    cmp ecx, RC_SVCS
    ja .done
    push ecx
    call rc_svc_enable
    pop ecx
    test eax, eax
    jz .next
    call rc_run_service
.next:
    inc ecx
    jmp .loop
.done:
    popad
    ret

; ============================================================================
;  rc_on_crash:程序崩了之后除了记账还要干什么(on_crash="reboot" 就重启)
;  默认 "log":只记账,shell 接着用
; ============================================================================
rc_on_crash:
    pushad
    mov esi, rc_k_oncrash
    call rc_get
    test eax, eax
    jz .done
    mov esi, eax
    mov al, [esi]
    or al, 0x20
    cmp al, 'r'                     ; reboot
    jne .done
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_rc_reboot
    call term_print
    call cmd_reboot                 ; 不回来了
.done:
    popad
    ret

; ============================================================================
;  cmd_rc:shell 里的 rc 命令
;    rc              概要(读到了什么配置)
;    rc list         服务清单
;    rc get KEY      看某个 key 的值
;    rc start N      跑服务 N(走 run 那条路:ring 3 + 按需分页)
;    rc log          翻事件账本
;    rc reload       重新读 RC.CONF(改完不用重启)
; ============================================================================
cmd_rc:
    pushad
    ; ★ 这里不能调 strip_name:它会把**第一个空格**改成 0(那是给"只吃一个参数"
    ;   的命令准备的),而 rc 要 `rc get hostname` / `rc start 3` 这种两个词。
    ;   尾部换行由 shell 那边处理,这里自己按空格切第一个词。
    mov esi, [cmd_arg]
    cmp byte [esi], 0
    je .summary
    mov edi, esi                    ; 量第一个词的长度
    xor ecx, ecx
.len:
    mov al, [edi]
    test al, al
    jz .len_done
    cmp al, ' '
    je .len_done
    inc edi
    inc ecx
    jmp .len
.len_done:
    mov edx, n_rc_list
    call str_eq
    test eax, eax
    jnz .list
    mov edx, n_rc_log
    call str_eq
    test eax, eax
    jnz .log
    mov edx, n_rc_get
    call str_eq
    test eax, eax
    jnz .get
    mov edx, n_rc_start
    call str_eq
    test eax, eax
    jnz .start
    mov edx, n_rc_reload
    call str_eq
    test eax, eax
    jnz .reload
    mov edx, n_rc_status
    call str_eq
    test eax, eax
    jnz .summary
    ; 不认识的子命令
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_rc_usage
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    jmp .done

.summary:
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_rc_summary
    call term_print
    mov esi, rc_fname
    call term_print
    cmp dword [rc_ok], 0
    jne .sum_ok
    mov esi, msg_rc_absent
    call term_print
.sum_ok:
    mov al, 10
    call term_putc
    mov esi, msg_rc_keys2
    call term_print
    mov eax, [rc_keys]
    call term_print_dec
    mov esi, msg_rc_services
    call term_print
    mov eax, [rc_svc_n]
    call term_print_dec
    mov esi, msg_rc_enabled
    call term_print
    mov eax, [rc_svc_en]
    call term_print_dec
    mov esi, msg_rc_rparen_nl
    call term_print
    ; hostname / autostart / on_crash 三个值都给出来
    mov esi, msg_rc_hostname2
    call term_print
    call .show_host
    mov esi, msg_rc_autostart2
    call term_print
    mov esi, rc_k_autostart
    call rc_get
    call .show_val
    mov esi, msg_rc_oncrash2
    call term_print
    mov esi, rc_k_oncrash
    call rc_get
    call .show_val
    mov al, COL_NORMAL
    call term_set_color
    mov esi, msg_rc_hint
    call term_print
    jmp .done
.show_host:
    push esi
    mov esi, rc_k_hostname
    call rc_get
    test eax, eax
    jnz .sh_out
    mov eax, rc_def_host
.sh_out:
    mov esi, eax
    call term_print
    mov al, 10
    call term_putc
    pop esi
    ret
.show_val:
    test eax, eax
    jz .sv_none
    mov esi, eax
    call term_print
    mov al, 10
    call term_putc
    ret
.sv_none:
    mov esi, msg_rc_unset
    call term_print
    mov al, 10
    call term_putc
    ret

.list:
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_rc_listhead
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    mov dword [rc_tmp_n], 0
    mov dword [rc_lst_i], 1
    ; ★ 循环下标放内存里,别用 push/pop 保 ecx:第一版在循环里 push 了 ecx 却
    ;   没有配对的 pop(靠 .next 直接 jmp 回去),每列一个服务就多压 4 字节,
    ;   列完两个服务再 popad 就恢复了错位的寄存器,ret 跳到 EIP=0x00000007。
.loop:
    mov ecx, [rc_lst_i]
    cmp ecx, RC_SVCS
    ja .list_end
    call rc_svc_prog
    test eax, eax
    jz .next
    inc dword [rc_tmp_n]
    mov esi, msg_rc_lbracket
    call term_print
    mov eax, [rc_lst_i]                 ; 服务号那个字符
    add eax, '0'
    call term_putc
    mov al, ']'
    call term_putc
    mov al, ' '
    call term_putc
    mov ecx, [rc_lst_i]
    call rc_svc_prog
    mov esi, eax
    call term_print
    ; 启用状态
    mov ecx, [rc_lst_i]
    call rc_svc_enable
    test eax, eax
    jz .disabled
    mov al, COL_OK
    call term_set_color
    mov esi, msg_rc_yes
    call term_print
    jmp .args
.disabled:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_rc_no
    call term_print
.args:
    mov al, COL_NORMAL
    call term_set_color
    mov ecx, [rc_lst_i]
    call rc_svc_args
    test eax, eax
    jz .nl
    cmp byte [eax], 0
    je .nl
    mov esi, msg_rc_args
    call term_print
    mov ecx, [rc_lst_i]
    call rc_svc_args
    mov esi, eax
    call term_print
.nl:
    mov al, 10
    call term_putc
.next:
    inc dword [rc_lst_i]
    jmp .loop
.list_end:
    cmp dword [rc_tmp_n], 0
    jne .list_hint
    mov esi, msg_rc_nosvc
    call term_print
.list_hint:
    mov esi, msg_rc_starthint
    call term_print
    jmp .done

.get:
    mov esi, [cmd_arg]
    call rc_rest
    mov esi, eax
    cmp byte [esi], 0
    je .no_key_arg
    call rc_get
    test eax, eax
    jz .no_key
    mov esi, eax
    call term_print
    mov al, 10
    call term_putc
    jmp .done
.no_key:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_rc_nokey
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    jmp .done

.no_key_arg:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_rc_usage_get
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    jmp .done

.start:
    mov esi, [cmd_arg]
    call rc_rest
    mov esi, eax
    cmp byte [esi], 0
    je .bad_arg
    call rc_dec
    jc .bad_arg
    cmp eax, 1
    jb .bad_arg
    cmp eax, RC_SVCS
    ja .bad_arg
    mov ecx, eax
    call rc_run_service
    test eax, eax
    jz .no_svc
    jmp .done
.no_svc:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_rc_nosvc2
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    jmp .done
.bad_arg:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_rc_usage_start
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    jmp .done

.log:
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_rc_loghead
    call term_print
    mov dword [rc_tmp_n], 0
    mov eax, [rc_evt_n]
    cmp eax, RC_EVENTS
    jbe .log_have
    mov eax, RC_EVENTS              ; 环满了只显示最后 16 条
.log_have:
    mov [rc_tmp_shown], eax
    mov ecx, eax                    ; 从最老的开始:起点 = 总数 - 显示数
    jmp .log_first
.log_first:
    mov edx, [rc_evt_n]
    sub edx, ecx                    ; edx = 第几条(0 起)
    and edx, RC_EVENTS - 1
    mov esi, msg_rc_logdot
    call term_print
    mov eax, [rc_evt_tick + edx * 4]
    call term_print_dec
    mov esi, msg_rc_logtick
    call term_print
    mov eax, [rc_evt_id + edx * 4]
    cmp eax, EV_COUNT
    jb .log_name
    xor eax, eax
.log_name:
    mov eax, [evt_names + eax * 4]
    mov esi, eax
    call term_print
    mov esi, msg_rc_logarg
    call term_print
    mov eax, [rc_evt_arg + edx * 4]
    call term_print_hex
    mov al, 10
    call term_putc
    dec ecx
    jnz .log_first
    cmp dword [rc_evt_n], 0
    jne .log_done
    mov esi, msg_rc_noevt
    call term_print
.log_done:
    mov al, COL_NORMAL
    call term_set_color
    jmp .done

.reload:
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_rc_reload
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    call rc_load
    jmp .done

.done:
    popad
    ret

; ============================================================================
;  数据
; ============================================================================
rc_fname      db 'RC.CONF', 0
rc_k_svc      db 'service_', 0
rc_k_hostname db 'hostname', 0
rc_k_bootmsg  db 'boot_msg', 0
rc_k_autostart db 'autostart', 0
rc_k_oncrash  db 'on_crash', 0
rc_suf_none   db 0
rc_suf_args   db '_args', 0
rc_suf_enable db '_enable', 0
rc_def_host   db 'joyos', 0

rc_ok         dd 0                  ; 1 = 真的读到了 RC.CONF
rc_buf        times RC_MAX db 0     ; RC.CONF 的内容(就地解析:key=value 就地改 0)
rc_len        dd 0
rc_keys       dd 0
rc_kptr       times RC_KEYS dd 0
rc_vptr       times RC_KEYS dd 0
rc_kstart     dd 0
rc_vstart     dd 0
rc_keybuf     times 32 db 0
rc_svc_n      dd 0
rc_svc_en     dd 0
rc_runbuf     times RC_RUNBUF db 0
rc_run_prog   dd 0
rc_saved_arg  dd 0
rc_tmp_n      dd 0
rc_tmp_shown  dd 0
rc_lst_i      dd 0                  ; rc list 的循环下标
rc_run_num    dd 0                  ; rc_run_service 正在跑第几号服务(放内存,免得 push/pop 配不平)
rc_evt_n      dd 0
rc_evt_id     times RC_EVENTS dd 0
rc_evt_tick   times RC_EVENTS dd 0
rc_evt_arg    times RC_EVENTS dd 0

evt_names:
    dd n_ev_boot, n_ev_rcconf, n_ev_svc_start, n_ev_svc_ok, n_ev_svc_fail
    dd n_ev_prog_exit, n_ev_prog_crash, n_ev_kill, n_ev_shell

n_ev_boot       db 'boot', 0
n_ev_rcconf     db 'rc.conf', 0
n_ev_svc_start  db 'service start', 0
n_ev_svc_ok     db 'service ok', 0
n_ev_svc_fail   db 'service failed', 0
n_ev_prog_exit  db 'program exit', 0
n_ev_prog_crash db 'program crash', 0
n_ev_kill       db 'thread killed', 0
n_ev_shell      db 'shell switch', 0

n_rc_list     db 'list', 0
n_rc_log      db 'log', 0
n_rc_get      db 'get', 0
n_rc_start    db 'start', 0
n_rc_reload   db 'reload', 0
n_rc_status   db 'status', 0

msg_rc_head      db 'rc.conf: ', 0
msg_rc_comma     db ', ', 0
msg_rc_keys      db ' keys', 0
msg_rc_builtin   db 'no RC.CONF (built-in defaults)', 0
msg_rc_hostname  db ', hostname ', 0
msg_rc_hostname2 db '  hostname  : ', 0
msg_rc_svcs      db ', services ', 0
msg_rc_enabled   db ' (', 0
msg_rc_rparen_nl db ')', 10, 0
msg_rc_bootmsg   db 'boot_msg: ', 0
msg_rc_nofile    db 'rc.conf: no RC.CONF on disk, using built-in defaults (see docs/rc-conf.md)', 10, 0
msg_rc_autostart db 'rc.conf: autostart=YES, starting enabled services...', 10, 0
msg_rc_reboot    db 'on_crash=reboot: restarting the machine...', 10, 0
msg_rc_summary   db 'rc.conf  : ', 0
msg_rc_absent    db '  (没有 RC.CONF,用内置默认值)', 0
msg_rc_keys2     db '  keys     : ', 0
msg_rc_services  db '  services : ', 0
msg_rc_autostart2 db '  autostart: ', 0
msg_rc_oncrash2  db '  on_crash : ', 0
msg_rc_unset     db '(没设,用默认 log)', 0
msg_rc_hint      db 'rc list / rc get KEY / rc start N / rc log / rc reload', 10, 0
msg_rc_listhead  db 'services in RC.CONF:', 10, 0
msg_rc_lbracket  db '[', 0
msg_rc_yes       db ' enabled', 0
msg_rc_no        db ' disabled', 0
msg_rc_args      db '  args: ', 0
msg_rc_nosvc     db '(RC.CONF 里没有登记服务:加一行 service_1="HELLO.BIN")', 10, 0
msg_rc_starthint db 'rc start N 跑起来;enabled 只影响开机 autostart', 10, 0
msg_rc_nokey     db 'rc: 没有这个 key', 10, 0
msg_rc_nosvc2    db 'rc: 这个服务号在 RC.CONF 里没登记', 10, 0
msg_rc_usage_start db 'rc: 用法 rc start <1..8>', 10, 0
msg_rc_usage_get db 'rc: 用法 rc get <key>(比如 rc get hostname)', 10, 0
msg_rc_usage     db 'rc: 不认识的子命令,试试 rc list / rc get KEY / rc start N / rc log / rc reload', 10, 0
msg_rc_loghead   db 'event log (tick = 100 Hz PIT 心跳):', 10, 0
msg_rc_logdot    db '  t=', 0
msg_rc_logtick   db '  ', 0
msg_rc_logarg    db '  arg=', 0
msg_rc_noevt     db '  (账本还是空的)', 10, 0
msg_rc_reload    db 'rc.conf: reloading RC.CONF...', 10, 0
