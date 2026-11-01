; ============================================================================
;  JoyOS — FAT16 文件系统(读 + 写)
;
;  为什么要文件系统:字库能靠"裸读固定扇区"解决(见 fontdisk.asm),但要让别人
;  往盘里扔自己的东西(文本、程序),就得有个按名字找文件的东西 —— 那就是文件系统。
;  选 FAT16 是因为它结构最简单:一张 FAT 表 + 固定大小的根目录 + 数据区。
;
;  ── FAT16 长什么样(根目录 + FAT32 的簇链根 + 8.3 短名 + VFAT 长名)──────
;      引导扇区(BPB):每扇区字节数、每簇扇区数、保留扇区数、FAT 份数、
;                     根目录项数、每张 FAT 占多少扇区 …… 挂载就是把这些读出来
;      FAT 表:每簇 2 字节。0x0000 = 空闲,0xFFFF = 链尾,其它值 = 下一个簇
;      根目录:固定大小(根目录项数 × 32 字节),每项 32 字节
;          [0..10] 名字(8+3,空格补齐)  [11] 属性  [26..27] 首簇  [28..31] 大小
;      数据区:簇 N 的扇区 = 数据区起点 + (N - 2) × 每簇扇区数
;
;  ── 长文件名(VFAT LFN)────────────────────────────────────────────────
;  8.3 装不下的名字,短项前面排一串 32 字节项:attr=0x0F、order 从 N 到 1
;  (第一项再 |0x40)、偏移 13 是短项的校验和、13 个 UTF-16LE 字符一段;
;  目录里的顺序是 N..1 再短项。读的时候把链拼起来、校验和对上才认。
;  这里只支持 ASCII 长名(UTF-16 高字节恒为 0,非 ASCII 一律当 '?' 匹配不上)。
;
;  ── 两个坑 ──────────────────────────────────────────────────────────────
;   1. 每次读盘/写盘都得**重新算 LBA**,不能"记住上次读到哪"(FAT 表是随机访问的)
;   2. FAT 表被改过必须写回(而且两份 FAT 都要写),不然重启后文件就"没了"
; ============================================================================

FAT_PART_LBA equ 6144                   ; FAT16 分区从哪个 LBA 开始(和 Makefile 里 mkfat.py 的参数一致;
                                        ; 必须排在字库(LBA 2048 起)之后,不然两边会互相踩)
FAT_BUF      equ 0x100000               ; 1 MiB:扇区缓冲(挂载/目录/FAT 共用)

; ---------------------------------------------------------------------------
;  fat_mount:读分区的引导扇区,把 BPB 里的参数记下来
; ---------------------------------------------------------------------------
fat_mount:
    pushad
    mov eax, FAT_PART_LBA
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    cmp eax, 0
    jne .fail
    mov esi, FAT_BUF
    cmp word [esi + 510], 0xAA55
    jne .fail

    movzx eax, word [esi + 11]
    mov [fat_bps], eax
    cmp eax, 512
    jne .fail                           ; 只支持 512 字节扇区
    movzx eax, byte [esi + 13]
    mov [fat_spc], eax
    movzx eax, word [esi + 14]
    mov [fat_reserved], eax
    movzx eax, byte [esi + 16]
    mov [fat_nfats], eax
    movzx eax, word [esi + 17]
    mov [fat_root_ents], eax
    movzx eax, word [esi + 22]
    mov [fat_size], eax
    mov dword [fat_eoc], 0xFFF8          ; FAT16 的链尾门槛
    mov byte [fat_fat32], 0
    ; ---- FAT16 还是 FAT32?规范:f16 里的"每 FAT 扇区数"(偏移 22)为 0 → FAT32 ----
    test eax, eax
    jnz .fat16_done
    mov byte [fat_fat32], 1
    mov eax, [esi + 36]                 ; FAT32:每张 FAT 的扇区数(32 位)
    mov [fat_size], eax
    mov eax, [esi + 44]                 ; FAT32:根目录首簇(根也是簇链)
    and eax, 0x0FFFFFFF
    mov [fat_root_cluster], eax
    movzx eax, word [esi + 48]          ; FSInfo 扇区(先记下来备用)
    mov [fat_fsinfo], eax
    mov dword [fat_root_ents], 0        ; FAT32 没有固定根目录区
    mov dword [fat_eoc], 0x0FFFFFF8     ; 28 位的链尾门槛
.fat16_done:

    ; FAT 表起始 = 分区起点 + 保留扇区
    mov eax, FAT_PART_LBA
    add eax, [fat_reserved]
    mov [fat_fat_lba], eax

    ; 根目录起始 = FAT 起始 + FAT 份数 × 每张 FAT 扇区数
    mov eax, [fat_nfats]
    imul eax, [fat_size]
    add eax, [fat_fat_lba]
    mov [fat_root_lba], eax

    ; 数据区起始 = 根目录起始 + ceil(根目录项数 × 32 / 每扇区字节数)
    mov eax, [fat_root_ents]
    shl eax, 5                          ; × 32
    add eax, 511
    shr eax, 9                          ; ÷ 512
    add eax, [fat_root_lba]
    mov [fat_data_lba], eax

    mov dword [fat_cache_lba], -1
    mov byte [fat_ok], 1
    popad
    xor eax, eax
    ret
.fail:
    mov byte [fat_ok], 0
    popad
    mov eax, -1
    ret

; ---------------------------------------------------------------------------
;  fat_name83:"HELLO.BIN" + 0 → 11 字节 8.3 名(大写、空格补齐),写到 fat_name
; ---------------------------------------------------------------------------
fat_name83:
    pushad
    mov edi, fat_name
    mov ecx, 11
    mov al, ' '
    rep stosb                           ; 先全填空格
    mov edi, fat_name
    mov ecx, 8                          ; 主名最多 8 字节
.base:
    lodsb
    test al, al
    jz .done
    cmp al, '.'
    je .ext
    cmp al, 'a'
    jb .store
    cmp al, 'z'
    ja .store
    sub al, 32                          ; 小写 → 大写
.store:
    mov [edi], al
    inc edi
    dec ecx
    jnz .base
    ; 主名超过 8 字节,跳到扩展名
.skip_to_ext:
    lodsb
    test al, al
    jz .done
    cmp al, '.'
    jne .skip_to_ext
.ext:
    mov edi, fat_name + 8
    mov ecx, 3
.ext_loop:
    lodsb
    test al, al
    jz .done
    cmp al, 'a'
    jb .ext_store
    cmp al, 'z'
    ja .ext_store
    sub al, 32
.ext_store:
    mov [edi], al
    inc edi
    dec ecx
    jnz .ext_loop
.done:
    popad
    ret

; ---------------------------------------------------------------------------
;  fat_lfn_checksum:esi = 11 字节短名 → al = VFAT 长名项里的校验和
;    算法:sum = ((sum & 1) << 7) + (sum >> 1) + 字节,逐字节滚一遍。
;    tools/mkfat.py 的 lfn_checksum 用的是同一套,两边必须一致。
; ---------------------------------------------------------------------------
fat_lfn_checksum:
    push esi
    push ecx
    push edx
    xor edx, edx
    mov ecx, 11
.loop:
    mov al, [esi]
    inc esi
    mov ah, dl
    and ah, 1
    shl ah, 7
    shr dl, 1
    add dl, ah
    add dl, al
    dec ecx
    jnz .loop
    mov al, dl
    pop edx
    pop ecx
    pop esi
    ret

; ---------------------------------------------------------------------------
;  fat_char_legal:al = 已转成大写的字符 → CF=1 表示它能出现在 8.3 名里
; ---------------------------------------------------------------------------
fat_char_legal:
    push ebx
    push esi
    cmp al, 'A'
    jb .num
    cmp al, 'Z'
    jbe .ok
.num:
    cmp al, '0'
    jb .punct
    cmp al, '9'
    jbe .ok
.punct:
    mov esi, fat_legal_chars
.scan:
    mov bl, [esi]
    test bl, bl
    jz .bad
    cmp al, bl
    je .ok
    inc esi
    jmp .scan
.ok:
    pop esi
    pop ebx
    clc
    ret
.bad:
    pop esi
    pop ebx
    stc
    ret

; ---------------------------------------------------------------------------
;  fat_sanitize_char:al = 字符 → al = 大写合法字符;不合法就换成 '_'
; ---------------------------------------------------------------------------
fat_sanitize_char:
    push ebx
    push esi
    cmp al, 'a'
    jb .up
    cmp al, 'z'
    ja .up
    sub al, 32
.up:
    call fat_char_legal
    jnc .done                          ; CF=0 合法 → 保留大写字符
    mov al, '_'                        ; CF=1 非法 → 换成 '_'
