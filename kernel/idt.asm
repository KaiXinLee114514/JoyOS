; ============================================================================
;  JoyOS (胡闹OS) — 中断描述符表(IDT)与 CPU 异常处理
;
;  这个文件被 kernel/kmain.asm 用 %include 装进去(同一个平坦二进制,
;  不用链接器 —— 大小自觉控制在 128 KiB 内核区以内)。
;
;  ── IDT 是什么 ──────────────────────────────────────────────────────────
;  保护模式下 CPU 不再用中断向量表(实模式的 0x0000 那 1KB),改用 IDT:
;  256 个 8 字节表项,每项告诉 CPU"这个号的中断该跳去哪、用什么段、什么门"。
;  表项结构(低地址在前):
;      [0..1]  处理程序地址低 16 位
;      [2..3]  代码段选择子(我们用 0x08,就是引导扇区 GDT 里的代码段)
;      [4]     恒 0
;      [5]     属性:0x8E = P=1 DPL=0 32 位中断门
;      [6..7]  处理程序地址高 16 位
;  最后用 lidt 把 IDT 的基址和限长告诉 CPU。
;
;  ── 异常和错误码 ────────────────────────────────────────────────────────
;  有些异常 CPU 会**自己多压一个错误码**(8 双重故障、10~14、17、21、29、30),
;  有些不会。为了在 C 风格的处理程序里统一取参数,没有错误码的我们压一个 0,
;  这样栈上永远是:  向量号 → 错误码 → EIP → CS → EFLAGS
; ============================================================================

CODE_SEL   equ 0x08                    ; GDT 里的代码段选择子
IDT_ENTRIES equ 256

; ---------------------------------------------------------------------------
;  生成 32 个异常入口
;    %1 = 向量号   %2 = 1 表示 CPU 会自己压错误码
; ---------------------------------------------------------------------------
%macro ISR_ERRCODE 1
isr_%1:
    push dword %1                      ; CPU 已经压了错误码,只补向量号
    jmp isr_common
%endmacro

%macro ISR_NOERRCODE 1
isr_%1:
    push dword 0                       ; 假错误码,让栈格式统一
    push dword %1
    jmp isr_common
%endmacro

ISR_NOERRCODE 0                        ; #DE 除零
ISR_NOERRCODE 1                        ; #DB 调试
ISR_NOERRCODE 2                        ; NMI
ISR_NOERRCODE 3                        ; #BP 断点
ISR_NOERRCODE 4                        ; #OF 溢出
ISR_NOERRCODE 5                        ; #BR 越界
ISR_NOERRCODE 6                        ; #UD 非法指令
ISR_NOERRCODE 7                        ; #NM 设备不可用
ISR_ERRCODE   8                        ; #DF 双重故障
ISR_NOERRCODE 9                        ; 协处理器段越界(386 以后不用)
ISR_ERRCODE   10                       ; #TS 非法 TSS
ISR_ERRCODE   11                       ; #NP 段不存在
ISR_ERRCODE   12                       ; #SS 栈异常
ISR_ERRCODE   13                       ; #GP 通用保护
ISR_ERRCODE   14                       ; #PF 页错误
ISR_NOERRCODE 15                       ; 保留
ISR_NOERRCODE 16                       ; #MF x87 浮点
ISR_ERRCODE   17                       ; #AC 对齐检查
ISR_NOERRCODE 18                       ; #MC 机器检查
ISR_NOERRCODE 19                       ; #XM SIMD 浮点
ISR_NOERRCODE 20                       ; #VE 虚拟化
ISR_NOERRCODE 21                       ; 保留(有的 CPU 压错误码)
ISR_NOERRCODE 22
ISR_NOERRCODE 23
ISR_NOERRCODE 24
ISR_NOERRCODE 25
ISR_NOERRCODE 26
ISR_NOERRCODE 27
ISR_NOERRCODE 28
ISR_ERRCODE   29                       ; #VC
ISR_ERRCODE   30                       ; #SX
ISR_NOERRCODE 31                       ; 保留

; 没登记的号(比如后面的硬件中断)一律走这里
isr_default:
    push dword 0
    push dword 0xFFFFFFFF              ; 用它表示"不知道是哪个向量"
    jmp isr_common

; 0..31 号异常的处理程序地址表(填 IDT 用)
isr_table:
%assign v 0
%rep 32
    dd isr_%+v
%assign v v+1
%endrep

; ---------------------------------------------------------------------------
;  idt_init:填 256 个表项 → 装载 IDT
; ---------------------------------------------------------------------------
idt_init:
    pushad
    mov ecx, IDT_ENTRIES
    mov edi, idt
    mov esi, isr_default
