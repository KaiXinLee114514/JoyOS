; ============================================================================
;  JoyOS (胡闹OS) — 程序接口(int 0x30)
;
;  磁盘上的程序怎么跟内核说话?如果直接 `call` 内核里的函数,那函数的**绝对地址**
;  会随内核代码变化而变 —— 程序编好就作废了。所以用软中断当门:
;
;      eax = 功能号,其它寄存器放参数,`int 0x30` 进去
;
;      0  打印字符串        esi = UTF-8 字符串地址(0 结尾)
;      1  打印十进制        ebx = 数值
;      2  打印十六进制      ebx = 数值
;      3  打印一个码位      ebx = Unicode 码位(可以打中文)
;      4  设颜色            bl  = 属性字节(和文本模式一样,如 0x0A 亮绿)
;      5  等一个按键        → 返回 al = ASCII(没有输入法,只能拿到 ASCII)
;
;  别的功能号会被忽略。程序直接 ret 就回到 shell,不用专门"返回"。
;
;  这样接口就"冻结"了:内核怎么改,程序的 int 0x30 永远有效。
;  程序本身用 nasm 编成平铺二进制,被 shell 的 run 命令读进 0x120000 后 call 进去,
;  所以程序里的 [ORG 0x120000] 要和 kernel/shell.asm 里的 PROG_ADDR 一致。
; ============================================================================

API_VECTOR  equ 0x30                    ; 用哪个中断号(0x20-0x2F 是硬件中断,所以挑 0x30)

; ---------------------------------------------------------------------------
;  api_stub:中断门进来的第一站。保存现场 → 分发 → 恢复 → iret
; ---------------------------------------------------------------------------
api_stub:
    pushad
    push ds
    push es
    push fs
    push gs
    ; ★ 注意:`mov ax, 0x10` 会把 EAX 的低 16 位冲掉,而 EAX 正是程序传进来的**功能号**!
    ;   一开始就是这么坏的:分发器看到的 eax 永远是 0x10(内核数据段选择子),
    ;   于是所有功能都匹配不上,程序打印不出任何东西。先把功能号挪到 EBP 暂存。
    mov ebp, eax
    mov ax, 0x10                        ; 内核数据段(平坦)
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov eax, ebp                        ; 恢复功能号
    call api_dispatch
    pop gs
    pop fs
    pop es
    pop ds
    popad
    iret

api_dispatch:
    cmp eax, 0
    je .print_str
    cmp eax, 1
    je .print_dec
    cmp eax, 2
    je .print_hex
    cmp eax, 3
    je .print_cp
    cmp eax, 4
    je .set_color
    cmp eax, 5
    je .getchar
    ret
.print_str:
    call term_print
    ret
.print_dec:
    mov eax, ebx
    call term_print_dec
    ret
.print_hex:
    mov eax, ebx
    call term_print_hex
    ret
.print_cp:
    mov eax, ebx
    call term_print_cp
    ret
.set_color:
    mov al, bl
    call term_set_color
    ret
.getchar:
    call kbd_getchar                    ; 返回 al
    ret

api_install:
    mov eax, API_VECTOR
    mov ebx, api_stub
    call idt_install
    ret

; 给程序用的说明文件(写进盘里的 README.TXT 内容也在这里,方便一处改)
api_usage:
    db 'JoyOS program API (int 0x30):', 10
    db '  eax=0  print string      esi = UTF-8 string', 10
    db '  eax=1  print decimal     ebx = value', 10
    db '  eax=2  print hex         ebx = value', 10
    db '  eax=3  print codepoint   ebx = unicode (Chinese ok)', 10
    db '  eax=4  set color         bl  = attribute (0x0A = bright green)', 10
    db '  eax=5  wait key          -> al = ASCII', 10
    db 10, 'Build a program with:  nasm -f bin prog.asm -o PROG.BIN', 10
    db '[ORG 0x120000]  then put it on the disk and run it from the shell.', 10
    db 'More (Chinese): docs/programs.md, examples in progs/', 10, 0