.done:
    pop esi
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  fat_lfn_scan:esi = 目录项 → 是 LFN 项就收进 lfn_name 并返回 CF=1,
;                不是(短项/卷标等)返回 CF=0。状态存在 lfn_state 里,
;                所以链跨扇区、跨簇都能接上。
;    lfn_name 里只放 ASCII 低位;高字节非 0 的字符记成 '?',
;    这样带中文等非 ASCII 的长名永远匹配不上 ASCII 请求名。
; ---------------------------------------------------------------------------
fat_lfn_scan:
    push eax
    push ecx
    push edx
    push edi
    mov al, [esi + 11]
    and al, 0x0F
    cmp al, 0x0F
    jne .not_lfn
    movzx eax, byte [esi]
    mov edx, eax
    and edx, 0x3F
    test al, 0x40
    jz .more
    ; ---- 带 0x40 的是链的第一项(order = N):重置状态 ----
    test edx, edx
    jz .bad
    cmp edx, 20
    ja .bad
    mov [lfn_expect], edx
    mov dword [lfn_filled], 0
    mov dword [lfn_state], 1
    movzx eax, byte [esi + 13]
    mov [lfn_sum], eax
    push esi
    mov edi, lfn_name
    mov ecx, 272
    xor eax, eax
    rep stosb
    pop esi
    jmp .store
.more:
    cmp dword [lfn_state], 0
    je .handled
    mov eax, [lfn_expect]
    sub eax, [lfn_filled]
    cmp eax, edx
    jne .bad
    test edx, edx
    jz .bad
.store:
    dec edx
    imul edx, 13
    lea edi, [lfn_name + edx]
    xor ecx, ecx
.char:
    movzx edx, byte [lfn_offs + ecx]
    mov al, [esi + edx]
    cmp byte [esi + edx + 1], 0
    je .low
    mov al, '?'
.low:
    mov [edi + ecx], al
    inc ecx
    cmp ecx, 13
    jb .char
    inc dword [lfn_filled]
    jmp .handled
.bad:
    mov dword [lfn_state], 0
.handled:
    pop edi
    pop edx
    pop ecx
    pop eax
    stc
    ret
.not_lfn:
    pop edi
    pop edx
    pop ecx
    pop eax
    clc
    ret

; ---------------------------------------------------------------------------
;  fat_lfn_need:esi = 名字 → eax = 1 表示这个名字没法原样放进 11 字节 8.3 项
;                (太长 / 字符不合法 / 多个点 / 空主名 / 结尾是点)
;    纯小写的合法 8.3 名不算:老行为就是存成大写短名(fat_name83),不改。
; ---------------------------------------------------------------------------
fat_lfn_need:
    pushad
    mov dword [lfn_base_len], 0
    mov dword [lfn_ext_len], 0
    mov dword [lfn_dots], 0
    mov dword [lfn_need], 0
    xor ebx, ebx                        ; 0 = 还在主名,1 = 到扩展名了
.loop:
    lodsb
    test al, al
    jz .end
    cmp al, '.'
    jne .char
    inc dword [lfn_dots]
    cmp dword [lfn_dots], 1
    jne .need                           ; 第二个点
    mov ebx, 1
    jmp .loop
.char:
    cmp al, 'a'
    jb .up
    cmp al, 'z'
    ja .up
    sub al, 32
.up:
    call fat_char_legal
    jc .need                            ; 空格、中文之类,8.3 放不下
    test ebx, ebx
    jnz .in_ext
    inc dword [lfn_base_len]
    cmp dword [lfn_base_len], 8
    ja .need
    jmp .loop
.in_ext:
    inc dword [lfn_ext_len]
    cmp dword [lfn_ext_len], 3
    ja .need
    jmp .loop
.end:
    cmp dword [lfn_base_len], 0
    je .need
    cmp dword [lfn_dots], 0
    je .done
    cmp dword [lfn_ext_len], 0
    je .need                            ; "NAME." 结尾那个点存不进去
.done:
    popad
    mov eax, [lfn_need]
    ret
.need:
    mov dword [lfn_need], 1
    popad
    mov eax, 1
    ret

; ---------------------------------------------------------------------------
;  fat_lfn_alias:esi = 原名 → 生成当前目录里没占用的 11 字节短别名(fat_name)
;    规则:能原样收成合法 8.3 就用它(非法字符换 '_');被截断/撞名就
;    BASE 取前 6(两位数时前 5)+ "~n" + ".EXT",n 从 1 往上查。
;    成功 CF=0,别名用完 CF=1。查重靠 fat_find(短名 + 长名都比)。
; ---------------------------------------------------------------------------
fat_lfn_alias:
    pushad
    ; ---- 1) 找最后一个点,拆主名/扩展名,非法字符换成 '_' ----
    mov edx, esi
    xor ebx, ebx
.find_dot:
    mov al, [edx]
    test al, al
    jz .split
    cmp al, '.'
    jne .fd_next
    mov ebx, edx
.fd_next:
    inc edx
    jmp .find_dot
.split:
    mov edi, lfn_base_buf
    xor ecx, ecx
    mov edx, esi
.base:
    mov al, [edx]
    test al, al
    jz .base_end
    cmp edx, ebx
    je .base_end
    call fat_sanitize_char
    mov [edi + ecx], al
    inc ecx
    cmp ecx, 32
    jae .base_end
    inc edx
    jmp .base
.base_end:
    mov [lfn_base_len], ecx
    xor ecx, ecx
    test ebx, ebx
    jz .ext_end
    lea edx, [ebx + 1]
.ext:
    mov al, [edx]
    test al, al
    jz .ext_end
    call fat_sanitize_char
    mov [lfn_ext_buf + ecx], al
    inc ecx
    cmp ecx, 16
    jae .ext_end
    inc edx
    jmp .ext
.ext_end:
    mov [lfn_ext_len], ecx
    ; ---- 2) 先试"不截断"的候选 ----
    cmp dword [lfn_base_len], 0
    je .tilde
    cmp dword [lfn_base_len], 8
    ja .tilde
    cmp dword [lfn_ext_len], 3
    ja .tilde
    call fat_alias_build_plain
    call fat_alias_free
    jnc .ok
.tilde:
    ; ---- 3) 截断/撞名:BASE 前 6 + "~n"(n = 1..99) ----
    mov dword [lfn_alias_n], 1
.tn:
    mov eax, [lfn_alias_n]
    cmp eax, 100
    jae .fail
    call fat_alias_build_tilde
    call fat_alias_free
    jnc .ok
    inc dword [lfn_alias_n]
    jmp .tn
.ok:
    mov esi, lfn_alias_str
    call fat_name83                     ; 字符串 → 11 字节短名(fat_name)
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; 造"不截断"的候选字符串(主名 + 有扩展名才加点 + 扩展名)
fat_alias_build_plain:
    push eax
    push ecx
    push esi
    push edi
    mov edi, lfn_alias_str
    mov esi, lfn_base_buf
    mov ecx, [lfn_base_len]
    rep movsb
    cmp dword [lfn_ext_len], 0
    je .done
    mov al, '.'
    stosb
    mov esi, lfn_ext_buf
    mov ecx, [lfn_ext_len]
    rep movsb
.done:
    mov byte [edi], 0
    pop edi
    pop esi
    pop ecx
    pop eax
    ret

; 造"BASE 前 6 + ~n"的候选字符串(带扩展名时补 .EXT)
fat_alias_build_tilde:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov eax, [lfn_alias_n]
    mov ecx, 6
    cmp eax, 10
    jb .keep
    mov ecx, 5                          ; 两位数:留 5 个字符给 BASE
.keep:
    mov edx, [lfn_base_len]
    cmp edx, ecx
    jbe .cp
    mov edx, ecx
.cp:
    mov esi, lfn_base_buf
    mov edi, lfn_alias_str
    mov ecx, edx
    rep movsb
    mov al, '~'
    stosb
    mov eax, [lfn_alias_n]
    cmp eax, 10
    jb .one
    xor edx, edx
    mov ecx, 10
    div ecx                             ; eax = 十位,edx = 个位
    add al, '0'
    stosb
    mov al, dl
    add al, '0'
    stosb
    jmp .ext
.one:
    add al, '0'
    stosb
.ext:
    cmp dword [lfn_ext_len], 0
    je .done
    mov al, '.'
    stosb
    mov esi, lfn_ext_buf
    mov ecx, [lfn_ext_len]
    cmp ecx, 3
    jbe .ec
    mov ecx, 3
.ec:
    rep movsb
.done:
    mov byte [edi], 0
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; 检查 lfn_alias_str 这个短名在当前目录里是否空着(CF=0 = 空着)
fat_alias_free:
    pushad
    mov esi, lfn_alias_str
    call fat_find
    cmp eax, -1
    je .free
    popad
    stc
    ret
.free:
    popad
    clc
    ret

; ---------------------------------------------------------------------------
;  fat_build_short_entry:edi = 32 字节目录项地址 → 按 fat_name / [lfn_attr]
;    填一个短项(名字 11 字节 + 属性,其余清零;首簇/大小由调用方补)
; ---------------------------------------------------------------------------
fat_build_short_entry:
    push eax
    push ecx
    push esi
    push edi
    push edi
    mov ecx, 32
    xor eax, eax
    rep stosb
    pop edi
    mov esi, fat_name
    mov ecx, 11
    rep movsb
    mov al, [lfn_attr]
    mov [edi], al
    pop edi
    pop esi
    pop ecx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  fat_lfn_prepare:esi = 名字,edx = 属性(0x20 文件 / 0x10 目录)
