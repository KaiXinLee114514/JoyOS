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
;      5  等一个按键        → 返回 al = ASCII(方向键之类会被跳过)
;      6  清屏              → 光标回左上角
;      7  读文件            esi = 文件名,edi = 缓冲区,ecx = 最多读几字节
;                           → eax = 实际字节数,失败 = -1
;      8  写文件            esi = 文件名,edi = 数据,ecx = 字节数
;                           → eax = 0 成功,-1 失败(没挂载/盘满)
;      9  定位光标          ebx = 行,ecx = 列(从 0 开始,超界自动夹住)
;      10 等一个键事件      → eax = ASCII;扩展键 = 0x100+编号
;                           (1 上 2 下 3 左 4 右 5 Home 6 End 7 Del 8 PgUp 9 PgDn)
;      11 屏幕尺寸          → eax = 每行几个字符格,ebx = 几行
;      12 取程序参数        → esi = 参数字符串(`run PROG 参数` 里那截,没有就是 "")
;      13 在指定位置画字    esi = 字符串,ebx = 行,ecx = 列,edx = 最多几格
;                           → eax = 实际占几格(不滚屏,编辑器重画一行用)
;      14 蜂鸣器(嘀)       ebx = 频率 Hz,ecx = 持续毫秒(频率 <= 0 = 静音等这么久,
;                           谱子里的休止符就靠它);音高准、时值是估的,见 speaker.asm
;
;  别的功能号会被忽略。程序直接 ret 就回到 shell,不用专门"返回"。
;
;  ── 寄存器约定(重要)────────────────────────────────────────────────────
;  返回值和参数都走寄存器,所以**返回值放哪几个寄存器,哪几个就是"调用后不保证"**:
;      eax / ebx / esi  → 可能是返回值(没有返回值时就是调用前那点残留)
;      ecx / edx / edi / ebp → 保证不变
;  这是 api_stub 里 pushad/popad 之外**特意写回去**的三个槽位:光 pushad/popad
;  的话返回值会被 popad 一起还原掉,程序永远收不到结果(这个坑很隐蔽)。
;
;  这七个是"全屏程序"最小的一套:能清屏、能定位、能画指定位置、能收方向键、
;  能读写文件、能拿参数。calculator 和 editor 就是这么写出来的(progs/)。
;
;  这样接口就"冻结"了:内核怎么改,程序的 int 0x30 永远有效。
;  程序本身用 nasm 编成平铺二进制,被 shell 的 run 命令读进 0x120000 后 call 进去,
;  所以程序里的 [ORG 0x120000] 要和 kernel/shell.asm 里的 PROG_ADDR 一致。
; ============================================================================

API_VECTOR  equ 0x30                    ; 用哪个中断号(0x20-0x2F 是硬件中断,所以挑 0x30)

; ---------------------------------------------------------------------------
;  程序参数块:`run EDIT NOTES.TXT` 里那截 "NOTES.TXT" 由 shell 写在这儿
;      +0  magic 'JARG'(4 字节;为 0 表示这次没有参数)
;      +4  参数字符串(0 结尾)
;  这块内存不在内核镜像里(镜像到 0x20000 就完了),直接借 0x11F000 这 4 KB ——
;  它在 FILE_BUF(0x110000,cat 用)之上、程序加载区 PROG_ADDR(0x120000)之下,
;  所以 cat 的大文件和程序本身都不会踩到它(cat 那边有大小上限)。
; ---------------------------------------------------------------------------
PROG_ARG_ADDR equ 0x11F000
PROG_ARG_STR  equ PROG_ARG_ADDR + 4
PROG_ARG_MAX  equ 2048                  ; 参数字符串最多这么长

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
    ; ★ 把返回值写回"待会儿 popad 要还给程序的那三个槽位"。
    ;   pushad 压栈顺序是 eax,ecx,edx,ebx,esp,ebp,esi,edi(edi 在栈顶),
    ;   所以 popad 读的是 [esp+0]=edi [esp+4]=esi [esp+8]=ebp [esp+16]=ebx [esp+28]=eax。
    ;   不写回去的话,程序调用 int 0x30 拿不到任何返回值。
    mov [esp + 28], eax                 ; 返回值:对 eax
    mov [esp + 16], ebx                 ;          ebx
    mov [esp + 4], esi                  ;          esi
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
    cmp eax, 6
    je .clear
    cmp eax, 7
    je .read_file
    cmp eax, 8
    je .write_file
    cmp eax, 9
    je .set_cursor
    cmp eax, 10
    je .getkey
    cmp eax, 11
    je .size
    cmp eax, 12
    je .get_arg
    cmp eax, 13
    je .puts_at
    cmp eax, 14
    je .beep
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
.clear:
    call term_clear
    ret
