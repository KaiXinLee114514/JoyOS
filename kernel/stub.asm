; ============================================================================
;  JoyOS (胡闹OS) — 实模式 stub(内核镜像的开头,还在实模式里跑)
;
;  引导扇区只把镜像搬到 0x10000 就跳过来了,这里接着干:
;    1. **问 VBE 要一个带线性帧缓冲的图形模式**(必须在实模式里调 BIOS)
;    2. 把模式参数(帧缓冲物理地址/宽高/扫描线/色深/颜色位域)写进 BOOTINFO
;    3. 建 GDT、进保护模式、跳到 32 位内核入口
;
;  为什么不用 BIOS 直接画字:图形模式下没有"字符格"这回事了,屏幕就是一块显存,
;  往里写什么就是什么 —— 汉字、图标、图片全都能画(代价是终端要自己重写)。
;
;  VBE(VESA BIOS Extension)调用:
;    AX=4F00, ES:DI → VbeInfoBlock(512 字节),里面给出支持的模式号列表
;    AX=4F01, CX=模式号, ES:DI → ModeInfoBlock(256 字节)
;    AX=4F02, BX=模式号|0x4000 → 用线性帧缓冲来设置这个模式,返回 AX=004F 表示成功
;  ModeInfoBlock 里我们要的字段(偏移):
;    0x00 ModeAttributes(bit0 支持/bit4 图形/bit7 有线性帧缓冲)
;    0x10 BytesPerScanLine   0x12 XResolution   0x14 YResolution
;    0x19 BitsPerPixel       0x1B MemoryModel(6 = 直接色)
;    0x1F..0x26 红/绿/蓝的位宽和位偏移
;    0x28 PhysBasePtr(帧缓冲物理地址)
; ============================================================================

[BITS 16]
[ORG 0x0500]                            ; 被引导扇区搬到 0x500,用 CS=0 的近跳进来

BOOTINFO     equ 0x8000
VBE_INFO     equ 0x9000                 ; VbeInfoBlock 缓冲
VBE_MODEINFO equ 0x9200                 ; ModeInfoBlock 缓冲
KERNEL_ENTRY equ 0x10000             ; 32 位内核被加载到的物理地址

; ---------------------------------------------------------------------------
;  实模式入口:地址 0x0500(CS=0,所以 ORG 0x0500 的绝对地址就是物理地址)
; ---------------------------------------------------------------------------
stub_entry:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00                      ; 栈放在引导扇区上方,往下长
    sti
    mov [boot_drive], dl

    mov si, msg_hello
    call print16

    ; ---- 1) 取 VBE 控制器信息 ----
    mov ax, 0x4F00
    mov di, VBE_INFO
    int 0x10
    cmp ax, 0x004F
    jne .no_vbe
    cmp dword [VBE_INFO], 0x41534556    ; 'VESA'
    jne .no_vbe
    mov si, msg_vbe_ok
    call print16

    ; ---- 2) 在模式列表里找合用的模式 ----
    ; 模式列表是"远指针"存在 VbeInfoBlock +0x0E(偏移)+0x10(段)
    mov ax, [VBE_INFO + 0x10]
    mov fs, ax
    mov si, [VBE_INFO + 0x0E]

.next_mode:
    mov cx, [fs:si]
    cmp cx, 0xFFFF                      ; 列表结束
    je .no_vbe
    add si, 2
    mov [cand_mode], cx

    mov ax, 0x4F01
    mov di, VBE_MODEINFO
    int 0x10
    cmp ax, 0x004F
    jne .next_mode

    mov ax, [VBE_MODEINFO + 0x00]       ; ModeAttributes
    test ax, 0x0001                     ; 硬件支持
    jz .next_mode
    test ax, 0x0010                     ; 图形模式
    jz .next_mode
    test ax, 0x0080                     ; 有线性帧缓冲(没这个就没法直接写显存)
    jz .next_mode
    cmp byte [VBE_MODEINFO + 0x19], 32  ; 要 32 位色(每像素 4 字节,好画)
    jne .next_mode
    cmp byte [VBE_MODEINFO + 0x1B], 6   ; 直接色模式
    jne .next_mode
    cmp word [VBE_MODEINFO + 0x12], 640 ; 至少 640 宽
    jb .next_mode

    ; 800×600 优先;否则先记下第一个合用的,继续找
    cmp word [VBE_MODEINFO + 0x12], 800
    jne .remember
    cmp word [VBE_MODEINFO + 0x14], 600
    je .found
.remember:
    cmp byte [have_cand], 0
    jne .next_mode
    mov byte [have_cand], 1
    mov ax, [cand_mode]
    mov [best_mode], ax
    jmp .next_mode

