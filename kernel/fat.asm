; ============================================================================
;  JoyOS (胡闹OS) — FAT16 文件系统(读 + 写)
;
;  为什么要文件系统:字库能靠"裸读固定扇区"解决(见 fontdisk.asm),但要让别人
;  往盘里扔自己的东西(文本、程序),就得有个按名字找文件的东西 —— 那就是文件系统。
;  选 FAT16 是因为它结构最简单:一张 FAT 表 + 固定大小的根目录 + 数据区。
;
;  ── FAT16 长什么样(我们只支持根目录 + 8.3 短名)────────────────────────
;      引导扇区(BPB):每扇区字节数、每簇扇区数、保留扇区数、FAT 份数、
;                     根目录项数、每张 FAT 占多少扇区 …… 挂载就是把这些读出来
;      FAT 表:每簇 2 字节。0x0000 = 空闲,0xFFFF = 链尾,其它值 = 下一个簇
;      根目录:固定大小(根目录项数 × 32 字节),每项 32 字节
;          [0..10] 名字(8+3,空格补齐)  [11] 属性  [26..27] 首簇  [28..31] 大小
;      数据区:簇 N 的扇区 = 数据区起点 + (N - 2) × 每簇扇区数
;
;  ── 两个坑 ──────────────────────────────────────────────────────────────
;   1. 每次读盘/写盘都得**重新算 LBA**,不能"记住上次读到哪"(FAT 表是随机访问的)
;   2. FAT 表被改过必须写回(而且两份 FAT 都要写),不然重启后文件就"没了"
;
;  不支持:子目录、长文件名(LFN)、删除。够跑程序就行。
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
;  fat_find:在 [fat_dir] 指向的目录里找 fat_name(11 字节 8.3 名)
;            [fat_dir] = 0 → 根目录(固定区域);否则是子目录(沿簇链找)
;            找到了返回 eax = 目录项所在的扇区 LBA,
;            [fat_entry_off] = 表项在扇区内的偏移;[fat_found_lba] 也记一份;
;            找不到返回 eax = -1
; ---------------------------------------------------------------------------
fat_find:
    pushad
    mov eax, [fat_dir]
    test eax, eax
    jz .root                            ; 0 = 根目录(固定区域)
    ; ------------------------------------------------------------------
    ;  子目录:目录本身是一条簇链,一簇一簇地读
    ;  (FAT32 的根目录也走这条路 —— 它的"根"就是一条从 root_cluster 起的簇链)
    ; ------------------------------------------------------------------
    mov [fat_scan_cluster], eax
.ccluster:
    mov eax, [fat_scan_cluster]
    cmp eax, 0xFFF8                     ; 链尾
    jae .not_found
    test eax, eax
    jz .not_found
    sub eax, 2
    imul eax, [fat_spc]
    add eax, [fat_data_lba]
    mov [fat_scan_lba], eax             ; 这一簇的第一扇区
    mov dword [fat_scan_sect], 0
.csector:
    mov eax, [fat_scan_sect]
    cmp eax, [fat_spc]
    jae .cnext
    mov eax, [fat_scan_lba]
    add eax, [fat_scan_sect]
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    cmp eax, 0
    jne .not_found
    mov dword [fat_cache_lba], -1
    xor ebx, ebx
.centry:
    cmp ebx, 512
    jae .cdone
    mov esi, FAT_BUF
    add esi, ebx
    movzx eax, byte [esi]
    test al, al
    jz .not_found                       ; 0 = 后面都是空的
    cmp al, 0xE5
    je .cskip
    mov al, [esi + 11]
    and al, 0x0F
    cmp al, 0x0F
    je .cskip                           ; 长文件名项
    mov edi, fat_name
    mov ecx, 11
    push esi
.ccmp:
    mov al, [esi]
    cmp al, [edi]
    jne .cdiff
    inc esi
    inc edi
    dec ecx
    jnz .ccmp
    pop esi
    mov [fat_entry_off], ebx
    mov eax, [fat_scan_lba]
    add eax, [fat_scan_sect]
    mov [fat_found_lba], eax
    popad
    mov eax, [fat_found_lba]
    ret
