; ============================================================================
;  fpu.asm — x87 浮点单元初始化
;
;  为什么要做:x86 开机后 x87 处于"复位默认"状态,但保护模式代码通常没动过
;  CR0 里的 EM/MP/NE/TS 位 —— 其中 NE(x87 数值错误异常) 默认是 0,一旦浮点
;  指令出错,CPU 会走 IRQ13 这条"DOS 兼容"老路;QEMU/VBox 根本不模拟 IRQ13,
;  于是整个系统直接卡死/三重故障。先在核心里把它改成现代语义(NE=1,异常走
;  #MF 向量 16,idt.asm 里已经有处理程序)。
;
;  做三件事:
;      1. CPUID 确认 CPU 有 x87(没有就跳过)
;      2. CR0: EM=0(允许浮点), MP=1, NE=1(异常走 #MF), TS=0
;      3. fninit 复位 x87 + fldcw 默认控制字 0x037F
;         (PC 精度 64 位、就近舍入、六种异常全屏蔽)
;
;  ★ 线程切换暂不保存 x87 状态:sched.asm 的上下文切换只 pushad/popad,
;    而目前只有 shell 主线程会跑浮点程序(其它 shell 线程不碰 x87),所以
;    暂时不会互相污染。以后要支持多线程浮点,再在 sched 里给每个线程栈
;    加 512 字节 fxsave 区(fxsave/fxrstor)。
;
;  调用:kmain.asm 在 idt_init 之后 call fpu_init;返回 al=1 表示可用。
; ============================================================================

; 默认 x87 控制字:0x037F = 精度 64 位 | 就近舍入 | 所有异常屏蔽
FPU_CW_DEFAULT equ 0x037F

; ---------------------------------------------------------------------------
;  fpu_init —— 初始化 x87,返回 al = 1(可用) / 0(没有 FPU)
; ---------------------------------------------------------------------------
fpu_init:
    push ebx
    pushfd
    cli                             ; 初始化期间不响应中断

    ; ---- 1. CPUID 查 x87 ----
    mov eax, 1
    cpuid
    test edx, 1                     ; EDX[0] = FPU 存在
    jz .no_fpu

    ; ---- 2. CR0: EM=0, MP=1, NE=1, TS=0 ----
    mov eax, cr0
    and eax, ~(1 << 2)              ; 清 EM:允许 x87 指令
    or  eax, (1 << 1)               ; 置 MP:监视协处理器(WAIT/FWAIT 语义)
    or  eax, (1 << 5)               ; 置 NE:数值错误走 #MF(向量 16)
    and eax, ~(1 << 3)              ; 清 TS:不做惰性切换
    mov cr0, eax

    ; ---- 3. fninit + 默认控制字 ----
    fninit                          ; 复位 x87(不产生异常)
    push dword FPU_CW_DEFAULT
    fldcw [esp]                     ; 载入控制字
    add esp, 4
    fnclex                          ; 清状态字里的挂起异常

    ; ---- 4. 自检:跑两条浮点指令,确认真的能用 ----
    fld1                            ; st(0) = 1.0
    fld1                            ; st(0) = 1.0, st(1) = 1.0
    faddp st1, st0                  ; st(0) = 2.0
    fstp dword [fpu_selftest]       ; 存回内存
    fwait

    mov al, 1
    jmp .done

.no_fpu:
    xor al, al

.done:
    popfd                           ; 恢复中断标志(原值)
    pop ebx
    ret

; 自检落点(调试时可以用 xp 命令看这里是不是 2.0 的 IEEE 表示 0x40000000)
fpu_selftest: dd 0
