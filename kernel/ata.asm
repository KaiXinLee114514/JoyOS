; ============================================================================
;  JoyOS (胡闹OS) — ATA(IDE 硬盘)PIO 驱动(读 + 写)
;
;  为什么用 ATA 不用软驱:
;    软驱(FDC,0x3F0)要配 DMA、管马达、等转速,几百行还容易挂;
;    ATA 就是"往几个端口写参数 → 搬 0x1F0 的数据口",几十行就能跑。
;    我们的镜像本来就能当硬盘挂(-hda 那条测试路径),这条路现成的。
;
;  LBA28 读一个扇区:
;    1. 选盘 + LBA 高 4 位 → 0x1F6(0xE0 = 主盘 LBA 模式,0xF0 = 从盘)
;    2. 扇区数 → 0x1F2;LBA 低 24 位 → 0x1F3/0x1F4/0x1F5
;    3. 命令 → 0x1F7(读 = 0x20,写 = 0x30)
;    4. 等状态寄存器:BSY(bit7) 清掉、DRQ(bit3) 置起来
;    5. 从 0x1F0 搬 256 次 16 位 = 512 字节
;  写的时候每写一个端口要等约 400ns(读状态口四次就行),不然老硬盘会丢字节;
;  写完还要发 0xE7(FLUSH CACHE)让它把缓存落盘。
; ============================================================================

ATA_DATA    equ 0x1F0
ATA_SECCNT  equ 0x1F2
ATA_LBA_LO  equ 0x1F3
ATA_LBA_MID equ 0x1F4
ATA_LBA_HI  equ 0x1F5
ATA_DRIVE   equ 0x1F6
ATA_STATUS  equ 0x1F7
ATA_CMD     equ 0x1F7

ATA_SR_BSY  equ 0x80                    ; 忙
ATA_SR_DRQ  equ 0x08                    ; 数据就绪
ATA_SR_ERR  equ 0x01                    ; 出错

ATA_TIMEOUT equ 0x000FFFFF
; 一次命令最多读多少扇区:255 是硬件上限,但实测 QEMU 一次 255 扇区会有部分传输
; (ATA 规范允许驱动器只传一部分),于是后面的数据变成 0。16 扇区=8 KB 很稳。
ATA_MAX_CHUNK equ 16

; ---------------------------------------------------------------------------
;  ata_delay400:约 400ns(端口 I/O 本身就有延迟,读四次状态口足够)
; ---------------------------------------------------------------------------
ata_delay400:
    push eax
    push edx
    mov dx, ATA_STATUS
    in al, dx
    in al, dx
    in al, dx
    in al, dx
    pop edx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  ata_wait_ready:等 BSY 清;返回 CF=1 表示超时
; ---------------------------------------------------------------------------
ata_wait_ready:
    push eax
    push ecx
    push edx
    mov ecx, ATA_TIMEOUT
.loop:
    mov dx, ATA_STATUS
    in  al, dx
    test al, ATA_SR_BSY
    jz .ok
    loop .loop
    pop edx
    pop ecx
    pop eax
    stc
    ret
.ok:
    pop edx
    pop ecx
    pop eax
    clc
    ret

; ---------------------------------------------------------------------------
;  ata_wait_drq:等 DRQ(数据就绪);顺便看一眼 ERR。CF=1 = 出错/超时
; ---------------------------------------------------------------------------
ata_wait_drq:
    push eax
    push ecx
    push edx
    mov ecx, ATA_TIMEOUT
.loop:
    mov dx, ATA_STATUS
    in  al, dx
    test al, ATA_SR_ERR
    jnz .fail
    test al, ATA_SR_DRQ
    jnz .ok
    loop .loop
.fail:
    pop edx
    pop ecx
    pop eax
    stc
    ret
.ok:
    pop edx
    pop ecx
    pop eax
    clc
    ret