.fill:                                 ; 全部先指向默认处理程序
    mov eax, esi
    call idt_set
    add edi, 8
    dec ecx
    jnz .fill

    mov ecx, 32
    mov edi, idt
    mov esi, isr_table
.over:                                 ; 再把 0..31 换成各自的
    mov eax, [esi]
    call idt_set
    add edi, 8
    add esi, 4
    dec ecx
    jnz .over

    lidt [idt_desc]
    popad
    ret

; eax = 向量号,ebx = 处理程序地址(给键盘这类硬件中断用)
idt_install:
    push edi
    mov edi, idt
    shl eax, 3                         ; 每个表项 8 字节
    add edi, eax
    mov eax, ebx
    call idt_set
    pop edi
    ret

; 同上,但门的 DPL=3 —— ring 3 的程序也能 int 进来(只有 int 0x30 用这个)
;  DPL 是"谁有资格用这条门"的闸:硬件中断门必须 DPL=0(不然用户能伪造定时器),
;  系统调用门才是 DPL=3。这是有意开的一个口子,别的口子一个都不留。
idt_install_user:
    push edi
    mov edi, idt
    shl eax, 3
    add edi, eax
    mov eax, ebx
    call idt_set_user
    pop edi
    ret

; edi = 表项地址,eax = 处理程序地址(会改 eax)
idt_set:
    mov [edi], ax                      ; 地址低 16 位
    mov word [edi + 2], CODE_SEL       ; 代码段选择子
    mov byte [edi + 4], 0
    mov byte [edi + 5], 0x8E           ; P=1 DPL=0 32 位中断门
    shr eax, 16
    mov [edi + 6], ax                  ; 地址高 16 位
    ret

idt_set_user:
    mov [edi], ax
    mov word [edi + 2], CODE_SEL
    mov byte [edi + 4], 0
    mov byte [edi + 5], 0xEE           ; P=1 DPL=3 32 位中断门
    shr eax, 16
    mov [edi + 6], ax
    ret

; ---------------------------------------------------------------------------
;  isr_common:所有异常/中断的公共出口 —— 现在只会"报错 + 停机"
;  进来时栈上(从低到高):向量号, 错误码, EIP, CS, EFLAGS
;  做完 pushad 之后 esp 往下移了 32 字节,所以:
;      [ebp+32]=向量号 [ebp+36]=错误码 [ebp+40]=EIP [ebp+44]=CS [ebp+48]=EFLAGS
; ---------------------------------------------------------------------------
isr_common:
    cli
    pushad
    mov ebp, esp

    ; ---- 14 号页错误先问一句:这是不是"按需分页"该补的页? ----
    ; page_fault_try_handle 返回 1 = 已经从页池拿了一页、填好了程序页表,
    ; 那就按原路回去把出错的那条指令**重执行一遍**(iret 的 EIP 就是它)。
    ; 没有程序在跑、或者地址不在程序窗口里 → 返回 0,照旧走下面的 panic。
    cmp dword [ebp + 32], 14
    jne .no_demand
    call page_fault_try_handle
    test eax, eax
    jnz .resume
.no_demand:

    ; ---- 这次异常是从 ring 3(用户程序)来的吗?----
    ;  是的话"弄死程序、系统活着"才是正经行为:内核 panic 屏是给内核自己
    ;  犯错用的,不能让一个乱写地址的玩具程序把整台机器按死。
    ;  取异常现场的 CS(位 0-1 = CPL):ring 3 的段选择子 CPL 就是 3。
    mov eax, [ebp + 44]
    and eax, 3
    cmp eax, 3
    jne .not_user
    cmp dword [space_live], 0
    je .not_user                        ; 没有程序在跑(理论上到不了)→ 老实 panic
    mov ebx, ebp                        ; 异常现场的帧指针交给它
    call prog_kill_from_fault           ; 不返回:干掉程序、回到 shell
.not_user:

    mov al, 10                           ; 先换行,免得和半行输出粘在一起
    call term_putc
    mov al, 0x4F                         ; 白字红底
    call term_set_color
    mov esi, msg_panic
    call term_print
    mov al, 10
    call term_putc

    ; ---- "EXCEPTION 00: divide error" ----
    mov al, 0x4F
    call term_set_color
    mov esi, msg_exc
    call term_print
    mov eax, [ebp + 32]
    and eax, 0xFF
    cmp eax, 0xFF
    je .unknown
    call term_print_byte                 ; 两位向量号
    mov esi, msg_colon
    call term_print
    mov eax, [ebp + 32]
    and eax, 0xFF
    call isr_name                        ; eax → 名字字符串
    mov esi, eax
    call term_print
    jmp .detail
