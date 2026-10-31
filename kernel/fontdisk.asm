; ============================================================================
;  JoyOS — 从磁盘加载完整字库
;
;  为什么要有这个:内建字库得塞进 64 KiB 的内核区,只能放几百个字;
;  磁盘上的字库不受这个限制(font/full-joyf.bin 有 4 万个字形、1.7 MB),
;  启动时用 ATA PIO 读进内存就行 —— 地址由 kernel/kmain.asm 运行时算:
;  恒等映射顶部 ident-2 MiB 的 2 MiB 槽(恒等映射范围内,读到那儿就能直接当指针用)。
;  页池顶端也停在字库槽下界,不会把字形页发出去。
;
;  盘上布局(mkimg.py 摆的):
;      LBA 2047     描述块:magic 'JFD1' + 字库 LBA + 扇区数 + 字节数
;      LBA 2048 起  字库本体(JOYF 格式,和内建的那个一样)
;
;  读不成(比如从软盘启动、或者镜像里没放字库)就退回内建子集,不影响启动。
; ============================================================================

FONT_DESC_LBA  equ 2047
; ★ 实际加载地址运行时定(kernel/kmain.asm 算):字库放在恒等映射顶部 ident-2 MiB 的槽里。
;   下面这两个常量只当**静态兜底值**——shell.asm 的 PROG_MAX_SIZE 和离线布局检查
;   还拿它当"字库至少不会低于 0x200000"的保守值用。
FONT_LOAD_ADDR equ 0x200000
FONT_TMP_ADDR  equ 0x1F0000

; ---------------------------------------------------------------------------
;  font_load_from_disk:启动盘是硬盘的话,把字库读进内存
; ---------------------------------------------------------------------------
font_load_from_disk:
    pushad
    mov eax, [BOOTINFO + 72]            ; 启动盘号(引导扇区填的)
    cmp eax, 0x80
    jb .keep_builtin                    ; 0x80 起才是硬盘;软盘(0x00)没这东西
    mov [ata_drive], al

    ; ---- 1) 读描述块 ----
    mov eax, FONT_DESC_LBA
    mov ecx, 1
    mov edi, [font_tmp_addr]
    call ata_read_sectors
    cmp eax, 0
    jne .keep_builtin
    mov esi, [font_tmp_addr]
    cmp dword [esi], 0x3144464A         ; 'JFD1'
    jne .keep_builtin

    ; ---- 2) 按描述块读字库本体 ----
    mov eax, [esi + 4]                  ; 字库起始 LBA
    mov ecx, [esi + 8]                  ; 扇区数
    mov edi, [font_load_addr]
    call ata_read_sectors
    cmp eax, 0
    jne .keep_builtin

    ; ---- 3) 校验 JOYF 头,确认读到的真是字库 ----
    mov esi, [font_load_addr]
    cmp dword [esi], 0x46594F4A         ; 'JOYF'
    jne .keep_builtin
    mov eax, [esi + 8]                  ; 字形数
    mov [font_glyphs], eax
    mov eax, [font_load_addr]
    mov [font_base], eax
    mov dword [font_from_disk], 1
    popad
    ret

.keep_builtin:
    mov eax, [font_blob + 8]
    mov [font_glyphs], eax
    mov dword [font_base], font_blob
    mov dword [font_from_disk], 0
    popad
    ret

font_base       dd font_blob            ; 字形表基址(fb_glyph 用它)
font_from_disk  dd 0
font_glyphs     dd 0