; ---------------------------------------------------------------------------
;  ata_setup_lba:按 [ata_lba] 选盘、填 LBA 三个端口
; ---------------------------------------------------------------------------
ata_setup_lba:
    push eax
    push ebx
    push edx
    mov eax, [ata_lba]

    mov ebx, eax
    shr ebx, 24
    and bl, 0x0F
    or  bl, 0xE0                        ; LBA 模式;bit4 = 主/从盘
    mov al, [ata_drive]
    and al, 1
    shl al, 4
    or  bl, al
    mov dx, ATA_DRIVE
    mov al, bl
    out dx, al
    call ata_delay400

    mov dx, ATA_SECCNT
    mov al, [ata_chunk]                 ; 本次读几个扇区(最多 255)
    out dx, al

    mov eax, [ata_lba]                  ; ★ 必须重新取:上面 `mov al, ...` 已经把 EAX 改花了
    mov ebx, eax                        ; LBA 低 24 位
    mov dx, ATA_LBA_LO
    mov al, bl
    out dx, al
    shr ebx, 8
    mov dx, ATA_LBA_MID
    mov al, bl
    out dx, al
    shr ebx, 8
    mov dx, ATA_LBA_HI
    mov al, bl
    out dx, al

    pop edx
    pop ebx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  ata_read_sectors:eax = LBA,ecx = 扇区数,edi = 目标地址;返回 eax = 0 成功 / -1 失败
; ---------------------------------------------------------------------------
ata_read_sectors:
    mov [ata_lba], eax
    mov [ata_buf], edi
    mov [ata_left], ecx
.loop:
    cmp dword [ata_left], 0
    je .done
    ; 本次读几块:最多 255 扇区(ATA 的 SECCNT 是 8 位,0 表示 256)
    mov eax, [ata_left]
    cmp eax, ATA_MAX_CHUNK
    jbe .use_it
    mov eax, ATA_MAX_CHUNK
.use_it:
    mov [ata_chunk], al
    call ata_setup_lba
    mov dx, ATA_CMD
    mov al, 0x20                        ; READ SECTORS
    out dx, al
    ; ★ 关键:多扇区 PIO **不能一口气读完** —— 驱动器每传完一个扇区会重新拉 DRQ,
    ;   必须每个扇区等一次 DRQ 再搬 256 个 16 位。整块硬读的话只有头一个扇区是对的,
    ;   后面的数据是零/旧数据(这个坑踩了一轮)。
    mov edi, [ata_buf]
    movzx ebp, byte [ata_chunk]
.sector:
    call ata_wait_drq
    jc .fail
    mov ecx, 256
    mov dx, ATA_DATA
    rep insw
    dec ebp
    jnz .sector
    movzx eax, byte [ata_chunk]
    add [ata_lba], eax
    imul eax, 512
    add [ata_buf], eax
    movzx eax, byte [ata_chunk]
    sub [ata_left], eax
    jmp .loop
.done:
    xor eax, eax
    ret
.fail:
    mov eax, -1
    ret

; ---------------------------------------------------------------------------
;  ata_write_sectors:eax = LBA,ecx = 扇区数,esi = 源地址;返回 eax = 0 / -1
;  注意:写盘是真写 —— 拿镜像的副本试,别拿唯一的镜像练手
; ---------------------------------------------------------------------------
ata_write_sectors:
    mov [ata_lba], eax
    mov [ata_src], esi
    mov [ata_left], ecx
.loop:
    cmp dword [ata_left], 0
    je .flush
    mov eax, [ata_left]
    cmp eax, ATA_MAX_CHUNK
    jbe .use_it_w
    mov eax, ATA_MAX_CHUNK
.use_it_w:
    mov [ata_chunk], al
    call ata_setup_lba
    mov dx, ATA_CMD
    mov al, 0x30                        ; WRITE SECTORS
    out dx, al
    ; 写也一样:每个扇区等一次 DRQ(而且每写一个扇区要留 400ns)
    mov esi, [ata_src]
    movzx ebp, byte [ata_chunk]
.sector_w:
    call ata_wait_drq
    jc .fail
    mov ecx, 256
    mov dx, ATA_DATA
    rep outsw
    call ata_delay400
    dec ebp
    jnz .sector_w
    movzx eax, byte [ata_chunk]
    add [ata_lba], eax
    imul eax, 512
    add [ata_src], eax
    movzx eax, byte [ata_chunk]
    sub [ata_left], eax
    jmp .loop
.flush:
    mov dx, ATA_CMD
    mov al, 0xE7                        ; FLUSH CACHE
    out dx, al
    call ata_wait_ready
    xor eax, eax
    ret
.fail:
    mov eax, -1
    ret

; ---------------------------------------------------------------- 变量
ata_lba    dd 0
ata_buf    dd 0
ata_src    dd 0
ata_left   dd 0
ata_chunk  db 1
ata_drive  db 0x80                      ; 0x80 = 主盘,0x81 = 从盘(fontdisk 会按 BOOTINFO 设)