;    结果:fat_name = 11 字节短别名;lfn_cnt = LFN 项数 N(0 = 不需要 LFN);
;          lfn_total = N+1;lfn_entries 里排好 N 个 LFN 项 + 1 个短项
;          (短项首簇/大小留 0,调用方写盘前再填)。失败 CF=1。
; ---------------------------------------------------------------------------
fat_lfn_prepare:
    pushad
    mov [lfn_attr], edx
    mov [fat_name_ptr], esi
    call fat_lfn_need
    test eax, eax
    jnz .long
    ; ---- 老路:直接一个 8.3 短项 ----
    mov esi, [fat_name_ptr]
    call fat_name83
    mov dword [lfn_cnt], 0
    mov dword [lfn_total], 1
    mov edi, lfn_entries
    call fat_build_short_entry
    popad
    clc
    ret
.long:
    mov esi, [fat_name_ptr]
    call fat_lfn_alias
    jc .fail
    ; ---- 名字长度 → N = ceil((len+1)/13) ----
    mov esi, [fat_name_ptr]
    xor ecx, ecx
.len:
    cmp byte [esi], 0
    je .got_len
    inc esi
    inc ecx
    jmp .len
.got_len:
    mov eax, ecx
    inc eax                             ; 含结尾 0
    add eax, 12
    xor edx, edx
    mov ecx, 13
    div ecx
    mov [lfn_cnt], eax
    cmp eax, 15
    ja .fail                            ; 一扇区最多 16 项,N+1 必须装得下
    inc eax
    mov [lfn_total], eax
    ; ---- 逐段倒着写:内存里顺序 N..1 ----
    mov ebx, [lfn_cnt]
.gen:
    test ebx, ebx
    jz .gen_done
    mov eax, [lfn_cnt]
    sub eax, ebx
    shl eax, 5
    lea edi, [lfn_entries + eax]
    push ebx
    push edi
    mov ecx, 32
    xor eax, eax
    rep stosb
    pop edi
    pop ebx
    mov eax, ebx
    cmp ebx, [lfn_cnt]
    jne .no_last
    or eax, 0x40
.no_last:
    mov [edi], al
    mov byte [edi + 11], 0x0F
    push ebx
    push edi
    mov esi, fat_name
    call fat_lfn_checksum
    pop edi
    pop ebx
    mov [edi + 13], al
    mov eax, ebx
    dec eax
    imul eax, 13
    add eax, [fat_name_ptr]
    mov esi, eax
    xor ecx, ecx
.chr:
    movzx edx, byte [lfn_offs + ecx]
    mov al, [esi]
    test al, al
    jz .pad
    mov [edi + edx], al
    mov byte [edi + edx + 1], 0
    inc esi
    inc ecx
    cmp ecx, 13
    jb .chr
    jmp .item_done
.pad:
    ; 名字到头:先写 UTF-16 的 0 结束符,剩下的补 0xFFFF
    mov byte [edi + edx], 0
    mov byte [edi + edx + 1], 0
    inc ecx
    inc esi
.pad_loop:
    cmp ecx, 13
    jae .item_done
    movzx edx, byte [lfn_offs + ecx]
    mov byte [edi + edx], 0xFF
    mov byte [edi + edx + 1], 0xFF
    inc ecx
    jmp .pad_loop
.item_done:
    dec ebx
    jmp .gen
.gen_done:
    mov eax, [lfn_cnt]
    shl eax, 5
    lea edi, [lfn_entries + eax]
    call fat_build_short_entry
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; ---------------------------------------------------------------------------
;  fat_ent_cluster:esi = 目录项地址 → eax = 它指向的首簇(兼容 FAT16/FAT32)
;                  FAT32 的簇号高 16 位藏在偏移 +20 里(其实只有低 4 位有效)
; ---------------------------------------------------------------------------
fat_ent_cluster:
    movzx eax, word [esi + 26]
    cmp byte [fat_fat32], 0
    je .done
    movzx edx, word [esi + 20]
    shl edx, 16
    or eax, edx
    and eax, 0x0FFFFFFF
.done:
    ret

; ---------------------------------------------------------------------------
;  fat_find:在 [fat_dir] 指向的目录里找 esi 给的名字
;            [fat_dir] = 0 → 根目录(固定区域);否则是子目录(沿簇链找)
;            名字可以是 8.3 短名,也可以是 VFAT 长名(ASCII,大小写不敏感):
;              · 先比 11 字节短名(老路径,快);
;              · 同时把前面的 LFN 链拼起来,校验和对上才拿去比长名 ——
;                不然别的文件的长名可能被错认成这个。
;            找到了返回 eax = 目录项所在的扇区 LBA,
;            [fat_entry_off] = 表项在扇区内的偏移;[fat_found_lba] 也记一份;
;            [lfn_matched] = 靠 LFN 命中时用掉的项数(0 = 靠 8.3 命中);
;            找不到返回 eax = -1
; ---------------------------------------------------------------------------
fat_find:
    pushad
    ; ---- 把请求名抄一份到 lfn_req,并算 8.3 快路径 ----
    mov edi, lfn_req
    mov ecx, 255
.copy_req:
    lodsb
    test al, al
    jz .req_done
    stosb
    dec ecx
    jnz .copy_req
    mov byte [edi], 0
    jmp .req_ok
.req_done:
    mov byte [edi], 0
.req_ok:
    mov esi, lfn_req
    call fat_name83
    mov dword [lfn_state], 0
    mov dword [lfn_matched], 0

    ; ---- 定起点:FAT16 固定根目录 还是 一条簇链 ----
    mov eax, [fat_dir]
    test eax, eax
    jnz .dir_clus
    cmp byte [fat_fat32], 0
    jne .root32
    mov dword [fat_scan_cluster], 0     ; 0 = 固定根目录(没有簇链)
    mov eax, [fat_root_lba]
    mov [fat_scan_lba], eax
    mov eax, [fat_root_ents]
    shl eax, 5
    add eax, 511
    shr eax, 9
    mov [fat_scan_sect], eax            ; 固定根:这个变量当"还剩几个扇区"
    jmp .next_sector
.root32:
    mov eax, [fat_root_cluster]
.dir_clus:
    mov [fat_scan_cluster], eax
    mov dword [fat_scan_sect], 0        ; 子目录:簇内扇区号

.next_sector:
    mov eax, [fat_scan_cluster]
    test eax, eax
    jz .root_sector
    cmp eax, [fat_eoc]
    jae .not_found
    sub eax, 2
    imul eax, [fat_spc]
    add eax, [fat_data_lba]
    add eax, [fat_scan_sect]
    jmp .read
.root_sector:
    cmp dword [fat_scan_sect], 0
    je .not_found
    mov eax, [fat_scan_lba]
.read:
    mov [fat_scan_lba], eax
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    cmp eax, 0
    jne .not_found
    mov dword [fat_cache_lba], -1
    xor ebx, ebx
.entry:
    cmp ebx, 512
    jae .sector_done
    mov esi, FAT_BUF
    add esi, ebx
    movzx eax, byte [esi]
    test al, al
    jz .not_found                       ; 0x00 = 后面都是空的
    cmp al, 0xE5
    je .dead
    call fat_lfn_scan
    jc .advance                         ; 长名项:收进 lfn_name,继续
    ; ---- 短项:先比 8.3 快路径 ----
    mov edi, fat_name
    mov ecx, 11
    push esi
.cmp83:
    mov al, [esi]
    cmp al, [edi]
    jne .cmp_long
    inc esi
    inc edi
    dec ecx
    jnz .cmp83
    pop esi
    mov dword [lfn_matched], 0
    jmp .found
.cmp_long:
    pop esi
    cmp dword [lfn_state], 0
    je .short_miss
    mov eax, [lfn_filled]
    cmp eax, [lfn_expect]
    jne .short_miss
    call fat_lfn_checksum               ; esi = 短项 → al
    movzx eax, al
    cmp eax, [lfn_sum]
    jne .short_miss
    ; ---- 长名逐字节比,ASCII 大小写不敏感 ----
    mov esi, lfn_name
    mov edi, lfn_req
.compare_long:
    mov al, [esi]
    mov ah, [edi]
    cmp al, 'a'
    jb .fold_b
    cmp al, 'z'
    ja .fold_b
    sub al, 32
.fold_b:
    cmp ah, 'a'
    jb .fold_done
    cmp ah, 'z'
    ja .fold_done
    sub ah, 32
.fold_done:
    cmp al, ah
    jne .short_miss
    test al, al
    jz .long_hit
    inc esi
    inc edi
    jmp .compare_long
.long_hit:
    mov eax, [lfn_expect]
    mov [lfn_matched], eax
    jmp .found
.short_miss:
    mov dword [lfn_state], 0            ; 短项没配上,这条 LFN 链作废
.advance:
    add ebx, 32
    jmp .entry
.dead:
    mov dword [lfn_state], 0            ; 删除项会打断 LFN 链
    add ebx, 32
    jmp .entry

