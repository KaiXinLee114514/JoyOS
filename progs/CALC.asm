; ============================================================================
;  CALC.BIN — JoyOS 计算器(用 int 0x30 写的"组件"之一)
;
;  能算:加 减 乘 除、小数点、平方(s)、清零(c)、退格改错、q 退出。
;
;  ── 为什么不用浮点 ──────────────────────────────────────────────────────
;  x87 浮点指令当然能用(fadd/fmul/fsqrt),但"把浮点数打印成十进制"反而更麻烦
;  (精度、舍入、指数范围都得管)。这里用**定点数**:
;
;      1.0 = 1000000          ← 固定 6 位小数
;      12.5 存成 12500000
;      0.001 存成 1000
;
;  加减就是普通 add/sub;乘除要 64 位中间结果(imul/mul 把结果放 edx:eax),
;  算完再乘/除一个 1000000 把小数点挪回来。范围 ±2147.483647,超了报 overflow。
;
;  ── 屏幕 ────────────────────────────────────────────────────────────────
;  全屏程序,靠 int 0x30 的 6(清屏)/9(定位)/13(在指定位置画字)。
;  它不进 shell 的滚动输出流,所以每按一个键只重画自己那几行。
;
;  ── 寄存器约定(见 docs/programs.md)─────────────────────────────────────
;  int 0x30 之后:eax/ebx/esi 是返回值(不保证保留),ecx/edx/edi/ebp 保证不变。
;
;  编译: nasm -f bin progs/CALC.asm -o build/CALC.BIN      运行: run CALC
; ============================================================================

[BITS 32]
[ORG 0x120000]

SCALE       equ 1000000                 ; 定点:1.0 = 1000000
LINE_PAD    equ 78                      ; 每行补到这么宽(擦掉上次的残留)

ROW_TITLE   equ 0
ROW_EXPR    equ 2
ROW_VALUE   equ 4
ROW_NOTE    equ 6
ROW_HELP    equ 9

; ---------------------------------------------------------------------------
;  start:清屏 → 画标题和帮助 → 循环读键
; ---------------------------------------------------------------------------
start:
    call api_clear
    call reset_state
    call draw_frame

.main:
    call draw_all
    call api_key
    cmp eax, 0x100
    jae .main                           ; 方向键之类先不管

    cmp al, '0'
    jb .not_digit
    cmp al, '9'
    ja .not_digit
    call key_digit
    jmp .main
.not_digit:
    mov bl, al                          ; 留着下面比较(bl 不参与调用)
    cmp al, '.'
    je .do_dot
    cmp al, '+'
    je .do_op
    cmp al, '-'
    je .do_op
    cmp al, '*'
    je .do_op
    cmp al, '/'
    je .do_op
    cmp al, '='
    je .do_eq
    cmp al, 's'
    je .do_sq
    cmp al, 'S'
    je .do_sq
    cmp al, 'c'
    je .do_clear
    cmp al, 'C'
    je .do_clear
    cmp al, 8
    je .do_bs
    cmp al, 27                          ; ESC 也当退出
    je .quit
    cmp al, 'q'
    je .quit
    cmp al, 'Q'
    je .quit
    jmp .main

.do_dot:
    call key_dot
    jmp .main
.do_op:
    call key_operator
    jmp .main
.do_eq:
    call key_equals
    jmp .main
.do_sq:
    call key_square
    jmp .main
.do_bs:
    call key_backspace
    jmp .main
.do_clear:
    call reset_state
    jmp .main
.quit:
    call api_clear
    mov bl, 0x07
    call api_color
    mov esi, msg_bye
    call api_puts
    ret                                 ; 回 shell

; ---------------------------------------------------------------------------
;  reset_state:回到刚进来的状态
; ---------------------------------------------------------------------------
reset_state:
    mov dword [acc], 0
    mov dword [have_acc], 0
    mov byte [pending], 0
    mov dword [cur_len], 0
    mov byte [cur_str], 0
    mov byte [expr_str], 0
    mov dword [err_ptr], 0
    ret

