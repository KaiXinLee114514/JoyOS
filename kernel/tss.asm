; ============================================================================
;  JoyOS (胡闹OS) — ring 3 的地基:用户段 + TSS
;
;  为什么需要这个文件(两条都是硬性要求,少一条就三重故障重启):
;
;    1) 用户段:程序要在 ring 3 跑,就得有 **DPL=3** 的代码段/数据段描述符。
;       原来那张 GDT 只有内核的两项(DPL=0),iret 到 ring 3 会立刻 #GP。
;
;    2) TSS:CPU 从 ring 3 掉回 ring 0(硬件中断、int 0x30)时,**内核栈在哪、
;       用哪个 ss** 只能从 TSS 的 esp0/ss0 里读 —— 这是 CPU 定的规矩,没有别的
;       地方能告诉它。没 ltr 过 TSS 就进中断 = 三重故障(机器重启)。
;       所以 ring 3 程序的"内核栈"是 TSS.esp0 指的这块,不是它自己那个栈。
;
;  做法:开机时换上一张新 GDT(前两项和 stub 里那张一模一样,后三项是新的)
;      0x08 内核代码(DPL=0)   0x10 内核数据(DPL=0)
;      0x1B 用户代码(DPL=3)   0x23 用户数据(DPL=3)   0x28 TSS
;  为什么不直接改 kernel/stub.asm 里那张:stub.bin 是 Makefile 里**单独**汇编的
;  (nasm kernel/stub.asm),它看不见这儿的 tss_blk 符号。从内核里重建一张表最省事,
;  而且 0x08/0x10 的值保持不变 —— idt.asm 里写死的 CODE_SEL 不用动。
;
;  I/O 位图**故意不给**(iomap_base = 104 = 表大小):ring 3 里 in/out 一律 #GP,
;  连 hlt 这种特权指令也不行。想做"特权违规"的演示很方便(见 progs/FAULT.asm)。
;
;  ring 3 期间的中断栈:RING3_STACK_TOP(0x60000,8 KiB 往下长)。为什么不用
;  shell 自己那条栈:进 ring 3 时 shell 的调用栈还挂在上面(cmd_run 下面还有
;  shell_execute/shell_main 的活帧),中断往栈顶一压就踩上了。单独一条最干净。
;  只有**一个**程序能跑(见 shell.asm 的 prog_owner 守卫),所以这条栈不会被抢。
; ============================================================================

TSS_SIZE         equ 104                ; 32 位 TSS 就固定这么大
TSS_ESP0         equ 4                  ; +4  esp0:ring 0 用哪个栈顶
TSS_SS0          equ 8                  ; +8  ss0
TSS_IOMAP        equ 102                ; +102 I/O 位图偏移(= TSS_SIZE 就是"没有位图")

RING3_STACK_TOP  equ 0x60000            ; ring 3 期间中断用的内核栈顶

GDT_KCODE        equ 0x08               ; 内核代码段选择子(和 CODE_SEL 一样)
GDT_KDATA        equ 0x10               ; 内核数据段选择子
USER_CODE_SEG    equ 0x1B               ; GDT 第 3 项 | 3
USER_DATA_SEG    equ 0x23               ; GDT 第 4 项 | 3
TSS_SEG          equ 0x28               ; GDT 第 5 项

; ---------------------------------------------------------------------------
;  TSS 本体(开机时清零)
;  故意放在 GDT 前面:下面那张表里要用 tss_blk 的地址算描述符的 base,而 nasm
;  对"还没定义的标签做位运算"会报 `operator may only be applied to scalar values`
;  —— 前向引用得先是个标量。
; ---------------------------------------------------------------------------
align 4
tss_blk: times TSS_SIZE db 0

; ---------------------------------------------------------------------------
;  新 GDT(每项 8 字节,手写字段:limit/base/access/flags)
; ---------------------------------------------------------------------------
align 8
gdt_new:
    dq 0x0000000000000000               ; 0x00 空(CPU 要求第 0 项全 0)
gdt_new_code:                           ; 0x08 内核代码:P=1 DPL=0 可执行可读
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10011010b
    db 11001111b
    db 0x00
gdt_new_data:                           ; 0x10 内核数据:P=1 DPL=0 可写
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10010010b
    db 11001111b
    db 0x00
gdt_new_ucode:                          ; 0x1B 用户代码:P=1 DPL=3 可执行可读
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 11111010b
    db 11001111b
    db 0x00
gdt_new_udata:                          ; 0x23 用户数据:P=1 DPL=3 可写
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 11110010b
    db 11001111b
    db 0x00
gdt_new_tss:                            ; 0x28 TSS:类型 9 = 32 位可用 TSS
    dw TSS_SIZE - 1                     ; limit = 104 字节
    dw 0x0000                           ; base 的 16 位/8 位/8 位三段先留 0,
    db 0x00                             ;   开机时由 gdt_tss_set_base 填进去
    db 10001001b                        ; P=1 DPL=0 类型 1001 = 32 位可用 TSS
    db 0x00
    db 0x00                             ;   (granularity 0:以字节为单位)

; 把 TSS 的真实地址填进描述符的 base 三段。
; ★ 为什么不在表里直接算:nasm -f bin 里对**标签**做 & / >> 会报
;   `operator may only be applied to scalar values`(标量位运算只认立即数);
;   `dd 标签` 可以,是因为那只是"把地址当数据写进去"。所以位运算挪到运行时。
gdt_tss_set_base:
    mov eax, tss_blk
    mov [gdt_new_tss + 2], ax           ; base 位 0-15
    shr eax, 16
    mov [gdt_new_tss + 4], al           ; base 位 16-23
    shr eax, 8
    mov [gdt_new_tss + 7], al           ; base 位 24-31
    ret
gdt_new_end:
gdt_new_desc:
    dw gdt_new_end - gdt_new - 1
    dd gdt_new

; ---------------------------------------------------------------------------
;  gdt_tss_init:换 GDT + 建 TSS + ltr —— 只在开机时调一次
;  自己 pushfd/cli:不管调用点在不在"中断已开"的阶段都安全(改 GDT 那一刻
;  要是来了中断,CPU 还在拿旧表解释选择子,想想就刺激)。
; ---------------------------------------------------------------------------
gdt_tss_init:
    pushfd
    cli
    pushad

    call gdt_tss_set_base               ; 先把 TSS 描述符的 base 填好
    lgdt [gdt_new_desc]

    mov ax, GDT_KDATA
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    jmp GDT_KCODE:gdt_tss_flush         ; 远跳一下,把 CS 也换成新表里的

gdt_tss_flush:
    mov edi, tss_blk
    xor eax, eax
    mov ecx, TSS_SIZE / 4
    rep stosd

    mov ax, GDT_KDATA
    mov [tss_blk + TSS_SS0], ax             ; ring 0 的 ss
    mov word [tss_blk + TSS_IOMAP], TSS_SIZE ; 没有 I/O 位图 → ring 3 不许 in/out
    mov dword [tss_blk + TSS_ESP0], RING3_STACK_TOP

    mov ax, TSS_SEG
    ltr ax                              ; 从此 CPU 知道 ring 3 → ring 0 该用哪条栈

    popad
    popfd
    ret
