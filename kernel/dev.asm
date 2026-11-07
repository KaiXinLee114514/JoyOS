; ============================================================================
;  dev.asm —— /DEV 设备抽象层(虚拟设备:不占磁盘,读写在内存里现做)
;
;  为什么要有这一层?
;    "一切皆文件"是 Unix 的老话:读硬盘、读时钟、写屏幕,对程序来说都是
;    打开一个名字、读 / 写字节。KKernel 的 FAT16 已经把"名字 → 字节"这条路
;    铺好了,这里只加一小段:文件名以 DEV/ 开头时,不查磁盘,改查设备表。
;
;  设备节点长什么样?
;    /DEV 目录里由 mkfat 摆了几个 0 字节的占位文件(ls 看得见),真正的读写
;    由内核按名字拦截 —— 占位文件的内容永远不会被读到。
;
;  名字匹配规则(大小写不敏感,前导 / 可省):
;      DEV/NULL      DEV/ZERO     DEV/RANDOM
;      DEV/RTC       DEV/CON      DEV/DEVICES
;
;  设备表每项 12 字节:名字指针 / 读函数 / 写函数(0 = 这个方向不支持)。
;  读函数:edi = 缓冲区,ecx = 最多几字节 → eax = 实际读了几字节(-1 = 失败)
;  写函数:esi = 数据,ecx = 字节数        → eax = 0 成功,-1 失败
;  两个方向的函数都自己 pushad 保护寄存器,只把结果留在 eax 里 —— 这样
;  shell 的 cat/write 和 int 0x30 的 API7/API8 可以共用同一批 handler。
;
;  加一个新设备:写一个 handler,往 dev_table 里加一行,再在 Makefile 的
;  MKFAT_FILES 里给 DEV/ 加个占位条目,最后在 docs/devices.md 里记一笔。
; ============================================================================

; ---------------------------------------------------------------------------
;  dev_lookup:esi = 名字 → eax = 设备表项地址(0 = 不是设备名)
;  先把 "DEV/" 前缀吃掉,剩下的逐个和表里的名字比(大小写不敏感)。
; ---------------------------------------------------------------------------
dev_lookup:
    pushad
    mov [dev_name_ptr], esi
    ; ---- 跳过前导的 / 或 \ ----
.skipsep:
    mov esi, [dev_name_ptr]
    mov al, [esi]
    cmp al, '/'
    je .skip1
    cmp al, 0x5C
    jne .devpart
.skip1:
    inc esi
    mov [dev_name_ptr], esi
    jmp .skipsep
    ; ---- 必须是 "DEV" 前缀 ----
.devpart:
    mov esi, [dev_name_ptr]
    mov edi, dev_prefix
    mov ecx, 3
    call dev_strnicmp
    test eax, eax
    jz .no
    mov esi, [dev_name_ptr]
    add esi, 3
    ; ---- 紧接着必须是 / 或 \ ----
    mov al, [esi]
    cmp al, '/'
    je .skip2
    cmp al, 0x5C
    jne .no
.skip2:
    inc esi
    mov [dev_name_ptr], esi
    ; ---- 遍历设备表,找同名项 ----
    mov ebx, dev_table
.next:
    mov eax, [ebx]
    test eax, eax
    jz .no
    mov esi, [dev_name_ptr]
    mov edi, eax
    call dev_name_eq
    test eax, eax
    jnz .found
    add ebx, 12
    jmp .next
.found:
    mov [dev_result], ebx
    popad
    mov eax, [dev_result]
    ret
.no:
    popad
    xor eax, eax
    ret

; dev_strnicmp:esi / edi 比 ecx 个字符,大小写不敏感 → eax = 1 相等 / 0 不等
dev_strnicmp:
    push edx
    push ecx
.loop:
    test ecx, ecx
    jz .eq
    mov al, [esi]
    call dev_up_al
    mov dl, [edi]
    mov dh, al
    mov al, dl
    call dev_up_al
    cmp al, dh
    jne .ne
    inc esi
    inc edi
    dec ecx
    jmp .loop
.eq:
    mov eax, 1
    pop ecx
    pop edx
    ret
.ne:
    xor eax, eax
    pop ecx
    pop edx
    ret

; dev_name_eq:esi / edi 比到 0 结尾(大小写不敏感),两边必须同时结束 → eax
dev_name_eq:
    push edx
.loop:
    lodsb
    call dev_up_al
    mov dl, [edi]
    mov dh, al
    mov al, dl
    call dev_up_al
    cmp al, dh
    jne .diff
    test dh, dh
    jz .same
    inc edi
    jmp .loop
.same:
    mov eax, 1
    pop edx
    ret
.diff:
    xor eax, eax
    pop edx
    ret

; dev_up_al:al 里的小写字母转大写(其它不变)
dev_up_al:
    cmp al, 'a'
    jb .ret
    cmp al, 'z'
    ja .ret
    sub al, 32
.ret:
    ret

; ===========================================================================
;  设备 handler
;  读:edi = 缓冲,ecx = 上限 → eax = 字节数;写:esi = 数据,ecx = 长度 → eax = 0
; ===========================================================================

; ---- NULL:读永远 0 字节,写直接丢掉(经典 /dev/null)----
dev_null_read:
dev_null_write:
    pushad
    xor eax, eax
    mov [dev_result], eax
    popad
    mov eax, [dev_result]
    ret

; ---- ZERO:读多少给多少 0 字节;写也丢掉(和 Null 一样对写入无反应)----
dev_zero_read:
    pushad
    mov [dev_max], ecx
    xor eax, eax
    rep stosb
    mov eax, [dev_max]
    mov [dev_result], eax
    popad
    mov eax, [dev_result]
    ret