; ---------------------------------------------------------------------------
;  draw_frame:标题 + 底部帮助(不变的两行,进来画一次)
; ---------------------------------------------------------------------------
draw_frame:
    mov bl, 0x0B                        ; 亮青
    call api_color
    mov esi, msg_title
    mov ebx, ROW_TITLE
    xor ecx, ecx
    mov edx, 70
    call api_put_at

    mov bl, 0x07                        ; 浅灰
    call api_color
    mov esi, msg_help
    mov ebx, ROW_HELP
    xor ecx, ecx
    mov edx, 100
    call api_put_at
    ret

; ---------------------------------------------------------------------------
;  draw_all:重画"表达式 / 当前值 / 出错信息"三行
; ---------------------------------------------------------------------------
draw_all:
    pushad

    ; ---- 表达式行 ----
    mov edi, line_buf
    mov esi, txt_expr
    call str_copy
    mov esi, expr_str
    call str_copy
    mov esi, cur_str
    call str_copy
    call pad_line                       ; 补空格:上一次的数字更长时要把它盖掉

    mov bl, 0x07
    call api_color
    mov esi, line_buf
    mov ebx, ROW_EXPR
    xor ecx, ecx
    mov edx, 100
    call api_put_at

    ; ---- 当前值行 ----
    mov edi, num_buf
    call current_value                  ; → eax
    call format_fixed                   ; 写成 "12.5"(edi 前进)
    mov byte [edi], 0

    mov edi, line_buf
    mov esi, txt_eq
    call str_copy
    mov esi, num_buf
    call str_copy
    call pad_line

    mov bl, 0x0A                        ; 亮绿
    call api_color
    mov esi, line_buf
    mov ebx, ROW_VALUE
    xor ecx, ecx
    mov edx, 100
    call api_put_at

    ; ---- 出错信息(没有就打空串,把那行擦掉)----
    mov bl, 0x0C                        ; 亮红
    call api_color
    mov esi, [err_ptr]
    test esi, esi
    jnz .err
    mov esi, txt_blank
.err:
    mov edi, err_buf
    call str_copy
    call pad_line_err
    mov esi, err_buf
    mov ebx, ROW_NOTE
    xor ecx, ecx
    mov edx, 100
    call api_put_at

    popad
    ret

; ---------------------------------------------------------------------------
;  current_value:现在该显示哪个数
;    正在输入 → 解析输入的那些字符;没在输入 → 累加器(上次的结果)
; ---------------------------------------------------------------------------
current_value:
    cmp dword [cur_len], 0
    je .acc
    mov esi, cur_str
    call parse_fixed
    ret
.acc:
    mov eax, [acc]
    ret

; ---------------------------------------------------------------------------
;  key_digit:al = '0'..'9' → 接到正在输入的数后面
; ---------------------------------------------------------------------------
key_digit:
    cmp dword [cur_len], 12
    jae .out                            ; 够长了(别撑爆缓冲区)
    mov edx, [cur_len]
    mov [cur_str + edx], al
    inc edx
    mov [cur_len], edx
    mov byte [cur_str + edx], 0
    mov dword [err_ptr], 0
.out:
    ret

; ---------------------------------------------------------------------------
;  key_dot:小数点(一个数里只允许一个)
; ---------------------------------------------------------------------------
key_dot:
    cmp dword [cur_len], 0
    jne .check
    mov byte [cur_str], '0'             ; 一上来就按小数点 → 当 "0."
    mov dword [cur_len], 1
    mov byte [cur_str + 1], 0
.check:
    mov esi, cur_str
.find:
    mov al, [esi]
    test al, al
    jz .append
    cmp al, '.'
    je .out                             ; 已经有了,忽略
    inc esi
    jmp .find
.append:
    cmp dword [cur_len], 12
    jae .out
    mov edx, [cur_len]
    mov byte [cur_str + edx], '.'
    inc edx
    mov [cur_len], edx
    mov byte [cur_str + edx], 0
    mov dword [err_ptr], 0
.out:
    ret