.found:
    mov ax, [cand_mode]
    mov [best_mode], ax
    mov byte [have_cand], 1

    ; ---- 3) 设置模式(0x4000 = 用线性帧缓冲)----
    mov ax, 0x4F02
    mov bx, [best_mode]
    or  bx, 0x4000
    int 0x10
    cmp ax, 0x004F
    jne .no_vbe

    ; 设完再读一次模式信息:有些 BIOS 这时才填好帧缓冲地址
    mov ax, 0x4F01
    mov cx, [best_mode]
    mov di, VBE_MODEINFO
    int 0x10
    cmp ax, 0x004F
    jne .no_vbe

    ; ---- 4) 把模式参数写进 BOOTINFO ----
    mov eax, [VBE_MODEINFO + 0x28]
    mov [BOOTINFO + 16], eax            ; 帧缓冲物理地址
    movzx eax, word [VBE_MODEINFO + 0x12]
    mov [BOOTINFO + 20], eax            ; 宽
    movzx eax, word [VBE_MODEINFO + 0x14]
    mov [BOOTINFO + 24], eax            ; 高
    movzx eax, word [VBE_MODEINFO + 0x10]
    mov [BOOTINFO + 28], eax            ; 扫描线字节数(pitch)
    movzx eax, byte [VBE_MODEINFO + 0x19]
    mov [BOOTINFO + 32], eax            ; 每像素位数
    movzx eax, byte [VBE_MODEINFO + 0x1F]
    mov [BOOTINFO + 36], eax            ; 红位宽
    movzx eax, byte [VBE_MODEINFO + 0x20]
    mov [BOOTINFO + 40], eax            ; 红偏移
    movzx eax, byte [VBE_MODEINFO + 0x21]
    mov [BOOTINFO + 44], eax
    movzx eax, byte [VBE_MODEINFO + 0x22]
    mov [BOOTINFO + 48], eax
    movzx eax, byte [VBE_MODEINFO + 0x23]
    mov [BOOTINFO + 52], eax
    movzx eax, byte [VBE_MODEINFO + 0x24]
    mov [BOOTINFO + 56], eax
    movzx eax, word [best_mode]
    mov [BOOTINFO + 60], eax            ; 模式号
    mov dword [BOOTINFO + 64], 1        ; vbe_ok = 1
    ; ---- 诊断用:把 VBE 报的几个"可能不一致"的字段原样带给内核 ----
    ;  (VBE 2.0 的 BytesPerScanLine(0x10)在有些 BIOS/虚拟机里是"窗口模式"的值,
    ;   真正的线性帧缓冲行距在 VBE 3.0 的 LinBytesPerScanLine(0x32)—— 这就是
    ;   同一个内核在 QEMU 正常、在 VirtualBox 花屏的那个坑)
    mov eax, [VBE_INFO + 0x04]
    mov [BOOTINFO + 76], eax            ; VBE 版本
    movzx eax, word [VBE_MODEINFO + 0x10]
    mov [BOOTINFO + 80], eax            ; BytesPerScanLine(老字段)
    movzx eax, word [VBE_MODEINFO + 0x32]
    mov [BOOTINFO + 84], eax            ; LinBytesPerScanLine(VBE3 新字段)
    movzx eax, word [VBE_MODEINFO + 0x00]
    mov [BOOTINFO + 88], eax            ; ModeAttributes
    movzx eax, byte [VBE_MODEINFO + 0x19]
    mov [BOOTINFO + 92], eax            ; BitsPerPixel(冗余,确认用)

    mov si, msg_mode_ok
    call print16
    jmp enter_pm

.no_vbe:
    mov dword [BOOTINFO + 64], 0        ; 没搞到图形模式,内核会用文本模式
    mov si, msg_no_vbe
    call print16

; ---------------------------------------------------------------------------
;  进保护模式(和以前在引导扇区里做的一样,只是现在有地方写注释了)
; ---------------------------------------------------------------------------
enter_pm:
    cli
    lgdt [gdt_desc]
    mov eax, cr0
    or  eax, 1
    mov cr0, eax
    jmp CODE_SEG:pm_start

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
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    jmp .next
.done:
    pop si
    pop bx
    pop ax
    ret

; ---------------------------------------------------------------- GDT
align 8
gdt_start:
    dq 0x0000000000000000
gdt_code:
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10011010b
    db 11001111b
    db 0x00
gdt_data:
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10010010b
    db 11001111b
    db 0x00
gdt_end:
gdt_desc:
    dw gdt_end - gdt_start - 1
    dd gdt_start

CODE_SEG equ 8
DATA_SEG equ 16

; ---------------------------------------------------------------- 数据
msg_hello   db 'JoyOS: real-mode stub', 13, 10, 0
msg_vbe_ok  db '  VBE found, picking a mode...', 13, 10, 0
msg_mode_ok db '  graphics mode set (see kernel output)', 13, 10, 0
msg_no_vbe  db '  no usable VBE mode - falling back to text mode', 13, 10, 0

boot_drive db 0
cand_mode  dw 0
best_mode  dw 0
have_cand  db 0

; ---------------------------------------------------------------- 32 位
[BITS 32]
pm_start:
    mov ax, DATA_SEG
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, 0x90000
    mov ebp, esp
    jmp KERNEL_ENTRY                    ; 32 位内核入口(绝对地址 0x10000)
