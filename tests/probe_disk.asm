; ============================================================================
;  临时探针(不属于 JoyOS):软盘到底支不支持 LBA 读?
;
;  A) AH=42h LBA 读 8 扇区   B) AH=02h CHS 读 1 扇区(LBA1 = 柱0/头0/扇2)
;  C) AH=41h EDD 支持探测(以后靠它选读法)
;  A/B 读同一个扇区,所以两行 data= 应当一样。
;
;  组装: nasm -f bin tests/probe_disk.asm -o build/probe.bin
;        python3 tools/mkimg.py build/probe.bin build/kernel.bin build/probe.img
;        python3 tests/qemu_test.py build/probe.img --dump
; ============================================================================

[BITS 16]
[ORG 0x7C00]

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    mov [drv], dl
    mov ax, 0x0003
    int 0x10

    mov si, s_a
    call p16
    mov dword [dap_lba], 1
    mov word [dap_count], 8
    mov word [dap_seg], 0x0100
    mov si, dap
    mov ah, 0x42
    mov dl, [drv]
    int 0x13
    mov [err], ah
    call stat
    mov bx, 0x1000
    call dump

    mov si, s_b
    call p16
    mov ax, 0x0201
    mov bx, 0x2000
    mov cx, 0x0002
    mov dx, 0x0000
    int 0x13
    mov [err], ah
    call stat
    mov bx, 0x2000
    call dump

    mov si, s_c
    call p16
    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, [drv]
    push bx
    push cx
    int 0x13
    mov [err], ah
    pop cx
    pop bx
    call stat
    mov si, s_bx
    call p16
    mov ax, bx
    call w4
    mov si, s_cx
    call p16
    mov ax, cx
    call w4

    mov si, s_e
    call p16
hang:
    hlt
    jmp hang

p16:
    push ax
    push bx
    push si
.n:
    lodsb
    test al, al
    jz .d
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    jmp .n
.d:
    pop si
    pop bx
    pop ax
    ret

stat:
    push ax
    push bx
    push si
    mov si, s_cf0
    jnc .p
    mov si, s_cf1
.p:
    call p16
    mov si, s_ah
    call p16
    mov bl, [err]
    mov al, bl
    shr al, 4
    call n1
    mov al, bl
    call n1
    pop si
    pop bx
    pop ax
    ret

n1:
    and al, 0x0F
    cmp al, 10
    jb .d
    add al, 'A' - 10
    jmp .o
.d:
    add al, '0'
.o:
    push bx
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    pop bx
    ret

w4:
    push ax
    push cx
    mov cx, 4
.l:
    rol ax, 4
    push ax
    call n1
    pop ax
    dec cx
    jnz .l
    pop cx
    pop ax
    ret

dump:
    push ax
    push bx
    push cx
    push si
    mov si, s_dt
    call p16
    mov cx, 4
.l:
    mov al, [bx]
    push bx
    mov bl, al
    shr al, 4
    call n1
    mov al, bl
    call n1
    pop bx
    inc bx
    dec cx
    jnz .l
    pop si
    pop cx
    pop bx
    pop ax
    ret

s_a  db 'A LBAx8: ', 0
s_b  db 13, 10, 'B CHSx1: ', 0
s_c  db 13, 10, 'C EDD  : ', 0
s_bx db ' BX=', 0
s_cx db ' CX=', 0
s_dt db ' data=', 0
s_cf0 db ' CF=0', 0
s_cf1 db ' CF=1', 0
s_ah  db ' AH=', 0
s_e   db 13, 10, 'done', 13, 10, 0

drv db 0
err db 0

align 4
dap:
    db 0x10
    db 0
dap_count: dw 8
dap_off:   dw 0
dap_seg:   dw 0x1000
dap_lba:   dq 1
    times 16 - ($ - dap) db 0

    times 510 - ($ - $$) db 0
    dw 0xAA55