; ---------------------------------------------------------------------------
;  key_backspace:删掉正在输入的最后一个字符
; ---------------------------------------------------------------------------
key_backspace:
    cmp dword [cur_len], 0
    je .out
    dec dword [cur_len]
    mov edx, [cur_len]
    mov byte [cur_str + edx], 0
.out:
    ret

; ---------------------------------------------------------------------------
;  key_operator:al = 运算符
;    先把"上一个运算符 + 刚才输入的数"并掉(链式:1+2+3 每按一次都算一步),
;    再把新运算符挂起来等下一个数。连按两个运算符 = 换一个。
; ---------------------------------------------------------------------------
key_operator:
    mov [op_new], al
    call commit_operand
    cmp dword [err_ptr], 0
    jne .done                           ; 出错了就别往下走
    mov al, [op_new]
    mov [pending], al
    cmp dword [committed], 0
    je .done
    ; 表达式历史记一笔:" 数字 运算符"
    mov esi, txt_space
    call expr_append
    mov esi, last_str
    call expr_append
    mov esi, txt_space
    call expr_append
    mov al, [op_new]
    mov [op_tmp], al
    mov byte [op_tmp + 1], 0
    mov esi, op_tmp
    call expr_append
.done:
    ret

; ---------------------------------------------------------------------------
;  key_equals:把剩下的算完,结果显示出来
; ---------------------------------------------------------------------------
key_equals:
    call commit_operand
    cmp dword [err_ptr], 0
    jne .done
    mov byte [pending], 0
    mov byte [expr_str], 0              ; 结果出来了,表达式清空
    mov dword [have_acc], 0             ; 下一个数字 = 一次新计算
    mov dword [err_ptr], 0
.done:
    ret

; ---------------------------------------------------------------------------
;  key_square:把现在这个数平方(s)
; ---------------------------------------------------------------------------
key_square:
    call commit_operand
    cmp dword [err_ptr], 0
    jne .done
    mov eax, [acc]
    mov esi, eax                        ; 左
    mov edi, eax                        ; 右(同一个数)
    mov bl, '*'
    call calc_fixed
    jc .done                            ; 出错(calc_fixed 已经记下原因)
    mov [acc], eax
    mov dword [have_acc], 1
    mov dword [err_ptr], 0
    mov esi, txt_sq
    call expr_append
.done:
    ret

; ---------------------------------------------------------------------------
;  commit_operand:把正在输入的数(cur_str)按 pending 里的运算符并进 acc
;    · 没有输入 → 什么都不做(只是换了个运算符)
;    · have_acc = 0 → 这是第一个数,直接当累加器
;    · 出错 → err_ptr 记下原因,输入清掉
;  committed 标记"这次真的并进去一个数"(表达式显示要用)
; ---------------------------------------------------------------------------
commit_operand:
    pushad
    mov dword [committed], 0
    cmp dword [cur_len], 0
    je .nothing
    mov esi, cur_str
    call parse_fixed
    mov [op_val], eax
    mov edi, last_str                   ; 记下这个数的字符串(表达式显示用)
    mov esi, cur_str
    call str_copy
    mov byte [edi], 0
    mov dword [committed], 1

    cmp dword [have_acc], 0
    jne .have
    mov eax, [op_val]
    mov [acc], eax
    mov dword [have_acc], 1
    jmp .clear

.have:
    mov al, [pending]
    test al, al
    jz .clear                           ; 没有待办运算符:只是换个数值
    mov esi, [acc]
    mov edi, [op_val]
    mov bl, al
    call calc_fixed
    jc .fail
    mov [acc], eax

.clear:
    mov byte [pending], 0
    mov dword [cur_len], 0
    mov byte [cur_str], 0
    popad
    ret
.fail:
    mov dword [cur_len], 0              ; 出错了:把输入清掉,err_ptr 已经写好
    mov byte [cur_str], 0
    popad
    ret
.nothing:
    popad
    ret