.found:
    mov [fat_entry_off], ebx
    mov eax, [fat_scan_lba]
    mov [fat_found_lba], eax
    popad
    mov eax, [fat_found_lba]
    ret

.sector_done:
    mov eax, [fat_scan_cluster]
    test eax, eax
    jz .root_next
    inc dword [fat_scan_sect]
    mov eax, [fat_scan_sect]
    cmp eax, [fat_spc]
    jb .next_sector
    mov eax, [fat_scan_cluster]
    mov [fat_cluster], eax
    call fat_next_cluster
    mov [fat_scan_cluster], eax
    mov dword [fat_scan_sect], 0
    jmp .next_sector
.root_next:
    inc dword [fat_scan_lba]
    dec dword [fat_scan_sect]
    jmp .next_sector
.not_found:
    popad
    mov eax, -1
    ret

; ---------------------------------------------------------------------------
;  fat_find_run:在当前目录里找连续 ecx 个空目录项(0x00 或 0xE5),
;               并且这 ecx 项必须落在同一个扇区里 —— 写路径一次写一个扇区。
;               (读路径的 LFN 链可以跨扇区,写路径不搞那么复杂:N+1 ≤ 16。)
;    ecx = 项数(调用前已经 fat_lfn_prepare 造好条目)
;    成功 CF=0,eax = 扇区 LBA,[fat_entry_off] = 第一项在扇区里的偏移;
;    失败 CF=1(根目录固定区不能扩,子目录会试着在链尾扩一簇再扫)。
; ---------------------------------------------------------------------------
fat_find_run:
    pushad
    mov [frun_need], ecx
    mov dword [frun_new], 0
    mov eax, [fat_dir]
    test eax, eax
    jnz .dir_clus
    cmp byte [fat_fat32], 0
    jne .root32
    mov dword [frun_clus], 0            ; FAT16 固定根目录
    mov eax, [fat_root_lba]
    mov [frun_lba], eax
    mov eax, [fat_root_ents]
    shl eax, 5
    add eax, 511
    shr eax, 9
    mov [frun_left], eax                ; 还剩几个扇区
    jmp .sec
.root32:
    mov eax, [fat_root_cluster]
.dir_clus:
    mov [frun_clus], eax
    mov dword [frun_left], 0
.sec:
    mov eax, [frun_clus]
    test eax, eax
    jz .root_sec
    cmp eax, [fat_eoc]
    jae .extend
    sub eax, 2
    imul eax, [fat_spc]
    add eax, [fat_data_lba]
    add eax, [frun_left]
    jmp .rd
.root_sec:
    cmp dword [frun_left], 0
    je .extend
    mov eax, [frun_lba]
.rd:
    mov [frun_lba], eax
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    cmp eax, 0
    jne .fail
    mov dword [fat_cache_lba], -1
    xor ebx, ebx
.chk:
    mov eax, [frun_need]
    shl eax, 5
    mov edx, ebx
    add edx, eax                        ; edx = 这一段结束偏移
    cmp edx, 512
    ja .next_sect
    mov eax, ebx
.cnt:
    cmp eax, edx
    jae .found
    mov esi, FAT_BUF
    add esi, eax
    mov cl, [esi]
    test cl, cl
    jz .cnext
    cmp cl, 0xE5
    jne .occupied
.cnext:
    add eax, 32
    jmp .cnt
.occupied:
    ; 这个起始位置被占了:窗口往后挪一个目录项,继续在本扇区里找
    ; (以前这里直接跳下一扇区,会跳过前面的空位,把新目录项写到很后面,
    ;  而 ls 遇到 0x00 就认为目录结束了 → 新文件在 ls 里消失)
    add ebx, 32
    jmp .chk
.found:
    mov [fat_entry_off], ebx
    mov eax, [frun_lba]
    mov [fat_found_lba], eax
    popad
    mov eax, [frun_lba]                 ; ★ popad 会还原 eax:返回值必须在它之后装
    clc
    ret
.next_sect:
    mov eax, [frun_clus]
    test eax, eax
    jz .root_n
    inc dword [frun_left]
    mov eax, [frun_left]
    cmp eax, [fat_spc]
    jb .sec
    mov eax, [frun_clus]
    mov [fat_cluster], eax
    call fat_next_cluster
    mov [frun_clus], eax
    mov dword [frun_left], 0
    jmp .sec
.root_n:
    inc dword [frun_lba]
    dec dword [frun_left]
    jmp .sec
.extend:
    ; 子目录:链尾接一簇(全 0),再扫这一簇 —— 前面已经确认整条链没有空位
    mov eax, [frun_clus]
    test eax, eax
    jz .fail                            ; 固定根目录:扩不了,老实失败
    cmp dword [frun_new], 0
    jne .fail                           ; 只扩一次
    call fat_alloc_cluster
    test eax, eax
    jz .fail
    mov [frun_new], eax
    call fat_zero_cluster
    mov eax, [frun_clus]
    mov [fat_cluster], eax
    mov eax, [frun_new]
    call fat_set_entry
    mov eax, [frun_new]
    mov [frun_clus], eax
    mov dword [frun_left], 0
    jmp .sec
.fail:
    popad
    stc
    ret

; ---------------------------------------------------------------------------
;  fat_write_run:eax = 扇区 LBA,[fat_entry_off] = 起始偏移,
;                把 lfn_entries 里的 [lfn_total] 个连续目录项整段写进去。
;                成功 CF=0,失败 CF=1。
; ---------------------------------------------------------------------------
fat_write_run:
    pushad
    mov [frun_lba], eax
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    cmp eax, 0
    jne .fail
    mov edi, FAT_BUF
    add edi, [fat_entry_off]
    mov esi, lfn_entries
    mov ecx, [lfn_total]
    shl ecx, 5
    rep movsb
    mov eax, [frun_lba]
    mov ecx, 1
    mov esi, FAT_BUF
    call ata_write_sectors
    mov dword [fat_cache_lba], -1
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; ---------------------------------------------------------------------------
;  fat_chdir:esi = 目录名(8.3 短名)→ 把 [fat_dir] 换成这个目录的首簇
;            成功 CF=0,失败 CF=1(名字不存在 / 不是目录)
; ---------------------------------------------------------------------------
fat_chdir:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi
    call fat_find                       ; 短名/长名都能找(fat_find 内部先比 8.3)
    cmp eax, -1
    je .fail
    ; 找到的位置在 [fat_found_lba],把那一扇区重读一遍取首簇和属性
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    mov dword [fat_cache_lba], -1
    mov esi, FAT_BUF
    add esi, [fat_entry_off]
    mov al, [esi + 11]
    test al, 0x10                       ; attr bit4 = 目录
    jz .fail
    call fat_ent_cluster                ; 目录自己的首簇(FAT16/32 通用)
    test eax, eax
    jz .fail
    mov [fat_dir], eax
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop eax
    clc
    ret
.fail:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop eax
    stc
    ret

; ---------------------------------------------------------------------------
;  fat_path:esi = "DOCS/NOTE.TXT"(也认反斜杠)→ 逐段进目录,
;            返回 eax = 最后一段(文件名)的指针,CF=1 = 中间有一层进不去
;
;  为什么要先把整条路径抄进自己的缓冲(path_buf):
;    · 直接改调用方的字符串(cmd_arg)再恢复,一旦哪一步提前返回,字符串就被切坏了;
;    · 更要紧的是:内核里到处都用 esi 传名字,改来改去容易把"当前段的指针"
;      和"下一段的位置"搞混 —— 第一版就是这么坏的:fat_name83 收到的是整条路径
;      ("DOCS/NOTE.TXT" 被它当成 8.3 名 → "DOCS/NOT" + "TXT",于是永远找不到)。
;    自己抄一份、在副本上切段,就没有这些牵扯了。
;
;  调用前请把 [fat_dir] 清 0(从根目录开始)
; ---------------------------------------------------------------------------
PP_MAX equ 256                          ; 路径最长 255 字符(长文件名可能很长)
fat_path:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    ; ---- 1) 抄一份路径进 path_buf ----
    mov edi, path_buf
    mov ecx, PP_MAX - 1
.cpy:
    mov al, [esi]
    test al, al
    jz .cpy_done
    mov [edi], al
    inc esi
    inc edi
    dec ecx
    jnz .cpy
.cpy_done:
    mov byte [edi], 0
    mov dword [pp_cur], path_buf

    ; ---- 2) 一段一段地进目录 ----
.next:
    mov ebx, [pp_cur]                   ; ebx = 这一段的名字(nasm 里 ebx 最"干净")
    xor ecx, ecx
.scan:
    mov al, [ebx + ecx]
    test al, al
    jz .done                            ; 到头了 → ebx 就是文件名
    cmp al, '/'
    je .split
    cmp al, 0x5C                        ; 反斜杠(NASM 里 '\\' 是两个字符,别那么写)
    je .split
    inc ecx
    jmp .scan
.split:
    lea edx, [ebx + ecx]                ; edx → 分隔符
    mov byte [edx], 0                   ; 把这一段的尾巴切掉
    mov esi, ebx
    call fat_chdir                      ; 进目录(里面会用它自己的 esi)
    jc .fail                            ; 恢复与否都要走:失败就整体失败
    lea edx, [edx + 1]                  ; 下一段
    mov [pp_cur], edx
    jmp .next
