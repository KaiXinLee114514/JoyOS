; ============================================================================
;  JoyOS (胡闹OS) — 引导扇区(只有 512 字节,所以只管最要紧的事)
;
;  干四件事:
;    1. 存下 BIOS 给的启动盘号(DL)
;    2. 探测 BIOS 支不支持 LBA 扩展读,选一条路把内核搬进 0x10000
;    3. 把启动参数写进 BOOTINFO(固定地址 0x8000),给内核读
;    4. 跳到 0x10000 —— 那里是内核镜像开头的**实模式 stub**
;
;  为什么把 GDT/进入保护模式/VBE 都挪走了:
;    512 字节实在太小。现在这些都在内核镜像开头的 stub 里(见 kernel/stub.asm),
;    stub 有几十 KB 可用,而且能调 BIOS(VBE 必须实模式才能问)。
;    引导扇区因此反而简单了:读完盘就直接跳过去。
;
;  ── 读盘:两条路(实测得出的,见 README 第 4 节) ──────────────────────
;    支持 EDD 的盘(硬盘):AH=42h LBA 一次读 8 扇区
;    不支持(软盘):AH=02h CHS,而且每次都要按"本磁道还剩几扇区"截断
;
;  构建: nasm -f bin boot/boot.asm -o build/boot.bin
; ============================================================================

[BITS 16]
[ORG 0x7C00]

STUB_LBA     equ 1                  ; 实模式 stub 在第 1 扇区
STUB_SECTS   equ 4                  ; 最多 2 KB
STUB_ADDR    equ 0x0500             ; 搬到 0x500,用 CS=0 的近跳进去

KERNEL_LBA   equ 5                  ; 32 位内核从第 5 扇区开始
KERNEL_SECTS equ 256                ; 128 KiB 内核区(图形模式 + 字库 + C 程序 + 目录代码都要地方)
KERNEL_SEG   equ 0x1000             ; 内核加载在 0x1000:0000 = 0x10000
CHUNK        equ 8
BOOTINFO     equ 0x8000             ; 启动参数块(内核读它)

%if (KERNEL_SECTS % CHUNK) != 0
    %error "KERNEL_SECTS 必须是 CHUNK 的整数倍"
%endif
%if STUB_SECTS > CHUNK
    %error "STUB_SECTS 超过 CHUNK 时要改成分块读"
%endif
%if (STUB_ADDR % 16) != 0
    %error "STUB_ADDR 必须 16 字节对齐(要当段地址用)"
%endif

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    mov [boot_drive], dl

    ; ---- 启动参数块头部 ----
    mov dword [BOOTINFO], 0x4F4F424A     ; 'JBOO'
    mov dword [BOOTINFO + 4], KERNEL_SECTS
    mov dword [BOOTINFO + 8], KERNEL_LBA
    mov dword [BOOTINFO + 68], STUB_SECTS
    movzx eax, byte [boot_drive]
    mov [BOOTINFO + 72], eax            ; 启动盘号(0x80 起 = 硬盘,内核据此决定要不要读盘)

    mov ax, 0x0003
    int 0x10

    ; ---- 问 BIOS 支不支持 LBA ----
    ; ★ 软盘(dl < 0x80)不许走这条路:BIOS 对软盘也常报"支持 EDD",但软盘的
    ;   EDD 读**跨磁道就失败**(1.44 MB 每磁道 18 扇区,一次读 8 扇区很容易跨),
    ;   结果是引导扇区读盘失败 → 停机,屏幕全黑(踩过)。
    ;   软盘老老实实走 CHS:下面的 CHS 分支会自动把一次读的量卡在磁道边界上。
    cmp byte [boot_drive], 0x80
    jb .no_edd
    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, [boot_drive]
    int 0x13
    jc .no_edd
    cmp bx, 0xAA55
    jne .no_edd
    test cx, 1
    jz .no_edd
    mov byte [use_lba], 1

.no_edd:
    mov word [spt], 18                  ; 默认按 1.44MB 软盘几何
    mov word [heads], 2
    cmp byte [boot_drive], 0x80
    jb .go
    mov word [spt], 63                  ; 是老硬盘
    mov word [heads], 16

.go:
    xor ax, ax
    mov ds, ax
    mov es, ax
    movzx eax, byte [use_lba]
    mov [BOOTINFO + 12], eax            ; 1 = LBA/EDD,0 = CHS

    ; ---- 先把实模式 stub 搬到 0x500 ----
    ; 注意:stub 只有 4 扇区,比分块读的 CHUNK(8)小,所以必须**一次读完**,
    ; 用 KERNEL_SECTS/CHUNK 那种循环会得到 0 次循环(stub 根本没被加载)。
    mov dword [dap_lba], STUB_LBA
    mov word [dap_seg], STUB_ADDR / 16
    mov word [io_count], STUB_SECTS
    call read_chunk

    ; ---- 再多扇区读盘:把 64 KiB 内核搬到 0x10000 ----
    mov dword [dap_lba], KERNEL_LBA
    mov word [dap_seg], KERNEL_SEG
    mov cx, KERNEL_SECTS / CHUNK

.read_loop:
    push cx
    mov word [io_count], CHUNK
    mov di, 3
.retry:
    call read_chunk
    jnc .ok
    xor ah, ah
    mov dl, [boot_drive]
    int 0x13
    dec di
    jnz .retry
    jmp halt16                          ; 读不动就只能停这儿了

.ok:
    movzx eax, word [io_count]
    add dword [dap_lba], eax
    shl eax, 9
    shr eax, 4
    add [dap_seg], ax
    pop cx
    loop .read_loop

    ; ---- 交给内核镜像开头的实模式 stub ----
    mov dl, [boot_drive]
    jmp STUB_ADDR                       ; CS 还是 0(BIOS 给的),近跳到 0x500

; ---------------------------------------------------------------------------
;  底层读一次(两条路都在这里分)
; ---------------------------------------------------------------------------
read_chunk:
    cmp byte [use_lba], 0
    je .chs

    mov ax, [io_count]
    mov [dap_count], ax
    mov si, dap
    mov ah, 0x42
    mov dl, [boot_drive]
    int 0x13
    ret

.chs:
    mov eax, [dap_lba]
    xor edx, edx
    movzx ebx, word [spt]
    div ebx
    mov [sec0], dl
    xor edx, edx
    movzx ebx, word [heads]
    div ebx
    mov dh, dl
    mov dl, [boot_drive]
    mov ch, al
    mov cl, ah
    and cl, 0x03
    shl cl, 6
    mov al, [sec0]
    inc al
    or  cl, al
    movzx ebx, word [spt]
    movzx eax, byte [sec0]
    sub ebx, eax
    mov ax, [io_count]
    cmp ax, bx
    jbe .cnt_ok
    mov ax, bx
.cnt_ok:
    mov [io_count], ax
    mov es, [dap_seg]
    mov bx, 0
    mov ah, 0x02
    int 0x13
    ret

halt16:
    hlt
    jmp halt16

; ---------------------------------------------------------------- 数据
boot_drive db 0
use_lba    db 0
sec0       db 0
spt        dw 18
heads      dw 2
io_count   dw 0

align 4
dap:
    db 0x10
    db 0
dap_count: dw 1
dap_off:   dw 0x0000
dap_seg:   dw KERNEL_SEG
dap_lba:   dq 1
    times 16 - ($ - dap) db 0

    times 510 - ($ - $$) db 0
    dw 0xAA55