; ---------------------------------------------------------------------------
;  calc_fixed:esi = 左,edi = 右,bl = 运算符 → eax = 结果,CF=1 = 出错
;    加减:直接算,查溢出标志
;    乘:  (|a| × |b|) / SCALE,64 位中间结果(mul 给 edx:eax)
;    除:  (|a| × SCALE) / |b|,除 0 报错
;  全都先取绝对值算、再补符号 —— 32 位有符号除法那几个坑就绕开了。
;  出错时 err_ptr 指向原因字符串。
; ---------------------------------------------------------------------------
calc_fixed:
    push ebx
    push ecx
    push edx
    push ebp

    cmp bl, '+'
    je .add
    cmp bl, '-'
    je .sub
    cmp bl, '*'
    je .mul
    cmp bl, '/'
    je .div
    jmp .bad

.add:
    mov eax, esi
    add eax, edi
    jo .bad
    jmp .out
.sub:
    mov eax, esi
    sub eax, edi
    jo .bad
    jmp .out

.mul:
    xor ebp, ebp                        ; ebp bit0 = 结果是负的?
    mov eax, esi
    test eax, eax
    jns .m1
    neg eax
    xor ebp, 1
.m1:
    mov ecx, edi
    test ecx, ecx
    jns .m2
    neg ecx
    xor ebp, 1
.m2:
    mul ecx                             ; edx:eax = |a| × |b|
    mov ecx, SCALE
    cmp edx, ecx                        ; 商超过 32 位就先停下(不然 div 会炸 CPU 异常)
    jae .bad
    div ecx                             ; eax = a×b/SCALE
    cmp eax, 0x7FFFFFFF
    ja .bad
    test ebp, ebp
    jz .out
    neg eax
    jmp .out

.div:
    test edi, edi
    jz .divzero
    xor ebp, ebp
    mov eax, esi
    test eax, eax
    jns .d1
    neg eax
    xor ebp, 1
.d1:
    mov ecx, edi
    test ecx, ecx
    jns .d2
    neg ecx
    xor ebp, 1
.d2:
    mov edx, SCALE
    mul edx                             ; edx:eax = |a| × SCALE
    cmp edx, ecx
    jae .bad
    div ecx
    cmp eax, 0x7FFFFFFF
    ja .bad
    test ebp, ebp
    jz .out
    neg eax
    jmp .out

.divzero:
    mov dword [err_ptr], msg_divzero
    jmp .bad_keep
.bad:
    cmp dword [err_ptr], 0
    jne .bad_keep
    mov dword [err_ptr], msg_overflow
.bad_keep:
    pop ebp
    pop edx
    pop ecx
    pop ebx
    stc
    ret
.out:
    pop ebp
    pop edx
    pop ecx
    pop ebx
    clc
    ret

; ---------------------------------------------------------------------------
;  parse_fixed:esi = 十进制字符串 → eax = 定点值
;  只认数字和一个小数点(别的字符跳过),开头 "-" 算负数。
; ---------------------------------------------------------------------------
parse_fixed:
    push ebx
    push ecx
    push edx
    push ebp
    push esi
    xor ebx, ebx                        ; 整数部分
    xor ecx, ecx                        ; 小数部分
    xor edx, edx                        ; 0 = 整数段,1 = 小数段
    mov dword [pf_digits], 0
    xor ebp, ebp                        ; 负号
    cmp byte [esi], '-'
    jne .loop
    mov ebp, 1
    inc esi
.loop:
    mov al, [esi]
    test al, al
    jz .done
    inc esi
    cmp al, '.'
    je .dot
    cmp al, '0'
    jb .loop
    cmp al, '9'
    ja .loop
    sub al, '0'
    movzx eax, al
    test edx, edx
    jnz .frac
    imul ebx, ebx, 10
    add ebx, eax
    jmp .loop
.frac:
    cmp dword [pf_digits], 6
    jae .loop                           ; 第 7 位以后丢掉(定点只要 6 位)
    imul ecx, ecx, 10
    add ecx, eax
    inc dword [pf_digits]
    jmp .loop
.dot:
    mov edx, 1
    jmp .loop