.done:
    mov eax, ebx
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.fail:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    stc
    ret

; ---------------------------------------------------------------------------
;  fat_next_cluster:[fat_cluster] → eax = 下一个簇(带一扇区 FAT 缓存)
; ---------------------------------------------------------------------------
fat_next_cluster:
    push ebx
    push ecx
    push edx
    mov eax, [fat_cluster]
    cmp byte [fat_fat32], 0
    je .m16
    shl eax, 2                          ; FAT32:每簇 4 字节
    jmp .div
.m16:
    shl eax, 1                          ; FAT16:每簇 2 字节
.div:
    xor edx, edx
    mov ecx, 512
    div ecx                             ; eax = 扇区偏移,edx = 扇区内偏移
    mov [fat_off], edx
    add eax, [fat_fat_lba]
    cmp eax, [fat_cache_lba]
    je .cached
    mov [fat_cache_lba], eax
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    cmp eax, 0
    jne .fail
.cached:
    mov esi, FAT_BUF
    add esi, [fat_off]
    cmp byte [fat_fat32], 0
    je .get16
    mov eax, [esi]
    and eax, 0x0FFFFFFF                 ; 高 4 位是保留位
    pop edx
    pop ecx
    pop ebx
    ret
.get16:
    movzx eax, word [esi]
    pop edx
    pop ecx
    pop ebx
    ret
.fail:
    mov eax, [fat_eoc]
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  fat_read_file:esi = 文件名(ASCII,0 结尾),edi = 目标缓冲区
;                返回 eax = 文件字节数,-1 = 出错/没找到
; ---------------------------------------------------------------------------
fat_read_file:
    pushad
    mov [fat_dest], edi
    call fat_find
    cmp eax, -1
    je .fail

    ; 重新读一遍找到的那个目录项,取首簇和大小
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    mov dword [fat_cache_lba], -1
    mov esi, FAT_BUF
    add esi, [fat_entry_off]
    call fat_ent_cluster
    mov [fat_cluster], eax
    mov eax, [esi + 28]
    mov [fat_size_bytes], eax

    mov ebx, [fat_dest]
.read_loop:
    mov eax, [fat_cluster]
    cmp eax, 0xFFF8                     ; 链尾(>=0xFFF8 都算结束)
    jae .done
    test eax, eax
    jz .done
    sub eax, 2
    imul eax, [fat_spc]
    add eax, [fat_data_lba]
    mov ecx, [fat_spc]
    mov edi, ebx
    call ata_read_sectors
    cmp eax, 0
    jne .fail
    mov dword [fat_cache_lba], -1
    mov eax, [fat_spc]
    shl eax, 9                          ; × 512
    add ebx, eax
    call fat_next_cluster
    mov [fat_cluster], eax
    jmp .read_loop
.done:
    popad
    mov eax, [fat_size_bytes]
    ret
.fail:
    popad
    mov eax, -1
    ret

; ---------------------------------------------------------------------------
;  fat_stat:esi = 名字 → eax = 文件大小(找不到 -1)
;  只读目录项、不搬文件内容 —— shell 的 run 用它先看一眼大小,
;  太大的程序直接拒绝,免得读到一半把字库(0x200000)盖掉。
; ---------------------------------------------------------------------------
fat_stat:
    pushad
    call fat_find
    cmp eax, -1
    je .fail
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    mov dword [fat_cache_lba], -1
    mov esi, FAT_BUF
    add esi, [fat_entry_off]
    mov eax, [esi + 28]                 ; 目录项 +28 = 文件大小
    mov [fat_stat_size], eax
    popad
    mov eax, [fat_stat_size]            ; popad 会把 eax 还原,所以从内存读回来
    ret
.fail:
    popad
    mov eax, -1
    ret

; ---------------------------------------------------------------------------
;  fat_set_entry:把 [fat_cluster] 在 FAT 里的值改成 eax(两份 FAT 都写回)
; ---------------------------------------------------------------------------
fat_set_entry:
    pushad
    mov [fat_new_val], ax
    mov [fat_new_val32], eax            ; FAT32 用整个 32 位
    mov eax, [fat_cluster]
    cmp byte [fat_fat32], 0
    je .se16
    shl eax, 2
    jmp .sediv
.se16:
    shl eax, 1
.sediv:
    xor edx, edx
    mov ecx, 512
    div ecx
    mov [fat_off], edx
    add eax, [fat_fat_lba]
    mov [fat_sector], eax

    ; 读该 FAT 扇区
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    mov esi, FAT_BUF
    add esi, [fat_off]
    cmp byte [fat_fat32], 0
    je .put16
    mov eax, [fat_new_val32]
    and eax, 0x0FFFFFFF
    mov [esi], eax                      ; 整 32 位覆盖(高 4 位保留位清掉没关系)
    jmp .put_done
.put16:
    mov ax, [fat_new_val]
    mov [esi], ax
.put_done:

    ; 写回所有 FAT 副本
    xor ebx, ebx
.copy:
    cmp ebx, [fat_nfats]
    jae .done
    mov eax, ebx
    imul eax, [fat_size]
    add eax, [fat_fat_lba]
    ; 加上"扇区在 FAT 内的偏移"
    mov edx, [fat_sector]
    sub edx, [fat_fat_lba]
    add eax, edx
    mov ecx, 1
    mov esi, FAT_BUF
    call ata_write_sectors
    inc ebx
    jmp .copy
.done:
    mov dword [fat_cache_lba], -1
    popad
    ret

; ---------------------------------------------------------------------------
;  fat_alloc_cluster:找一个空闲簇,标记成链尾(0xFFFF),返回 eax = 簇号;0 = 没空间
; ---------------------------------------------------------------------------
fat_alloc_cluster:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov eax, [fat_next_free]
    cmp eax, 2
    jae .scan
    mov eax, 2
.scan:
    mov [fat_cluster], eax
    mov eax, [fat_cluster]
    cmp byte [fat_fat32], 0
    je .al16
    shl eax, 2
    jmp .aldiv
.al16:
    shl eax, 1
.aldiv:
    xor edx, edx
    mov ecx, 512
    div ecx
    mov [fat_off], edx
    add eax, [fat_fat_lba]
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    mov esi, FAT_BUF
    ; edx = 扇区内的字节偏移;每扇区能装 512/size 个表项
    cmp byte [fat_fat32], 0
    je .look16
.look32:
    cmp edx, 512
    jae .next_sector
    mov eax, [esi + edx]
    and eax, 0x0FFFFFFF
    test eax, eax
    jz .found32
    add edx, 4
    jmp .look32
.found32:
    shr edx, 2                          ; 表项序号 = 字节偏移 / 4
    jmp .found
.look16:
    movzx eax, word [esi + edx]
    test eax, eax
    jz .found16
    add edx, 2
    cmp edx, 512
    jb .look16
    jmp .next_sector
.found16:
    shr edx, 1                          ; 表项序号 = 偏移 / 2
    jmp .found
.next_sector:
    ; 这一扇区里没有空闲簇:跳到下一扇区
    mov eax, [fat_cluster]
    cmp byte [fat_fat32], 0
    je .ns16
    add eax, 128                        ; 一扇区 128 个 32 位表项
    jmp .ns_done
.ns16:
    add eax, 256                        ; 一扇区 256 个 16 位表项
.ns_done:
    mov [fat_cluster], eax
    jmp .scan
.found:
    mov eax, [fat_cluster]
    add eax, edx
    mov [fat_cluster], eax
    mov [fat_next_free], eax
    inc dword [fat_next_free]
    mov eax, [fat_eoc]                  ; 先当链尾,链的时候再改
    call fat_set_entry
    mov eax, [fat_cluster]
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  fat_write_file:esi = 文件名,edi = 数据,ecx = 字节数
;                 返回 eax = 0 成功,-1 失败(没挂载 / 盘满)
; ---------------------------------------------------------------------------
fat_write_file:
    pushad
    mov [fat_dest], edi                 ; 数据在哪
    mov [fat_want], ecx                 ; 要写多少字节
    mov [fat_name_ptr], esi

    ; ---- 先按短名找:有就覆盖,别动它原来的名字(人家可能是长名别名) ----
    mov esi, [fat_name_ptr]
    call fat_find
    cmp eax, -1
    je .new_entry
    mov [fat_dir_lba], eax
    mov dword [wr_existing], 1
    jmp .have_entry
.new_entry:
    mov dword [wr_existing], 0
    ; 新文件:算短别名 + LFN 串(只有长名才会有 LFN 项)
    mov esi, [fat_name_ptr]
    mov edx, 0x20
    call fat_lfn_prepare
    jc .fail
    ; 找 lfn_total 个连续空位(子目录满就扩簇;根目录固定区扩不了)
    mov ecx, [lfn_total]
    mov esi, [fat_name_ptr]
    call fat_find_run
    jc .fail
    mov [fat_dir_lba], eax