.cdiff:
    pop esi
.cskip:
    add ebx, 32
    jmp .centry
.cdone:
    inc dword [fat_scan_sect]
    jmp .csector
.cnext:
    mov eax, [fat_scan_cluster]
    mov [fat_cluster], eax
    call fat_next_cluster
    mov [fat_scan_cluster], eax
    jmp .ccluster

.root:
    mov dword [fat_scan], 0             ; 已经看过几个目录项
    mov eax, [fat_root_lba]
    mov [fat_scan_lba], eax
.sector:
    mov eax, [fat_scan]
    cmp eax, [fat_root_ents]
    jae .not_found
    mov eax, [fat_scan_lba]
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    cmp eax, 0
    jne .not_found
    mov dword [fat_cache_lba], -1       ; 冲掉了 FAT_BUF 的 FAT 缓存

    xor ebx, ebx                        ; 扇区内的表项偏移
.entry:
    cmp dword [fat_scan], 0
    ; 每扇区 16 个表项(512 / 32)
    cmp ebx, 512
    jae .next_sector
    mov esi, FAT_BUF
    add esi, ebx
    movzx eax, byte [esi]
    test al, al
    jz .not_found                       ; 0 = 后面都是空的
    cmp al, 0xE5
    je .skip                            ; 已删除
    mov al, [esi + 11]
    and al, 0x0F
    cmp al, 0x0F
    je .skip                            ; 长文件名项(LFN),跳过
    ; 比较 11 字节名字
    mov edi, fat_name
    mov ecx, 11
    push esi
.cmp:
    mov al, [esi]
    cmp al, [edi]
    jne .diff
    inc esi
    inc edi
    dec ecx
    jnz .cmp
    pop esi
    ; 找到了
    mov [fat_entry_off], ebx
    mov eax, [fat_scan_lba]
    mov [fat_found_lba], eax
    popad
    mov eax, [fat_found_lba]
    ret
.diff:
    pop esi
.skip:
    add ebx, 32
    inc dword [fat_scan]
    jmp .entry
.next_sector:
    inc dword [fat_scan_lba]
    jmp .sector
.not_found:
    popad
    mov eax, -1
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
    call fat_name83                     ; esi → 11 字节 8.3 名(fat_name)
    call fat_find
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
    movzx eax, word [esi + 26]          ; 目录自己的首簇
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
;  说明:进目录靠改 [fat_dir],所以调用前请先把 [fat_dir] 清 0(从根开始)
; ---------------------------------------------------------------------------
fat_path:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov [pp_cur], esi
.next:
    mov esi, [pp_cur]
    xor ecx, ecx
.scan:
    mov al, [esi + ecx]
    test al, al
    jz .done                            ; 没有分隔符了 → 剩下这截就是文件名
    cmp al, '/'
    je .split
    cmp al, 0x5C                        ; 反斜杠(NASM 里 '\\' 是两个字符,别那么写)
    je .split
    inc ecx
    jmp .scan
.split:
    mov edi, esi
    add edi, ecx                        ; edi → 分隔符
    mov al, [edi]
    mov [pp_sep], al
    mov [pp_next], edi
    mov byte [edi], 0                   ; 临时把"DIR/FILE"切成 "DIR"
    mov esi, [pp_cur]
    call fat_chdir
    pushf
    mov edi, [pp_next]
    mov al, [pp_sep]
    mov [edi], al                       ; 恢复原来的分隔符
    popf
    jc .fail
    lea eax, [edi + 1]                  ; 下一段
    mov [pp_cur], eax
    jmp .next
.done:
    mov eax, [pp_cur]
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
    shl eax, 1                          ; 每簇在 FAT 里占 2 字节
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
    movzx eax, word [esi]
    pop edx
    pop ecx
    pop ebx
    ret