.done:
    mov edx, 6
    sub edx, [pf_digits]                ; 差几位就补几个 0
    jz .no_pad
.pad:
    imul ecx, ecx, 10
    dec edx
    jnz .pad
.no_pad:
    ; ★ 缩放要按 64 位算:99999 这种"整数部分就超范围"的数,
    ;   imul eax, eax, SCALE 会直接绕回来变成一个小数,看起来还挺像回事(实测踩过)。
    mov eax, ebx
    mov edx, SCALE
    mul edx                             ; edx:eax = 整数部分 × SCALE
    add eax, ecx                        ; 加上小数部分
    adc edx, 0
    test edx, edx
    jnz .toobig
    cmp eax, 0x7FFFFFFF
    ja .toobig
    test ebp, ebp
    jz .pos
    neg eax
.pos:
    jmp .out
.toobig:
    mov dword [err_ptr], msg_overflow
    mov eax, 0x7FFFFFFF                 ; 夹到能表示的最大值,显示上不会太离谱
    test ebp, ebp
    jz .out
    neg eax
.out:
    pop esi
    pop ebp
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  format_fixed:eax = 定点值 → 写成 "12.5" 这样的字符串(edi 前进)
;  小数尾巴上的 0 去掉;整数就不带小数点。
; ---------------------------------------------------------------------------
format_fixed:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    test eax, eax
    jns .pos
    mov byte [edi], '-'
    inc edi
    neg eax
.pos:
    xor edx, edx
    mov ecx, SCALE
    div ecx                             ; eax = 整数,edx = 小数
    mov [ff_frac], edx
    call u32_dec                        ; 整数部分(edi 前进)
    mov byte [edi], '.'
    mov [ff_dot], edi                   ; 记下小数点位置(回头好删)
    inc edi
    mov esi, ff_divs                    ; 100000 10000 1000 100 10 1
    mov ecx, 6
.frac:
    mov eax, [ff_frac]
    xor edx, edx
    div dword [esi]
    mov [ff_frac], edx                  ; 余数留给下一位
    add al, '0'
    mov [edi], al
    inc edi
    add esi, 4
    dec ecx
    jnz .frac
.trim:
    cmp edi, [ff_dot]
    jbe .trimmed
    cmp byte [edi - 1], '0'
    jne .trimmed
    dec edi
    jmp .trim
.trimmed:
    ; 小数全部是 0 时 edi 停在"小数点后面那一格"(ff_dot+1),这时连点一起删
    mov eax, [ff_dot]
    inc eax
    cmp edi, eax
    jne .done                           ; 还有真正的小数位 → 保留小数点
    mov edi, [ff_dot]
.done:
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  u32_dec:eax = 数值 → 十进制写进 edi(edi 前进)
; ---------------------------------------------------------------------------
u32_dec:
    push eax
    push ebx
    push ecx
    push edx
    mov ebx, 10
    xor ecx, ecx
.divide:
    xor edx, edx
    div ebx
    push edx                            ; 余数入栈 → 出栈自然逆序
    inc ecx
    test eax, eax
    jnz .divide
.emit:
    pop eax
    add al, '0'
    mov [edi], al
    inc edi
    dec ecx
    jnz .emit
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  str_copy:esi → edi(edi 前进),到 0 结束
; ---------------------------------------------------------------------------
str_copy:
    push eax
.loop:
    mov al, [esi]
    test al, al
    jz .done
    mov [edi], al
    inc esi
    inc edi
    jmp .loop
.done:
    pop eax
    ret

; ---------------------------------------------------------------------------
;  str_len:esi = 串 → eax = 长度
; ---------------------------------------------------------------------------
str_len:
    push esi
    xor eax, eax
.loop:
    cmp byte [esi], 0
    je .done
    inc esi
    inc eax
    jmp .loop
.done:
    pop esi
    ret