.have_entry:
    ; ---- 分配簇链并把数据写进去 ----
    mov esi, [fat_dest]
    mov ecx, [fat_want]
    test ecx, ecx
    jnz .have_data
    mov ecx, 1                          ; 空文件也给一个簇(简单)
.have_data:
    mov [fat_left], ecx
    mov [fat_src], esi
    mov dword [fat_prev_cluster], 0
    mov dword [fat_first_cluster], 0
    mov eax, [fat_spc]
    shl eax, 9
    mov [fat_chunk_bytes], eax          ; 每簇多少字节
.cluster_loop:
    cmp dword [fat_left], 0
    jle .chain_done
    call fat_alloc_cluster
    test eax, eax
    jz .fail
    mov [fat_cluster], eax
    cmp dword [fat_first_cluster], 0
    jne .link
    mov [fat_first_cluster], eax        ; 记下首簇
    jmp .write_data
.link:
    ; 把上一个簇的链尾指向这个簇
    ; fat_set_entry 用 [fat_cluster] 当"要改哪一个表项",eax 当新值,
    ; 所以先存下新簇(edx),改完表项再恢复 —— 原先这里最后 mov eax,[fat_cluster]
    ; 拿到的是上一簇,导致下一簇的数据又被写回上一簇,多簇文件后半段就丢了。
    mov eax, [fat_cluster]
    mov edx, eax                        ; edx = 新簇(调用会保存 edx)
    mov eax, [fat_prev_cluster]
    mov [fat_cluster], eax
    mov eax, edx
    call fat_set_entry
    mov eax, edx                        ; eax = 新簇,下面把数据写到这里
.write_data:
    mov [fat_prev_cluster], eax
    ; 数据写到:数据区起点 + (簇 - 2) * 每簇扇区数
    mov eax, [fat_prev_cluster]
    sub eax, 2
    imul eax, [fat_spc]
    add eax, [fat_data_lba]
    mov ecx, [fat_spc]
    mov esi, [fat_src]
    call ata_write_sectors
    mov eax, [fat_chunk_bytes]
    add [fat_src], eax
    sub [fat_left], eax
    jmp .cluster_loop
.chain_done:
    ; ---- 更新目录项 ----
    mov eax, [fat_dir_lba]
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    cmp dword [wr_existing], 0
    jne .patch_short
    ; 新文件:把 N 个 LFN 项 + 短项整段拷进扇区(一次写完)
    mov edi, FAT_BUF
    add edi, [fat_entry_off]
    mov esi, lfn_entries
    mov ecx, [lfn_total]
    shl ecx, 5
    rep movsb
.patch_short:
    mov edi, FAT_BUF
    add edi, [fat_entry_off]
    cmp dword [wr_existing], 0
    jne .ps_go
    mov eax, [lfn_cnt]
    shl eax, 5
    add edi, eax                        ; 跳过 LFN 项,指向短项
.ps_go:
    mov byte [edi + 11], 0x20           ; 属性:普通文件
    ; 清掉属性后面的保留区,再从 +26 写簇号
    mov dword [edi + 12], 0
    mov dword [edi + 16], 0
    mov dword [edi + 20], 0             ; 顺便清掉 FAT32 的高位簇号
    mov eax, [fat_first_cluster]
    mov [edi + 26], ax
    cmp byte [fat_fat32], 0
    je .nc_done
    shr eax, 16
    mov [edi + 20], ax                  ; FAT32:高 16 位
.nc_done:
    mov eax, [fat_want]
    mov [edi + 28], eax
    mov eax, [fat_dir_lba]
    mov ecx, 1
    mov esi, FAT_BUF
    call ata_write_sectors
    mov dword [fat_cache_lba], -1
    popad
    xor eax, eax
    ret
.fail:
    popad
    mov eax, -1
    ret

; ---------------------------------------------------------------------------
;  fat_list:把根目录里的文件打出来(名字 + 大小)
; ---------------------------------------------------------------------------
fat_list:
    pushad
    mov eax, [fat_dir]
    test eax, eax
    jnz .cluster_init
    cmp byte [fat_fat32], 0
    jne .list32_root
    ; ---- 根目录:固定区域(FAT16) ----
    mov eax, [fat_root_lba]
    mov [fl_lba], eax
    mov eax, [fat_root_ents]
    mov [fl_ents], eax
    mov dword [fl_spc], 0               ; 0 = 固定区域,没有"下一簇"
    jmp .sector
.list32_root:
    mov eax, [fat_root_cluster]
    jmp .cluster_init
.cluster_init:
    mov [fl_clus], eax
.cluster:
    mov eax, [fl_clus]
    cmp eax, 0xFFF8                     ; 链尾
    jae .done
    test eax, eax
    jz .done
    sub eax, 2
    imul eax, [fat_spc]
    add eax, [fat_data_lba]
    mov [fl_lba], eax
    mov eax, [fat_spc]
    mov [fl_ents], eax
    shl dword [fl_ents], 4              ; 每扇区 16 个目录项
    mov [fl_spc], eax                   ; 记住这是子目录,一簇完了要接着走链
.sector:
    mov eax, [fl_ents]
    test eax, eax
    jz .run_done
    mov eax, [fl_lba]
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    mov dword [fat_cache_lba], -1
    xor ebx, ebx
.entry:
    cmp ebx, 512
    jae .next
    mov esi, FAT_BUF
    add esi, ebx
    movzx eax, byte [esi]
    test al, al
    jz .done
    cmp al, 0xE5
    je .dead
    call fat_lfn_scan
    jc .skip                            ; 长名项:收进 lfn_name,继续
    cmp byte [esi], '.'                 ; . 和 .. 不列出来(列出来太乱)
    je .short_reset
    ; ---- 前面挂了完整、校验和也对得上的 LFN 链 → 打长名 ----
    cmp dword [lfn_state], 0
    je .print83
    mov eax, [lfn_filled]
    cmp eax, [lfn_expect]
    jne .print83
    call fat_lfn_checksum               ; esi = 短项 → al
    movzx eax, al
    cmp eax, [lfn_sum]
    jne .print83
    push ebx
    mov al, COL_NORMAL
    call term_set_color
    mov esi, lfn_name
.ln_print:
    mov al, [esi]
    test al, al
    jz .ln_done
    cmp al, '?'
    je .ln_done                         ; 非 ASCII 长名:只打前面能认的部分
    call term_putc
    inc esi
    jmp .ln_print
.ln_done:
    mov dword [lfn_state], 0
    jmp .size
.short_reset:
    mov dword [lfn_state], 0
    jmp .skip
.print83:
    mov dword [lfn_state], 0
    ; 打名字(8+3)—— 8.3 的名字是空格补齐的,补的那些空格不打了
    push ebx
    mov al, COL_NORMAL
    call term_set_color
    mov edx, 8
.trim_name:
    test edx, edx
    jz .name
    mov al, [esi + edx - 1]
    cmp al, ' '
    jne .name
    dec edx
    jmp .trim_name
.name:
    xor ecx, ecx
.name_loop:
    cmp ecx, edx
    jae .name_end
    mov al, [esi + ecx]
    call term_putc
    inc ecx
    jmp .name_loop
.name_end:
    mov edx, 3
.trim_ext:
    test edx, edx
    jz .ext
    mov al, [esi + 8 + edx - 1]
    cmp al, ' '
    jne .ext
    dec edx
    jmp .trim_ext
.ext:
    test edx, edx
    jz .size                             ; 没扩展名就不打那个点
    mov al, '.'
    call term_putc
    xor ecx, ecx
.ext_loop:
    cmp ecx, edx
    jae .size
    mov al, [esi + 8 + ecx]
    call term_putc
    inc ecx
    jmp .ext_loop
.size:
    mov esi, FAT_BUF                    ; 打长名时 esi 跑掉了,重新指回短项
    add esi, ebx
    mov al, ' '
    call term_putc
    mov al, [esi + 11]
    test al, 0x10                        ; attr bit4 = 目录,不显示"大小"
    jnz .isdir
    mov eax, [esi + 28]
    call term_print_dec
    mov esi, msg_fat_bytes
    call term_print
    pop ebx
    jmp .skip
.isdir:
    mov esi, msg_fat_dir
    call term_print
    pop ebx
    jmp .skip
.dead:
    mov dword [lfn_state], 0
.skip:
    add ebx, 32
    jmp .entry
.next:
    inc dword [fl_lba]
    sub dword [fl_ents], 16
    jmp .sector
.run_done:
    cmp dword [fl_spc], 0               ; 根目录到头就是真的完了
    je .done
    mov eax, [fl_clus]                  ; 子目录:跟着簇链再进一簇
    mov [fat_cluster], eax
    call fat_next_cluster
    mov [fl_clus], eax
    jmp .cluster
.done:
    popad
    ret

; ---------------------------------------------------------------------------
;  fat_free_slot:在当前目录里找一个空目录项(0x00 或 0xE5)
;    成功:CF=0,eax = 目录项所在扇区的 LBA,[fat_entry_off] = 扇区里的偏移
;    失败:CF=1(根目录满了,或者子目录扩不出新簇)
; ---------------------------------------------------------------------------
fat_free_slot:
    pushad
    mov eax, [fat_dir]
    test eax, eax
    jnz .sub
    cmp byte [fat_fat32], 0
    jne .fs32_root
    mov eax, [fat_root_lba]
    mov [fs_lba], eax
    mov eax, [fat_root_ents]
    mov [fs_ents], eax
    mov dword [fs_spc], 0               ; 0 = 根目录,扩不了
    jmp .sect