.fail:
    mov eax, 0xFFFF
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
    call fat_name83
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
    movzx eax, word [esi + 26]
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
    call fat_name83
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
    mov eax, [fat_cluster]
    shl eax, 1
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
    mov ax, [fat_new_val]
    mov [esi], ax

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
    shl eax, 1
    xor edx, edx
    mov ecx, 512
    div ecx
    mov [fat_off], edx
    add eax, [fat_fat_lba]
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    mov esi, FAT_BUF
.look:
    movzx eax, word [esi + edx]
    test eax, eax
    jz .found
    add edx, 2
    cmp edx, 512
    jb .look
    ; 这一扇区里没有空闲簇:下一扇区
    mov eax, [fat_cluster]
    add eax, 256                        ; 一扇区 256 个 16 位表项
    mov [fat_cluster], eax
    jmp .scan
.found:
    mov eax, [fat_cluster]
    add eax, edx
    shr edx, 1                          ; 表项序号 = 偏移 / 2
    mov [fat_cluster], eax
    mov [fat_next_free], eax
    inc dword [fat_next_free]
    mov eax, 0xFFFF                     ; 先当链尾,链的时候再改
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
    ; 名字转 8.3(注意 esi 会被 lodsb 用掉,先存)
    mov [fat_name_ptr], esi
    mov esi, [fat_name_ptr]
    call fat_name83

    ; 找同名文件:有就沿用它的目录项(直接覆盖),没有就找空位
    call fat_find
    cmp eax, -1
    je .new_entry
    mov [fat_dir_lba], eax
    jmp .have_entry
.new_entry:
    ; 找第一个空表项(0x00 或 0xE5)
    mov dword [fat_scan], 0
    mov eax, [fat_root_lba]
    mov [fat_scan_lba], eax
.scan_sector:
    mov eax, [fat_scan]
    cmp eax, [fat_root_ents]
    jae .fail
    mov eax, [fat_scan_lba]
    mov ecx, 1
    mov edi, FAT_BUF
    call ata_read_sectors
    xor ebx, ebx
.scan_entry:
    cmp ebx, 512
    jae .scan_next
    mov esi, FAT_BUF
    add esi, ebx
    movzx eax, byte [esi]
    test al, al
    jz .free_slot
    cmp al, 0xE5
    je .free_slot
    add ebx, 32
    jmp .scan_entry
.scan_next:
    inc dword [fat_scan_lba]
    jmp .scan_sector
.free_slot:
    mov [fat_entry_off], ebx
    mov eax, [fat_scan_lba]
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
    mov eax, [fat_cluster]
    push eax
    mov eax, [fat_prev_cluster]
    mov [fat_cluster], eax
    pop eax
    call fat_set_entry
    mov eax, [fat_cluster]
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
    mov edi, FAT_BUF
    add edi, [fat_entry_off]
    mov esi, fat_name
    mov ecx, 11
    rep movsb                           ; 名字
    mov byte [edi], 0x20                ; 属性:普通文件
    ; 清掉属性后面的保留区,再从 +26 写簇号
    mov edi, FAT_BUF
    add edi, [fat_entry_off]
    mov dword [edi + 12], 0
    mov dword [edi + 16], 0
    mov dword [edi + 20], 0
    mov ax, [fat_first_cluster]
    mov [edi + 26], ax
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
    mov dword [fat_scan], 0
    mov eax, [fat_root_lba]
    mov [fat_scan_lba], eax
.sector:
    mov eax, [fat_scan]
    cmp eax, [fat_root_ents]
    jae .done
    mov eax, [fat_scan_lba]
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
    je .skip
    mov al, [esi + 11]
    and al, 0x0F
    cmp al, 0x0F
    je .skip
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
    mov al, ' '
    call term_putc
    mov eax, [esi + 28]
    call term_print_dec
    mov esi, msg_fat_bytes
    call term_print
    pop ebx
.skip:
    add ebx, 32
    inc dword [fat_scan]
    jmp .entry
.next:
    inc dword [fat_scan_lba]
    jmp .sector
.done:
    popad
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
fat_name_ptr    dd 0
fat_name        times 11 db 0
msg_fat_bytes   db ' bytes', 10, 0
fat_dir_lba     dd 0