; ---------------------------------------------------------------------------
;  pad_line:edi = 这一行现在的结尾 → 用空格补到 LINE_PAD 格,再补个 0
;
;  为什么必须补:终端只会"覆盖写",不会自动擦。上一次的数字更长时,
;  尾巴上的旧字符会留在屏幕上(现象是 "1.00.1 *1000" 这种鬼东西)。
;
;  ★ 这里踩过一个坑:一开始是用 str_len 数"到第一个 0 为止"来算已经写了多长 ——
;    可缓冲区里还留着上一次的内容,数出来的是**旧长度**,于是补了 0 个空格,
;    旧尾巴原样留在屏幕上。正确做法是拿"这次真写到哪了"(edi)来算。
; ---------------------------------------------------------------------------
pad_line:
    push eax
    push ecx
    mov eax, edi
    sub eax, line_buf
    mov ecx, LINE_PAD
    sub ecx, eax
    jle .done
.fill:
    mov byte [edi], ' '
    inc edi
    dec ecx
    jnz .fill
.done:
    mov byte [edi], 0
    pop ecx
    pop eax
    ret

pad_line_err:                           ; 出错那行用的是另一个缓冲区
    push eax
    push ecx
    mov eax, edi
    sub eax, err_buf
    mov ecx, LINE_PAD
    sub ecx, eax
    jle .done
.fill:
    mov byte [edi], ' '
    inc edi
    dec ecx
    jnz .fill
.done:
    mov byte [edi], 0
    pop ecx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  expr_append:把 esi 追加到 expr_str 尾巴上
; ---------------------------------------------------------------------------
expr_append:
    push esi
    mov esi, expr_str
    call str_len
    mov edi, expr_str
    add edi, eax
    pop esi
    call str_copy
    mov byte [edi], 0
    ret

; ---------------------------------------------------------------------------
;  int 0x30 的包装 —— ★ 它们不能放在文件最前面:
;  程序被加载到 0x120000,内核从**文件第一个字节**开始执行([ORG] 定的就是它),
;  所以入口(start)必须是第一段代码。这里一开始写反了:文件开头是 api_clear,
;  于是 `run CALC` 一闪就回 shell —— 它只执行了"清屏"那一句就 ret 了。
;  要么把入口放最前,要么第一句就 jmp start。
; ---------------------------------------------------------------------------
; ---------------------------------------------------------------------------
;  把 int 0x30 包一层,代码里看着像函数
; ---------------------------------------------------------------------------
api_clear:                              ; 清屏(eax=6)
    mov eax, 6
    int 0x30
    ret

api_puts:                               ; esi = 字符串(eax=0)
    mov eax, 0
    int 0x30
    ret

api_color:                              ; bl = 属性字节(eax=4)
    mov eax, 4
    int 0x30
    ret

api_key:                                ; → eax = 键事件(eax=10)
    mov eax, 10
    int 0x30
    ret

api_put_at:                             ; esi=串 ebx=行 ecx=列 edx=最多几格(eax=13)
    mov eax, 13
    int 0x30
    ret

; ---------------------------------------------------------------------------
;  数据
; ---------------------------------------------------------------------------
msg_title     db 'JoyOS calculator  (fixed point, 6 decimals, range +-2147.483647)', 0
msg_help      db '0-9 . + - * / =    s square    c clear    backspace    q quit', 0
msg_bye       db 'calculator closed.', 10, 0
msg_overflow  db 'overflow! range is +-2147.483647', 0
msg_divzero   db 'cannot divide by zero', 0
txt_expr      db 'expr: ', 0
txt_eq        db '   =  ', 0
txt_space     db ' ', 0
txt_sq        db ' [sq]', 0
txt_blank     db 0

acc         dd 0
have_acc    dd 0
committed   dd 0
pending     db 0
op_new      db 0
op_val      dd 0
err_ptr     dd 0
pf_digits   dd 0
ff_frac     dd 0
ff_dot      dd 0

ff_divs   dd 100000, 10000, 1000, 100, 10, 1

cur_str   times 16 db 0
cur_len   dd 0
expr_str  times 128 db 0
last_str  times 16 db 0
op_tmp    times 4 db 0
line_buf  times 192 db 0
err_buf   times 96 db 0
num_buf   times 32 db 0