.fs32_root:
    mov eax, [fat_root_cluster]         ; FAT32 的根也是簇链
    jmp .sub
.sub:
    mov [fs_clus], eax
.cluster:
    mov eax, [fs_clus]
    cmp eax, 0xFFF8                     ; 链尾 → 试试扩一簇
    jae .extend
    test eax, eax
    jz .extend
    sub eax, 2
    imul eax, [fat_spc]
    add eax, [fat_data_lba]
    mov [fs_lba], eax
    mov eax, [fat_spc]
    mov [fs_ents], eax
    shl dword [fs_ents], 4              ; 每扇区 16 项
    mov [fs_spc], eax
.sect:
    mov eax, [fs_ents]
    test eax, eax
    jz .extend
    mov eax, [fs_lba]
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    mov dword [fat_cache_lba], -1
    xor ebx, ebx
.entry:
    cmp ebx, 512
    jae .next
    movzx eax, byte [FAT_BUF + ebx]
    test al, al
    jz .found                           ; 0x00 = 后面全空
    cmp al, 0xE5
    je .found                           ; 0xE5 = 删掉过的
    add ebx, 32
    jmp .entry
.next:
    inc dword [fs_lba]
    sub dword [fs_ents], 16
    jmp .sect
.extend:
    cmp dword [fs_spc], 0
    je .full                            ; 根目录没有链可扩
    call fat_alloc_cluster
    test eax, eax
    jz .full
    mov [fs_new], eax
    call fat_zero_cluster               ; 新簇清零 → 第一项就是空位
    mov eax, [fs_clus]
    mov [fat_cluster], eax
    mov eax, [fs_new]
    call fat_set_entry                  ; 旧链尾 → 新簇
    mov eax, [fs_new]
    mov [fs_clus], eax
    jmp .cluster
.found:
    mov [fat_entry_off], ebx
    mov eax, [fs_lba]
    mov [fs_result], eax
    popad
    mov eax, [fs_result]
    clc
    ret
.full:
    popad
    stc
    ret

; ---------------------------------------------------------------------------
;  fat_zero_cluster:eax = 簇号 → 整簇写成 0
; ---------------------------------------------------------------------------
fat_zero_cluster:
    push eax
    push ecx
    push esi
    sub eax, 2
    imul eax, [fat_spc]
    add eax, [fat_data_lba]
    mov [zs_lba], eax
    mov ecx, [fat_spc]
.loop:
    mov eax, [zs_lba]
    mov esi, dir_zero
    push ecx
    mov ecx, 1
    call ata_write_sectors
    pop ecx
    inc dword [zs_lba]
    dec ecx
    jnz .loop
    pop esi
    pop ecx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  fat_mkdir:esi = 目录名(最后一段)→ eax = 0 成功 / -1 失败
;            在当前目录里建一个子目录,里面自动写好 . 和 ..
; ---------------------------------------------------------------------------
fat_mkdir:
    pushad
    mov [fat_name_ptr], esi
    call fat_find                       ; 0) 同名(文件或目录)就别建了,不然目录里两个同名项
    cmp eax, -1
    jne .fail
    ; 1) 算短别名 + LFN 串(长目录名才有 LFN)
    mov esi, [fat_name_ptr]
    mov edx, 0x10
    call fat_lfn_prepare
    jc .fail
    ; 2) 在父目录里找 lfn_total 个连续空位(子目录满就扩簇,根目录固定区就失败)
    mov ecx, [lfn_total]
    mov esi, [fat_name_ptr]
    call fat_find_run
    jc .fail
    mov [fat_dir_lba], eax
    call fat_alloc_cluster              ; 3) 给新目录分一簇
    test eax, eax
    jz .fail
    mov [mk_cluster], eax
    call fat_zero_cluster               ; 4) 清零
    mov eax, [mk_cluster]               ; 5) 算这一簇的第一扇区
    sub eax, 2
    imul eax, [fat_spc]
    add eax, [fat_data_lba]
    mov [mk_lba], eax
    mov byte [dir_make + 0], '.'        ; .  → 自己
    mov byte [dir_make + 11], 0x10
    mov eax, [mk_cluster]
    mov [dir_make + 26], ax
    cmp byte [fat_fat32], 0
    je .dot_done
    shr eax, 16
    mov [dir_make + 20], ax
.dot_done:
    mov byte [dir_make + 32], '.'       ; .. → 父目录(根目录是 0)
    mov byte [dir_make + 33], '.'
    mov byte [dir_make + 43], 0x10
    mov eax, [fat_dir]
    mov [dir_make + 58], ax
    cmp byte [fat_fat32], 0
    je .dotdot_done
    shr eax, 16
    mov [dir_make + 52], ax             ; FAT32:.. 的高位簇号
.dotdot_done:
    mov eax, [mk_lba]
    mov ecx, 1
    mov esi, dir_make
    call ata_write_sectors
    mov eax, [fat_dir_lba]              ; 6) 目录项写进父目录
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    mov dword [fat_cache_lba], -1
    mov edi, FAT_BUF
    add edi, [fat_entry_off]
    mov esi, lfn_entries                ; N 个 LFN 项 + 短项整段写
    mov ecx, [lfn_total]
    shl ecx, 5
    rep movsb
    mov edi, FAT_BUF
    add edi, [fat_entry_off]
    mov eax, [lfn_cnt]
    shl eax, 5
    add edi, eax                        ; 指向短项
    mov byte [edi + 11], 0x10
    mov dword [edi + 12], 0
    mov dword [edi + 16], 0
    mov dword [edi + 20], 0
    mov eax, [mk_cluster]
    mov [edi + 26], ax
    cmp byte [fat_fat32], 0
    je .mk_nc
    shr eax, 16
    mov [edi + 20], ax
.mk_nc:
    mov dword [edi + 28], 0
    mov eax, [fat_dir_lba]
    mov ecx, 1
    mov esi, FAT_BUF
    call ata_write_sectors
    popad
    xor eax, eax
    ret
.fail:
    popad
    mov eax, -1
    ret

; ---------------------------------------------------------------------------
;  fat_unlink:esi = 文件名 → eax = 0 成功 / -1 找不到 / -2 那是个目录
;
;  和 fat_rmdir 是一对:这里删的是"文件",所以
;    · 先看目录项是不是目录(attr bit4),是就退回去让调用方走 rmdir ——
;      要是这里也删,那条簇链里的子目录就全成孤儿了;
;    · 簇链照样整条标回空闲(从首簇沿 FAT 走,和 rmdir 一样的循环);
;    · 父目录里那一项首字节写 0xE5(= 已删除),这才是"文件真的不在了"的证据。
;
;  注意:目录项不首字节写 0 是有原因的 —— 0x00 表示"后面再没有表项了",
;  用 0 会把同目录后面的兄弟文件一起藏掉,只能用 0xE5。
; ---------------------------------------------------------------------------
fat_unlink:
    pushad
    call fat_find                       ; 短名/长名都能找
    cmp eax, -1
    je .fail
    mov [rm_lba], eax
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    mov dword [fat_cache_lba], -1
    mov esi, FAT_BUF
    add esi, [fat_entry_off]
    test byte [esi + 11], 0x10
    jnz .isdir                          ; 目录:请用 rmdir
    call fat_ent_cluster
    mov [rm_clus], eax
    test eax, eax
    jz .mark                            ; 空文件(首簇 0):只有目录项要清

    ; 从首簇沿链走,见一个标一个空闲 —— 和 fat_rmdir 的 .free_loop 同款
    mov [rm_scan], eax
.free_loop:
    mov eax, [rm_scan]
    test eax, eax
    jz .mark
    cmp eax, 0xFFF8
    jae .mark
    mov [fat_cluster], eax
    push eax
    call fat_next_cluster
    mov [rm_next], eax
    pop eax
    mov [fat_cluster], eax
    xor eax, eax
    call fat_set_entry
    mov eax, [rm_next]
    mov [rm_scan], eax
    jmp .free_loop

.mark:
    mov eax, [rm_lba]                   ; 父目录里那一项标成 0xE5
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    mov dword [fat_cache_lba], -1
    mov ebx, [fat_entry_off]
    mov byte [FAT_BUF + ebx], 0xE5
    ; 有 LFN 链的话,同一扇区里紧挨着的前 N 项也标成删除(跨扇区的前缀项留着,
    ; 它们校验和对不上,不会被当成有效长名)
    mov ecx, [lfn_matched]
    test ecx, ecx
    jz .mark_done
    mov eax, ebx
    shr eax, 5                          ; 这个短项前面还能放几项
    cmp ecx, eax
    jbe .mark_lfn
    mov ecx, eax
.mark_lfn:
    sub ebx, 32
    mov byte [FAT_BUF + ebx], 0xE5
    dec ecx
    jnz .mark_lfn
