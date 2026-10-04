; ============================================================================
;  JoyOS (胡闹OS) — 引导扇区
;
;  职责(只有四件事,512 字节很紧,别塞别的):
;    1. 接住 BIOS 给的启动盘号(DL)
;    2. **多扇区**把内核从 LBA 1 读到 0x10000
;    3. 建 GDT、置 CR0.PE,进 32 位保护模式
;    4. 跳到内核,并告诉它走的是哪种读盘方式
;
;  ── 为什么要写两种读盘方式?(实测踩出来的) ─────────────────────────────
;  tests/probe_disk.asm 在 QEMU 上问出来的结果:
;     读法                软盘(-fda)              硬盘(-hda)
;     AH=42h LBA 8 扇区   CF=1 AH=01 不支持       CF=0 数据正确
;     AH=02h CHS 1 扇区   CF=0 数据正确           CF=1 AH=20 几何不对
;     AH=41h EDD 探测     CF=1(老实说不支持)      CF=0
;  也就是说:软盘的 BIOS 根本不认 LBA 扩展读(AH=01 = 功能无效),
;  硬盘才认。所以正确姿势是先问 AH=41h,认就用 LBA,不认就退回 CHS。
;  只写 LBA 的话,一挂到软盘就"读盘失败"——这坑我替你踩过了。
;
;  CHS 的坑还有一个:一次读不能跨磁道,所以每次都要按"本磁道还剩几扇区"截断。
;
;  构建: nasm -f bin boot/boot.asm -o build/boot.bin
;  组装: 见 tools/mkimg.py
; ============================================================================

[BITS 16]
[ORG 0x7C00]

KERNEL_LBA   equ 1                  ; 内核从第 1 扇区开始
KERNEL_SECTS equ 64                 ; 最多读 64 扇区 = 32 KiB
KERNEL_ADDR  equ 0x10000            ; 内核加载到 64 KiB 处
CHUNK        equ 8                  ; 每次最多读 8 扇区(别贪多,有些 BIOS 会挂)

%if (KERNEL_SECTS % CHUNK) != 0
    %error "KERNEL_SECTS 必须是 CHUNK 的整数倍(最后一块要刚好读完)"
%endif

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00                  ; 栈往下长,不会压到引导扇区自己
    sti
    mov [boot_drive], dl            ; BIOS 把启动盘号放 DL,先存下来

    mov ax, 0x0003                  ; 清屏 + 80x25 文本模式
    int 0x10
    mov si, msg_boot
    call print16

    ; ---- 问 BIOS:这个盘支持 LBA 扩展读写吗?(AH=41h) ----
    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, [boot_drive]
    int 0x13
    jc .no_edd
    cmp bx, 0xAA55                  ; 应答必须是 0xAA55
    jne .no_edd
    test cx, 1                      ; CX 的 bit0 = 支持扩展读写
    jz .no_edd
    mov byte [use_lba], 1

.no_edd:
    ; CHS 退回时要用几何参数:默认按 1.44MB 软盘(18 扇区/磁道,2 磁头)
    mov word [spt], 18
    mov word [heads], 2
    cmp byte [boot_drive], 0x80
    jb .go
    mov word [spt], 63              ; 是老硬盘:63 扇区/磁道,16 磁头
    mov word [heads], 16

.go:
    xor ax, ax                      ; 刚才的 int 0x13 可能动过 DS/ES,保险起见归零
    mov ds, ax
    mov es, ax

    ; ---- 多扇区读盘:分块循环 ----
    mov dword [dap_lba], KERNEL_LBA
    mov word [dap_seg], 0x1000      ; 目标段:0x1000:0000 = 0x10000
    mov cx, KERNEL_SECTS / CHUNK    ; 分 KERNEL_SECTS/CHUNK 块读完

.read_loop:
    push cx                         ; int 0x13 会毁 CX,先存着
    mov word [io_count], CHUNK      ; 本次最多读 CHUNK 扇区

    mov di, 3                       ; 失败重试 3 次
.retry:
    call read_chunk                 ; 底层读(read_chunk 可能把 io_count 改小)
    jnc .ok
    xor ah, ah                      ; AH=0 复位磁盘控制器,再试
    mov dl, [boot_drive]
    int 0x13
    dec di
    jnz .retry
    mov si, msg_fail
    call print16
    jmp halt16

.ok:
    movzx eax, word [io_count]      ; 实读扇区数(CHS 退回时可能比 CHUNK 少)
    add dword [dap_lba], eax        ; LBA 往后推
    shl eax, 9                      ; 扇区数 × 512 = 字节数
    shr eax, 4                      ; ÷16 = 段增量(偏移恒为 0)
    add [dap_seg], ax               ; 目标段往后推
    pop cx
    loop .read_loop

    ; ---- 进保护模式 ----
    cli
    lgdt [gdt_desc]
    mov eax, cr0
    or  eax, 1                      ; CR0.PE = 1
    mov cr0, eax
    jmp CODE_SEG:pm_start