; ---- 读文件:esi = 名字,edi = 缓冲区,ecx = 上限 ----
.read_file:
    mov [api_name], esi                 ; 先存原始名字(可能带目录)
    mov [api_buf], edi
    mov [api_max], ecx
    mov esi, [api_name]                 ; 支持 DOCS/NOTE.TXT(相对当前目录)
    call fat_path
    jc .read_fail
    mov [api_name], eax                 ; 剩下这截才是文件名
    mov esi, eax
    call fat_stat                       ; 先问大小:超了就不读(免得盖掉后面的内存)
    cmp eax, -1
    je .read_fail
    cmp eax, [api_max]
    ja .read_fail
    mov esi, [api_name]
    mov edi, [api_buf]
    call fat_read_file
    cmp eax, -1
    je .read_fail
    ret
.read_fail:
    mov eax, -1
    ret
; ---- 写文件:esi = 名字,edi = 数据,ecx = 字节数 ----
.write_file:
    mov [api_name], esi                 ; 同样支持带目录的名字
    mov [api_buf], edi
    mov [api_max], ecx
    mov esi, [api_name]
    call fat_path
    jc .write_fail
    mov esi, eax
    mov edi, [api_buf]
    mov ecx, [api_max]
    call fat_write_file
    ret
.write_fail:
    mov eax, -1
    ret
.set_cursor:
    call term_set_cursor
    ret
.getkey:
    call kbd_getkey
    ret
.size:
    call term_size
    ret
.get_arg:
    mov esi, PROG_ARG_STR
    cmp dword [PROG_ARG_ADDR], 'JARG'
    je .arg_ok
    mov esi, api_empty                  ; 没有参数:给个空串,程序不用自己判空
.arg_ok:
    ret
.puts_at:
    call term_puts_at
    ret
; ---- 蜂鸣器:ebx = 频率 Hz,ecx = 持续毫秒 ----
;  参数本来就是按 beep 要的顺序放的,直接转给驱动;ecx 是"输入"不是返回值,
;  而且 speaker_beep 会把它原样还回来,所以不影响上面那条寄存器约定。
.beep:
    call speaker_beep
    ret

api_install:
    mov eax, API_VECTOR
    mov ebx, api_stub
    call idt_install
    ret

; 给程序用的说明文件(裸敲 run 就能看到;progs/README.TXT 里也抄了一份)
api_usage:
    db 'JoyOS program API (int 0x30)  -- eax = function', 10
    db '  0 print string   esi=utf-8    1 print decimal  ebx', 10
    db '  2 print hex      ebx          3 print codepoint ebx', 10
    db '  4 set color      bl           5 wait key       -> al', 10
    db '  6 clear screen                7 read file   esi name, edi buf, ecx max -> eax size/-1', 10
    db '  8 write file     esi name, edi data, ecx len -> eax 0/-1', 10
    db '  9 set cursor     ebx row, ecx col', 10
    db ' 10 wait key event -> eax: ascii, or 0x100+n', 10
    db '    n: 1 up 2 down 3 left 4 right 5 home 6 end 7 del 8 pgup 9 pgdn', 10
    db ' 11 screen size    -> eax cols, ebx rows', 10
    db ' 12 program arg    -> esi (run MYPROG hello 里的 hello)', 10
    db ' 13 puts at        esi str, ebx row, ecx col, edx max cells', 10
    db ' 14 beep           ebx freq hz, ecx ms (freq<=0: silent wait)', 10
    db 10, 'Build:  nasm -f bin prog.asm -o PROG.BIN   ([BITS 32] [ORG 0x120000])', 10
    db 'Install: tools/mkfat.py build/joyos-hd.img 6144 8 PROG.BIN=PROG.BIN', 10
    db 'Run:    run PROG          (more in progs/, docs/programs.md)', 10, 0

; ---- 程序接口用的数据 ----
api_empty   db 0                        ; "没有参数"时给程序的空字符串
api_name    dd 0
api_buf     dd 0
api_max     dd 0
