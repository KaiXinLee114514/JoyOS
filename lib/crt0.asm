; ============================================================================
;  JoyOS (胡闹OS) — C 程序的入口(crt0)
;
;  内核 `call build/XXX.BIN` 的那个地址,进来就是这里。要做的事只有两件:
;      1. 把 BSS 清零(平铺二进制里没存"全是 0 的段",内存里是垃圾)
;      2. 调 main(),它返回后我们再 ret 回 shell
;
;  没有 argc/argv:参数是用 int 0x30 的第 12 号功能取的(见 joyos.h 的 j_arg)。
;  也没有 _exit/atexit/main 的返回值处理 —— main 返回就是我们返回。
;
;  汇编: nasm -f elf32 lib/crt0.asm -o build/crt0.o   (注意是 elf32,要给 ld 用)
; ============================================================================

[BITS 32]

global _start
extern main
extern __bss_start
extern __bss_end
extern mc_exitbuf

section .text
_start:
    ; ---- 清 BSS:从 __bss_start 到 __bss_end 全写 0 ----
    mov edi, __bss_start
    mov ecx, __bss_end
    sub ecx, edi
    xor eax, eax
    rep stosb

    ; ---- 给 exit() 留个跳板:它 longjmp 回这里,然后我们一起回 shell ----
    push mc_exitbuf
    call mc_setjmp
    add esp, 4                          ; ★ 把参数丢掉:不丢的话下面那句 ret
    ;                                     会把"跳板地址"当成返回地址,直接飞出去
    ;                                     (第一版就是这么炸的:CR2 = 0xA4960001)
    test eax, eax
    jnz .out                            ; 1 = exit() 从 longjmp 跳回来

    call main

.out:
    ; main 返回(或 exit() 跳回来)了 → 直接回 shell
    ; (程序用 ret 返回是 JoyOS 的约定)
    ret

; ---------------------------------------------------------------------------
;  迷你 setjmp/longjmp:只有"回到跳板"这一个用途,但得是真的保存/恢复寄存器,
;  不然 exit() 从深层调用返回时栈是歪的。
;      jmp_buf 布局:int[6] = ebp, ebx, esi, edi, esp, 返回地址
; ---------------------------------------------------------------------------
global mc_setjmp
mc_setjmp:
    mov eax, [esp + 4]                  ; eax = jmp_buf
    mov [eax + 0], ebp
    mov [eax + 4], ebx
    mov [eax + 8], esi
    mov [eax + 12], edi
    mov [eax + 16], esp
    mov ecx, [esp]                      ; 保存返回地址(调用点)
    mov [eax + 20], ecx
    xor eax, eax                        ; 直接返回时给 0
    ret

global mc_longjmp
mc_longjmp:
    mov eax, [esp + 4]                  ; jmp_buf
    mov edx, [esp + 8]                  ; 返回值
    mov ebp, [eax + 0]
    mov ebx, [eax + 4]
    mov esi, [eax + 8]
    mov edi, [eax + 12]
    mov esp, [eax + 16]
    mov ecx, [eax + 20]
    mov [esp], ecx                      ; 让 ret 回到当初调用 mc_setjmp 的地方
    mov eax, edx
    test eax, eax
    jnz .ok
    inc eax                             ; longjmp(b, 0) 也得返回"非 0"
.ok:
    ret