; ---------------------------------------------------------------------------
;  底层读一次:按当前 [dap_lba]/[io_count]/[dap_seg] 读,由 use_lba 决定用哪种
;  返回:CF=0 成功(io_count = 实读扇区数);CF=1 失败(AH = BIOS 错误码)
; ---------------------------------------------------------------------------
read_chunk:
    cmp byte [use_lba], 0
    je .chs

    ; ---------------- 路 1:EDD / LBA 扩展读(AH=42h)----------------
    mov ax, [io_count]
    mov [dap_count], ax
    mov si, dap
    mov ah, 0x42
    mov dl, [boot_drive]
    int 0x13
    ret

    ; ---------------- 路 2:CHS(AH=02h)----------------
.chs:
    mov eax, [dap_lba]
    xor edx, edx
    movzx ebx, word [spt]
    div ebx                         ; eax=磁道号 edx=磁道内扇区(0 起)
    mov [sec0], dl
    xor edx, edx
    movzx ebx, word [heads]
    div ebx                         ; eax=柱面号 edx=磁头号

    mov dh, dl                      ; DH = 磁头
    mov dl, [boot_drive]            ; DL = 驱动器(注意:要在取完磁头之后)
    mov ch, al                      ; CH = 柱面号低 8 位
    mov cl, ah                      ; CL = 柱面号高 2 位 → bit7-6
    and cl, 0x03
    shl cl, 6
    mov al, [sec0]
    inc al                          ; 扇区号从 1 开始
    or  cl, al                      ; CL = 柱面高2位 | 扇区号
    mov al, [io_count]              ; AL = 本次读几扇区

    ; 一次不能跨磁道:截断到"本磁道剩余扇区数"
    movzx ebx, word [spt]
    movzx eax, byte [sec0]
    sub ebx, eax                    ; ebx = 本磁道还剩几扇区
    mov ax, [io_count]
    cmp ax, bx
    jbe .cnt_ok
    mov ax, bx
.cnt_ok:
    mov [io_count], ax              ; 实读扇区数
    mov es, [dap_seg]
    mov bx, 0                       ; ES:BX = 目标地址
    mov ah, 0x02
    int 0x13
    ret

; ---------------------------------------------------------------------------
;  16 位工具
; ---------------------------------------------------------------------------
print16:
    push ax
    push bx
    push si
.next:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0E                    ; BIOS 电传打字输出(会改 AH,所以别指望 AH 还在)
    mov bx, 0x0007
    int 0x10
    jmp .next
.done:
    pop si
    pop bx
    pop ax
    ret

halt16:
    hlt
    jmp halt16

; ---------------------------------------------------------------- GDT
align 8
gdt_start:
    dq 0x0000000000000000            ; null 描述符
gdt_code:                            ; base=0 limit=4G
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10011010b                     ; P=1 DPL=0 S=1 type=1010
    db 11001111b                     ; G=1 D/B=1 L=0 limit=1111
    db 0x00
gdt_data:
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10010010b                     ; type=0010 可写
    db 11001111b
    db 0x00
gdt_end:
gdt_desc:
    dw gdt_end - gdt_start - 1
    dd gdt_start

CODE_SEG equ gdt_code - gdt_start
DATA_SEG equ gdt_data - gdt_start

; ---------------------------------------------------------------- 数据
msg_boot db 'JoyOS boot: reading kernel...', 13, 10, 0
msg_fail db 'READ FAIL', 13, 10, 0

boot_drive db 0
use_lba    db 0
sec0       db 0
spt        dw 18
heads      dw 2
io_count   dw 0

; Disk Address Packet(AH=42h 用,16 字节)
align 4
dap:
    db 0x10                          ; 结构大小
    db 0
dap_count:
    dw 1                             ; 读几个扇区
dap_off:
    dw 0x0000                        ; 目标偏移
dap_seg:
    dw 0x1000                        ; 目标段
dap_lba:
    dq 1                             ; 起始 LBA(小端 64 位)
    times 16 - ($ - dap) db 0

; ---------------------------------------------------------------- 32 位
[BITS 32]
pm_start:
    mov ax, DATA_SEG
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, 0x90000                 ; 栈搬到内核上方,别踩到内核
    mov eax, KERNEL_SECTS            ; 参数 1:内核区扇区数
    mov ebx, KERNEL_LBA              ; 参数 2:内核起始 LBA
    movzx ecx, byte [use_lba]        ; 参数 3:1=LBA/EDD 0=CHS 退回
    jmp KERNEL_ADDR

    times 510 - ($ - $$) db 0
    dw 0xAA55
