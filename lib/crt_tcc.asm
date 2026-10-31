; ============================================================================
;  JoyOS — TCC 编译程序的入口(crt_tcc)
;
;  和 lib/crt0.asm 的区别:
;    · crt0 是给宿主机 gcc + joyos.ld 链接的平铺 BIN 用的:它清 BSS
;      (__bss_start/__bss_end 由链接脚本提供)。
;    · crt_tcc 是给 **JoyOS 里 TCC 链接出来的 ELF** 用的:TCC 没有链接脚本,
;      给不了 __bss_start/__bss_end —— BSS 由内核 ELF loader 按
;      p_memsz-p_filesz 清零(见 kernel/elf.asm)。
;    · 其余照抄 crt0:exit() 的 setjmp 跳板 + main 返回后回 shell。
;      程序里 exit() 能正常工作(它 longjmp 回这里的跳板,再 int 0x30:15)。
;
;  约定:ELF 入口符号是 _start(TCC 对可执行文件默认以 _start 为入口,
;  见 tccelf.c 里 get_sym_addr(s1, "_start", ...))。
;
;  汇编: nasm -f elf32 lib/crt_tcc.asm -o build/crt_tcc.o
; ============================================================================

[BITS 32]

global _start
extern main
extern mc_exitbuf

section .text
_start:
    ; ---- 给 exit() 留个跳板:它 longjmp 回这里,然后一起回 shell ----
    push mc_exitbuf
    call mc_setjmp
    add esp, 4                          ; 把参数丢掉,不然 ret 会飞出去
    test eax, eax
    jnz .out                            ; 1 = exit() 从 longjmp 跳回来

    call main

.out:
    mov eax, 15                         ; int 0x30:15 = 程序结束
    int 0x30
    ret

; ---------------------------------------------------------------------------
;  迷你 setjmp/longjmp(和 lib/crt0.asm 里的同一份实现)
;      jmp_buf 布局:int[6] = ebp, ebx, esi, edi, esp, 返回地址
; ---------------------------------------------------------------------------
global mc_setjmp
mc_setjmp:
    mov eax, [esp + 4]
    mov [eax + 0], ebp
    mov [eax + 4], ebx
    mov [eax + 8], esi
    mov [eax + 12], edi
    mov [eax + 16], esp
    mov ecx, [esp]
    mov [eax + 20], ecx
    xor eax, eax
    ret

global mc_longjmp
mc_longjmp:
    mov eax, [esp + 4]
    mov edx, [esp + 8]
    mov ebp, [eax + 0]
    mov ebx, [eax + 4]
    mov esi, [eax + 8]
    mov edi, [eax + 12]
    mov esp, [eax + 16]
    mov ecx, [eax + 20]
    mov [esp], ecx
    mov eax, edx
    test eax, eax
    jnz .ok
    inc eax
.ok:
    ret