dev_zero_write:
    jmp dev_null_write

; ---- RANDOM:xorshift32 伪随机字节(种子偷 PIT 的 tick 数)----
dev_rand_read:
    pushad
    mov [dev_max], ecx
    mov eax, [dev_rand_state]
    test eax, eax
    jnz .seeded
    call pit_get_ticks
    or eax, 0x9E3779B9
    mov [dev_rand_state], eax
.seeded:
    mov ebx, [dev_max]
.loop:
    test ebx, ebx
    jz .done
    mov eax, [dev_rand_state]
    mov edx, eax
    shl eax, 13
    xor eax, edx
    mov edx, eax
    shr edx, 17
    xor eax, edx
    mov edx, eax
    shl edx, 5
    xor eax, edx
    mov [dev_rand_state], eax
    stosb
    dec ebx
    jmp .loop
.done:
    mov eax, [dev_max]
    mov [dev_result], eax
    popad
    mov eax, [dev_result]
    ret

; ---- RTC:读 → "YYYY-MM-DD HH:MM:SS"(19 字节,不带换行)----
dev_rtc_read:
    mov [dev_arg_buf], edi
    pushad
    mov [dev_max], ecx
    call rtc_get
    mov edi, dev_tmp
    mov eax, [rtc_year]
    call dev_put4
    mov al, '-'
    stosb
    movzx eax, byte [rtc_mon]
    call dev_put2
    mov al, '-'
    stosb
    movzx eax, byte [rtc_day]
    call dev_put2
    mov al, ' '
    stosb
    movzx eax, byte [rtc_hour]
    call dev_put2
    mov al, ':'
    stosb
    movzx eax, byte [rtc_min]
    call dev_put2
    mov al, ':'
    stosb
    movzx eax, byte [rtc_sec]
    call dev_put2
    ; 拷到调用者缓冲(最多 19 字节)
    mov ecx, 19
    mov eax, [dev_max]
    cmp eax, ecx
    jae .copy
    mov ecx, eax
.copy:
    mov esi, dev_tmp
    mov edi, [dev_arg_buf]
    rep movsb
    mov eax, [dev_max]
    cmp eax, 19
    jbe .ret_max
    mov eax, 19
.ret_max:
    mov [dev_result], eax
    popad
    mov eax, [dev_result]
    ret

; ---- CON:写 → 当 UTF-8 文本打到屏幕上(不自动加换行)----
dev_con_write:
    mov [dev_arg_buf], esi
    pushad
    mov [dev_max], ecx
    cmp ecx, 255
    jbe .len_ok
    mov ecx, 255
.len_ok:
    mov esi, [dev_arg_buf]
    mov edi, dev_con_buf
    rep movsb
    mov byte [edi], 0
    mov esi, dev_con_buf
    call term_print
    xor eax, eax
    mov [dev_result], eax
    popad
    mov eax, [dev_result]
    ret

; ---- DEVICES:读 → 列出所有设备名,空格分隔(方便 cat DEV/DEVICES)----
dev_list_read:
    mov [dev_arg_buf], edi
    pushad
    mov [dev_max], ecx
    mov [dev_cnt], ecx
    mov edi, [dev_arg_buf]
    mov ebx, dev_table
.next:
    mov esi, [ebx]
    test esi, esi
    jz .done
    cmp ebx, dev_table
    je .no_space
    cmp dword [dev_cnt], 0
    jle .done
    mov al, ' '
    stosb
    dec dword [dev_cnt]
.no_space:
    mov esi, [ebx]
.name:
    mov al, [esi]
    test al, al
    jz .entry_done
    cmp dword [dev_cnt], 0
    jle .done
    stosb
    dec dword [dev_cnt]
    inc esi
    jmp .name
.entry_done:
    add ebx, 12
    jmp .next
.done:
    mov eax, [dev_max]
    sub eax, [dev_cnt]
    mov [dev_result], eax
    popad
    mov eax, [dev_result]
    ret

; ---- 十进制辅助:dev_put4 写 4 位、dev_put2 写 2 位,edi 自动前进 ----
dev_put4:
    push ecx
    push ebx
    mov ecx, 1000
    jmp dev_put_loop
dev_put2:
    push ecx
    push ebx
    mov ecx, 10
dev_put_loop:
    xor edx, edx
    div ecx
    add al, '0'
    stosb
    mov eax, edx
    push eax
    mov eax, ecx
    xor edx, edx
    mov ebx, 10
    div ebx
    mov ecx, eax
    pop eax
    test ecx, ecx
    jnz dev_put_loop
    pop ebx
    pop ecx
    ret

; ===========================================================================
;  数据
; ===========================================================================
dev_prefix      db 'DEV', 0
dev_n_null      db 'NULL', 0
dev_n_zero      db 'ZERO', 0
dev_n_random    db 'RANDOM', 0
dev_n_rtc       db 'RTC', 0
dev_n_con       db 'CON', 0
dev_n_devices   db 'DEVICES', 0

; 每项 12 字节:名字指针 / 读函数 / 写函数(0 = 不支持)
dev_table:
    dd dev_n_null,    dev_null_read,  dev_null_write
    dd dev_n_zero,    dev_zero_read,  dev_zero_write
    dd dev_n_random,  dev_rand_read,  0
    dd dev_n_rtc,     dev_rtc_read,   0
    dd dev_n_con,     0,              dev_con_write
    dd dev_n_devices, dev_list_read,  0
    dd 0

dev_name_ptr    dd 0
dev_arg_buf     dd 0
dev_max         dd 0
dev_cnt         dd 0
dev_result      dd 0
dev_rand_state  dd 0
dev_tmp         times 32 db 0
dev_con_buf     times 256 db 0