.mark_done:
    mov eax, [rm_lba]
    mov ecx, 1
    mov esi, FAT_BUF
    call ata_write_sectors
    popad
    xor eax, eax
    ret
.isdir:
    popad
    mov eax, -2
    ret
.fail:
    popad
    mov eax, -1
    ret

; ---------------------------------------------------------------------------
;  fat_rmdir:esi = 目录名 → eax = 0 成功 / -1 不是目录 / -2 目录不空
; ---------------------------------------------------------------------------
fat_rmdir:
    pushad
    call fat_find
    cmp eax, -1
    je .fail
    mov [rm_lba], eax
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    mov dword [fat_cache_lba], -1
    mov esi, FAT_BUF
    add esi, [fat_entry_off]
    mov al, [esi + 11]
    test al, 0x10
    jz .fail                            ; 不是目录
    call fat_ent_cluster
    mov [rm_clus], eax
    test eax, eax
    jz .fail                            ; 首簇 0 = 根,删不了
    mov [rm_scan], eax
.rs_cluster:
    mov eax, [rm_scan]
    cmp eax, 0xFFF8
    jae .empty
    test eax, eax
    jz .empty
    sub eax, 2
    imul eax, [fat_spc]
    add eax, [fat_data_lba]
    mov [rm_lba2], eax
    mov ecx, [fat_spc]
    mov [rm_count], ecx
.rs_sect:
    mov eax, [rm_lba2]
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    mov dword [fat_cache_lba], -1
    xor ebx, ebx
.rs_entry:
    cmp ebx, 512
    jae .rs_next
    movzx eax, byte [FAT_BUF + ebx]
    test al, al
    jz .empty                           ; 0x00 = 后面全空 → 目录是空的
    cmp al, 0xE5
    je .rs_skip
    cmp al, '.'
    je .rs_skip                         ; "." 和 ".."
    jmp .notempty
.rs_skip:
    add ebx, 32
    jmp .rs_entry
.rs_next:
    inc dword [rm_lba2]
    dec dword [rm_count]
    jnz .rs_sect
    mov eax, [rm_scan]                  ; 这一簇看完了,下一簇
    mov [fat_cluster], eax
    call fat_next_cluster
    mov [rm_scan], eax
    jmp .rs_cluster
.empty:
    mov eax, [rm_clus]                  ; 释放整条簇链
.free_loop:
    test eax, eax
    jz .mark
    cmp eax, 0xFFF8
    jae .mark
    mov [fat_cluster], eax
    push eax
    call fat_next_cluster
    mov [rm_next], eax
    pop eax
    mov [fat_cluster], eax
    xor eax, eax                        ; 值 0 = 空闲
    call fat_set_entry
    mov eax, [rm_next]
    jmp .free_loop
.mark:
    mov eax, [rm_lba]                   ; 父目录里那一项标成 0xE5
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    mov dword [fat_cache_lba], -1
    mov ebx, [fat_entry_off]
    mov byte [FAT_BUF + ebx], 0xE5
    ; 有 LFN 链的话,同一扇区里紧挨着的前 N 项也标成删除(跨扇区的前缀项留着,
    ; 它们校验和对不上,不会被当成有效长名)
    mov ecx, [lfn_matched]
    test ecx, ecx
    jz .mark_done
    mov eax, ebx
    shr eax, 5                          ; 这个短项前面还能放几项
    cmp ecx, eax
    jbe .mark_lfn
    mov ecx, eax
.mark_lfn:
    sub ebx, 32
    mov byte [FAT_BUF + ebx], 0xE5
    dec ecx
    jnz .mark_lfn
.mark_done:
    mov eax, [rm_lba]
    mov ecx, 1
    mov esi, FAT_BUF
    call ata_write_sectors
    popad
    xor eax, eax
    ret
.notempty:
    popad
    mov eax, -2
    ret
.fail:
    popad
    mov eax, -1
    ret

; ---------------------------------------------------------------------------
;  fat_dotdot:当前目录的父目录 → eax = 父目录首簇(0 = 根目录)
;             从当前目录第一簇里的 ".." 项读
; ---------------------------------------------------------------------------
fat_dotdot:
    push ebx
    push ecx
    push edi
    push esi
    mov eax, [fat_dir]
    test eax, eax
    jz .root
    sub eax, 2
    imul eax, [fat_spc]
    add eax, [fat_data_lba]
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    mov dword [fat_cache_lba], -1
    cmp byte [FAT_BUF + 32], '.'        ; 第二项应该就是 ..
    jne .root
    mov esi, FAT_BUF + 32
    call fat_ent_cluster
    pop esi
    pop edi
    pop ecx
    pop ebx
    ret
.root:
    xor eax, eax
    pop esi
    pop edi
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------- 数据
fat_ok          db 0
fat_bps         dd 512
fat_spc         dd 4
fat_reserved    dd 1
fat_nfats       dd 2
fat_root_ents   dd 512
fat_dir         dd 0                    ; 当前目录的首簇:0 = 根目录
fat_scan_cluster dd 0
fat_scan_sect   dd 0
pp_cur          dd 0
path_buf        times PP_MAX db 0       ; fat_path 自己抄一份路径(别去改调用方的字符串)
pp_next         dd 0
pp_sep          db 0
fat_size        dd 0
fat_fat_lba     dd 0
fat_root_lba    dd 0
fat_data_lba    dd 0
fat_cache_lba   dd -1
fat_cluster     dd 0
fat_next_free   dd 2
fat_off         dd 0
fat_new_val     dw 0
fat_sector      dd 0
fat_fat32       db 0                    ; 1 = FAT32(BPB 里 f16 的每 FAT 扇区数为 0)
fat_root_cluster dd 0                   ; FAT32 根目录首簇
fat_fsinfo      dd 0                    ; FAT32 的 FSInfo 扇区号
fat_eoc         dd 0xFFF8               ; 链尾门槛(FAT16 0xFFF8 / FAT32 0x0FFFFFF8)
fat_new_val32   dd 0
fat_scan        dd 0
fat_scan_lba    dd 0
fat_entry_off   dd 0
fat_found_lba   dd 0
fat_dest        dd 0
fat_src         dd 0
fat_left        dd 0
fat_want        dd 0
fat_size_bytes  dd 0
fat_stat_size   dd 0
fat_first_cluster dd 0
fat_prev_cluster  dd 0
fat_chunk_bytes   dd 0
fs_lba          dd 0
fs_ents         dd 0
fs_clus         dd 0
fs_spc          dd 0
fs_new          dd 0
fs_result       dd 0
zs_lba          dd 0
mk_cluster      dd 0
mk_lba          dd 0
rm_lba          dd 0
rm_lba2         dd 0
rm_clus         dd 0
rm_scan         dd 0
rm_count        dd 0
rm_next         dd 0
dir_make        times 512 db 0         ; 造新目录第一扇区用
dir_zero        times 512 db 0         ; 清零整簇用
fl_lba          dd 0
fl_ents         dd 0
fl_clus         dd 0
fl_spc          dd 0
fat_name_ptr    dd 0
fat_name        times 11 db 0
msg_fat_bytes   db ' bytes', 10, 0
msg_fat_dir     db ' <DIR>', 10, 0
fat_dir_lba     dd 0
; ---- VFAT 长名(LFN)相关 ----
lfn_req         times 256 db 0          ; fat_find 抄一份请求名(大小写不敏感比较用)
lfn_name        times 272 db 0          ; 拼起来的 LFN(最多 20 项 × 13 字符 + 结尾)
lfn_entries     times 512 db 0          ; 要写盘的一串目录项:N 个 LFN + 1 个短项
lfn_base_buf    times 32 db 0           ; 短别名的主名(非法字符已换成 '_')
lfn_ext_buf     times 16 db 0           ; 短别名的扩展名
lfn_alias_str   times 16 db 0           ; 短别名字符串("LONGNA~1.TXT")
lfn_offs        db 1,3,5,7,9,14,16,18,20,22,24,28,30
fat_legal_chars db "$%'-_@~`!(){}^#&", 0
lfn_state       dd 0                    ; 当前短项前面的 LFN 链有没有收完
lfn_expect      dd 0                    ; 这条链应该有 N 项
lfn_filled      dd 0                    ; 已经收到几项
lfn_sum         dd 0                    ; 链首项里记的短名校验和
lfn_matched     dd 0                    ; fat_find/fat_list:命中的 LFN 项数
lfn_cnt         dd 0                    ; 要写几个 LFN 项
lfn_total       dd 0                    ; lfn_cnt + 1(含短项)
lfn_attr        dd 0                    ; 短项属性(文件 0x20 / 目录 0x10)
lfn_need        dd 0
lfn_base_len    dd 0
lfn_ext_len     dd 0
lfn_dots        dd 0
lfn_alias_n     dd 0
wr_existing     dd 0                    ; fat_write_file:1 = 覆盖老目录项
frun_lba        dd 0
frun_left       dd 0                    ; 固定根目录:还剩几个扇区;子目录:簇内扇区号
frun_clus       dd 0
frun_need       dd 0
frun_new        dd 0