.unknown:
    mov esi, msg_unknown
    call term_print

.detail:
    mov al, 10
    call term_putc
    mov al, 0x0F                         ; 白字黑底
    call term_set_color
    mov esi, msg_err
    call term_print
    mov eax, [ebp + 36]
    call term_print_hex
    mov al, 10
    call term_putc

    mov esi, msg_eip
    call term_print
    mov eax, [ebp + 40]
    call term_print_hex
    mov esi, msg_cs
    call term_print
    mov eax, [ebp + 44]
    and eax, 0xFFFF
    call term_print_hex
    mov esi, msg_flags
    call term_print
    mov eax, [ebp + 48]
    call term_print_hex
    mov al, 10
    call term_putc

    ; ---- 页错误(14 号)的话,CR2 里存着出错的那个线性地址,很有用 ----
    cmp dword [ebp + 32], 14
    jne .no_cr2
    mov esi, msg_cr2
    call term_print
    mov eax, cr2
    call term_print_hex
    mov al, 10
    call term_putc
.no_cr2:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_halt
    call term_print

.panic_hang:
    hlt
    jmp .panic_hang

; 按需分页补好了:扔掉"向量号 + 错误码",iret 回去重试那条指令
; (栈上现在是:向量号, 错误码, EIP, CS, EFLAGS —— popad 之后正是这样)
.resume:
    popad
    add esp, 8
    iret

; ---------------------------------------------------------------------------
;  isr_name:向量号(传在 eax)→ 名字字符串地址(返在 eax)
; ---------------------------------------------------------------------------
isr_name:
    cmp eax, 32
    jae .bad
    push ebx
    mov ebx, exc_names
    mov eax, [ebx + eax * 4]
    pop ebx
    ret
.bad:
    mov eax, msg_unknown
    ret

; ---------------------------------------------------------------- 数据
msg_panic   db '*** KERNEL PANIC ***', 0
msg_exc     db 'EXCEPTION ', 0
msg_colon   db ': ', 0
msg_err     db 'error code = ', 0
msg_eip     db 'EIP = ', 0
msg_cs      db '   CS = ', 0
msg_flags   db '   EFLAGS = ', 0
msg_halt    db 'system halted - reset the machine (or close QEMU)', 10, 0
msg_unknown db 'unhandled interrupt', 0
msg_cr2     db 'CR2 (faulting address) = ', 0

n0  db 'divide error', 0
n1  db 'debug', 0
n2  db 'non-maskable interrupt', 0
n3  db 'breakpoint', 0
n4  db 'overflow', 0
n5  db 'bound range exceeded', 0
n6  db 'invalid opcode', 0
n7  db 'device not available', 0
n8  db 'double fault', 0
n9  db 'coprocessor segment overrun', 0
n10 db 'invalid TSS', 0
n11 db 'segment not present', 0
n12 db 'stack-segment fault', 0
n13 db 'general protection fault', 0
n14 db 'page fault', 0
n15 db 'reserved (15)', 0
n16 db 'x87 floating-point', 0
n17 db 'alignment check', 0
n18 db 'machine check', 0
n19 db 'SIMD floating-point', 0
n20 db 'virtualization', 0
n21 db 'reserved (21)', 0
n22 db 'reserved (22)', 0
n23 db 'reserved (23)', 0
n24 db 'reserved (24)', 0
n25 db 'reserved (25)', 0
n26 db 'reserved (26)', 0
n27 db 'reserved (27)', 0
n28 db 'reserved (28)', 0
n29 db 'VMM communication', 0
n30 db 'security exception', 0
n31 db 'reserved (31)', 0

exc_names:
    dd n0,  n1,  n2,  n3,  n4,  n5,  n6,  n7
    dd n8,  n9,  n10, n11, n12, n13, n14, n15
    dd n16, n17, n18, n19, n20, n21, n22, n23
    dd n24, n25, n26, n27, n28, n29, n30, n31

align 8
idt:
    times IDT_ENTRIES * 8 db 0          ; 256 × 8 = 2048 字节
                                        ; (用 times db 0 而不是 resb:平坦二进制里
                                        ;  resb 会让 nasm 报 "uninitialized space" 警告)
idt_end:

idt_desc:
    dw idt_end - idt - 1                ; 限长
    dd idt                              ; 基址
