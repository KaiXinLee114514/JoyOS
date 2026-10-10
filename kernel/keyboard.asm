; ============================================================================
;  JoyOS (胡闹OS) — PS/2 键盘(中断方式)
;
;  ── 为什么必须重映射 8259A ──────────────────────────────────────────────
;  开机时 BIOS 把 PIC 的中断映射到 0x08~0x0F / 0x70~0x77,可 0x08~0x0F
;  在保护模式里**已经被 CPU 异常占用了**(0x08 双重故障、0x0D 通用保护...)。
;  所以第一件事是把 PIC 重映射到 0x20~0x2F:IRQ0→0x20,IRQ1→0x21(键盘)。
;  不重映射的话,你一敲键盘就会跳进"双重故障"。
;
;  ── 数据从哪来 ──────────────────────────────────────────────────────────
;  键盘控制器(8042)把**扫描码**(不是字符)放在 0x60 端口,并拉一根 IRQ1。
;  扫描码只是"哪个键的位置",跟字符没有关系 —— 所以要有翻译表:
;      sc_lo[]  = 不按 Shift 时的字符
;      sc_hi[]  = 按着 Shift 时的字符
;      bit7=1 的扫描码是"松键",要忽略(Shift 的松键要处理,否则一直算按住)
;  大小写:字母是 "Shift XOR Caps Lock"(两个都开 = 小写,和真键盘一样);
;  数字/符号只看 Shift。Caps Lock 按一下翻状态,顺便给键盘发 0xED 点灯。
;  小键盘/数字锁定先不管(注释里标了)。
;
;  ── 为什么用环形缓冲区 ──────────────────────────────────────────────────
;  中断随时会来,可能比程序"取字符"快得多。所以中断只往缓冲区里塞,
;  取字符的程序慢慢取;缓冲区满了就丢掉新的(总比覆盖还没读的强)。
;
;  ── 扩展键(方向键那一家子)───────────────────────────────────────────
;  方向键之类的键,键盘先发一个 0xE0 前缀,再发真正的扫描码。裸塞进去的话,
;  "上"就只剩一个 0x48 —— 和字符 'H' 分不清了。所以:
;      扩展键 → 往缓冲区塞两个字节:0x1B(ESC) + (0x80 | 编号)
;  编号表见 sc_ext:1 上 2 下 3 左 4 右 5 Home 6 End 7 Delete 8 PgUp 9 PgDn。
;  用 0x80 起是因为普通按键翻出来的字符都 < 0x80,两者永远不会撞。
;  单敲 ESC 键只塞一个 0x1B(后面没跟着 0x8x),取键时两种情况分得开。
;
;  ── Ctrl ────────────────────────────────────────────────────────────────
;  按住 Ctrl 再按字母 → 塞控制码(字母 & 0x1F,Ctrl-S = 0x13)。
;  编辑器那种"不占屏幕的快捷键"就靠它。
; ============================================================================

PIC1_CMD   equ 0x20                    ; 主片:命令口
PIC1_DAT   equ 0x21                    ; 主片:数据口(写它 = 设置屏蔽位)
PIC2_CMD   equ 0xA0
PIC2_DAT   equ 0xA1
KBD_DATA   equ 0x60                    ; 读它 = 取扫描码
KBD_STATUS equ 0x64
PIC_EOI    equ 0x20

IRQ_BASE   equ 0x20                    ; 重映射后:IRQ0 = 0x20
KBD_VECTOR equ IRQ_BASE + 1            ; 键盘 = IRQ1 = 0x21

KBD_BUF_SIZE equ 64                    ; 必须是 2 的幂(取模用 and)

; ---------------------------------------------------------------------------
;  kbd_init:重映射 PIC → 装中断入口 → 只放行键盘 → 开中断
; ---------------------------------------------------------------------------
kbd_init:
    pushad

    ; ---- 1) 重映射 8259A ----
    mov al, 0x11                       ; ICW1:开始初始化 + 需要 ICW4
    out PIC1_CMD, al
    out 0x80, al                       ; 给老机器一点时间(io_wait)
    out PIC2_CMD, al
    out 0x80, al

    mov al, IRQ_BASE                   ; ICW2:主片中断号从 0x20 开始
    out PIC1_DAT, al
    out 0x80, al
    mov al, IRQ_BASE + 8               ; 从片从 0x28 开始
    out PIC2_DAT, al
    out 0x80, al

    mov al, 0x04                       ; ICW3:从片接在主片 IRQ2 上
    out PIC1_DAT, al
    out 0x80, al
    mov al, 0x02                       ; 从片:自己的编号
    out PIC2_DAT, al
    out 0x80, al

    mov al, 0x01                       ; ICW4:8086 模式
    out PIC1_DAT, al
    out 0x80, al
    out PIC2_DAT, al
    out 0x80, al

    mov al, 0xFF                       ; 先把所有中断都屏蔽掉
    out PIC1_DAT, al
    out PIC2_DAT, al

    ; ---- 2) 装中断入口(0x21 → irq1_stub)----
    mov eax, KBD_VECTOR
    mov ebx, irq1_stub
    call idt_install

    ; ---- 3) 只放行 IRQ1(键盘):屏蔽字 bit1 = 0 ----
    mov al, 0xFD
    out PIC1_DAT, al

    ; ---- 4) 清掉可能积压的一个扫描码 ----
    in al, KBD_STATUS
    test al, 1
    jz .no_pending
    in al, KBD_DATA
.no_pending:

    sti                                ; 可以开始收中断了
    popad
    ret

; ---------------------------------------------------------------------------
;  中断入口:栈格式和异常保持一致(假错误码 + 向量号)
; ---------------------------------------------------------------------------
irq1_stub:
    push dword 0
    push dword KBD_VECTOR
    jmp irq_common

irq_common:
    pushad
    call keyboard_irq
    popad
    add esp, 8                         ; 丢掉"向量号 + 假错误码"
    iret

; ---------------------------------------------------------------------------
;  keyboard_irq:真正的键盘处理
; ---------------------------------------------------------------------------
keyboard_irq:
    push eax
    push ebx
    push ecx
    push edx

    in al, KBD_DATA                    ; 扫描码必须读走,否则控制器不再中断
    mov bl, al

    ; ---- 前缀字节:0xE0/0xE1 后面的那个扫描码是"扩展键" ----
    cmp bl, 0xE0
    je .prefix
    cmp bl, 0xE1
    je .prefix
    cmp byte [ext_pending], 0
    jne .extended

    ; ---------------- 普通键 ----------------
    test bl, 0x80                      ; bit7=1 → 松键
    jnz .release

    cmp bl, 0x2A                       ; 左 Shift
    je .shift_on
    cmp bl, 0x36                       ; 右 Shift
    je .shift_on
    cmp bl, 0x1D                       ; 左 Ctrl
    je .ctrl_on
    cmp bl, 0x38                       ; 左 Alt:开始"码位输入"
    je .alt_on
    ; ---- Alt 按着的时候:数字键是在敲码位,不进正常缓冲 ----
    cmp byte [alt_down], 0
    je .not_alt_digit
    movzx ecx, bl
    cmp ecx, 0x02                      ; 主键盘 1..9
    jb .alt_cancel
    cmp ecx, 0x0A                      ; 9
    jbe .alt_digit
    cmp ecx, 0x0B                      ; 0
    je .alt_digit
.alt_cancel:                           ; Alt 期间按了别的键 → 当取消,正常处理这个键
    mov byte [alt_len], 0
    jmp .not_alt_digit
.alt_digit:
    mov al, [sc_lo + ecx]              ; 数字字符('0'..'9')
    movzx ecx, byte [alt_len]
    cmp ecx, 6                         ; 最多 6 位(0x10FFFF 也就 7 位,留余量)
    jae .done
    mov [alt_buf + ecx], al
    inc byte [alt_len]
    jmp .done                          ; 数字被吃掉,不回显(松开 Alt 时直接出字)
.not_alt_digit:
    cmp bl, 0x3A                       ; Caps Lock:翻一下状态,顺便点灯
    je .caps_toggle

    movzx ecx, bl
    cmp ecx, 0x80
    jae .done
    mov dl, [sc_lo + ecx]              ; 不按 Shift 时这个键是什么
    cmp dl, 'a'                        ; 字母才受 Caps Lock 影响
    jb .not_letter
    cmp dl, 'z'
    ja .not_letter
    ; ---- 字母:大写 = Shift XOR Caps Lock(两个都开反而变小写,和真键盘一样)----
    mov al, dl
    mov dh, [shift_down]
    xor dh, [caps_down]
    test dh, 1
    jz .translated
    mov al, [sc_hi + ecx]
    jmp .translated
.not_letter:
    mov al, dl
    test byte [shift_down], 1          ; 数字/符号只看 Shift
    jz .translated
    mov al, [sc_hi + ecx]              ; 按着 Shift 就用另一张表
.translated:
    test al, al                        ; 0 = 这个键我们不认识
    jz .done
    cmp byte [ctrl_down], 0            ; Ctrl + 字母 → 控制码(Ctrl-S = 0x13)
    je .push
    cmp dl, 'a'                        ; 用 sc_lo 那一栏算,免得 Shift/Caps 把 Ctrl 弄丢
    jb .push
    cmp dl, 'z'
    ja .push
    mov al, dl
    sub al, 'a' - 1
.push:
    call kbd_push
    jmp .done

.caps_toggle:
    xor byte [caps_down], 1
    call kbd_set_leds                  ; 尽量把键盘上的灯也点对(点不亮不影响打字)
    jmp .done

    ; ---------------- 扩展键(前缀已经收到)----------------
.extended:
    mov byte [ext_pending], 0
    test bl, 0x80
    jnz .done                          ; 扩展键的松开:忽略
    movzx ecx, bl
    cmp ecx, 0x80
    jae .done
    mov al, [sc_ext + ecx]
    test al, al
    jz .done                           ; 表里是 0 = 这个扩展键我们不管
    mov [ext_code], al
    ; ---- Ctrl + ←/→ :换 shell(编号 3 = 左、4 = 右,见 sc_ext)----
    ;      在键盘中断里直接切:活动的 shell 就算正卡在程序里,键盘也照样能换手。
    ;      不压 ESC+编号 —— 不然等着读方向键的代码会当成方向键吃掉。
    test byte [ctrl_down], 1
    jz .ext_normal
    cmp al, 3
    je .ext_shell_left
    cmp al, 4
    je .ext_shell_right
.ext_normal:
    mov al, 27                         ; 先塞 ESC …
    call kbd_push
    mov al, [ext_code]
    or al, 0x80                        ; … 再塞 0x80|编号
    call kbd_push
    jmp .done
.ext_shell_left:
    mov al, -1
    call shell_switch_step
    jmp .done
.ext_shell_right:
    mov al, 1
    call shell_switch_step
    jmp .done

.prefix:
    mov byte [ext_pending], 1
    jmp .done

    ; ---------------- 松开 ----------------
.release:
    and bl, 0x7F
    cmp bl, 0x2A
    je .shift_off
    cmp bl, 0x36
    je .shift_off
    cmp bl, 0x1D
    je .ctrl_off
    cmp bl, 0x38                       ; 松开 Alt → 把攒的数字变成一个字符
    je .alt_off
    jmp .done

.shift_on:
    mov byte [shift_down], 1
    jmp .done
.shift_off:
    mov byte [shift_down], 0
    jmp .done
.ctrl_on:
    mov byte [ctrl_down], 1
    jmp .done

; ---------------------------------------------------------------------------
;  Alt 输入:按住 Alt 敲十进制码位,松开 Alt 就把它变成一个 UTF-8 字符塞进
;  按键缓冲(编辑器/shell 收到的就是普通字节,和输入法无关)。
;      例:Alt 按着打 20013,松开 → 屏幕上出现 "中"
;  为什么用十进制:和 Windows 的 Alt+小键盘一样,而且不用记十六进制字母。
; ---------------------------------------------------------------------------
.alt_off:
    mov byte [alt_down], 0
    movzx ecx, byte [alt_len]
    mov byte [alt_len], 0
    test ecx, ecx
    jz .done                           ; 没敲数字 = 只是按了一下 Alt,忽略
    ; ---- 把十进制字符串转成码位(eax)----
    xor eax, eax
    xor edx, edx
    mov esi, alt_buf
.alt_parse:
    movzx ebx, byte [esi]
    inc esi
    sub bl, '0'
    imul eax, eax, 10
    add eax, ebx
    dec ecx
    jnz .alt_parse
    cmp eax, 0x10FFFF                  ; 超过 Unicode 上限就当没敲
    ja .done
    test eax, eax
    jz .done
    ; ---- 码位 → UTF-8(1~4 字节)----
    cmp eax, 0x7F
    ja .u2
    call kbd_push
    jmp .done
.u2:
    cmp eax, 0x7FF
    ja .u3
    mov ecx, eax
    shr eax, 6
    or al, 0xC0
    call kbd_push
    mov eax, ecx
    and al, 0x3F
    or al, 0x80
    call kbd_push
    jmp .done
.u3:
    cmp eax, 0xFFFF
    ja .u4
    mov ecx, eax
    shr eax, 12
    or al, 0xE0
    call kbd_push
    mov eax, ecx
    shr eax, 6
    and al, 0x3F
    or al, 0x80
    call kbd_push
    mov eax, ecx
    and al, 0x3F
    or al, 0x80
    call kbd_push
    jmp .done
.u4:
    mov ecx, eax
    shr eax, 18
    or al, 0xF0
    call kbd_push
    mov eax, ecx
    shr eax, 12
    and al, 0x3F
    or al, 0x80
    call kbd_push
    mov eax, ecx
    shr eax, 6
    and al, 0x3F
    or al, 0x80
    call kbd_push
    mov eax, ecx
    and al, 0x3F
    or al, 0x80
    call kbd_push
    jmp .done
.alt_on:
    mov byte [alt_down], 1
    mov byte [alt_len], 0              ; 重新开始数
    jmp .done
.ctrl_off:
    mov byte [ctrl_down], 0

.done:
    mov al, PIC_EOI                    ; 告诉 PIC"这条中断处理完了"
    out PIC1_CMD, al
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  kbd_push:把 al 里的字符放进环形缓冲区(满了就丢)
; ---------------------------------------------------------------------------
kbd_push:
    push eax
    push ebx
    push ecx
    mov ebx, [kbd_head]
    mov ecx, ebx
    inc ecx
    and ecx, KBD_BUF_SIZE - 1
    cmp ecx, [kbd_tail]                ; 追上 tail 说明满了
    je .full
    mov [kbd_buf + ebx], al
    mov [kbd_head], ecx
.full:
    pop ecx
    pop ebx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  kbd_avail:缓冲区里现在有几个字节(读 head/tail 时关中断)
; ---------------------------------------------------------------------------
kbd_avail:
    cli
    push ebx
    mov eax, [kbd_head]
    mov ebx, [kbd_tail]
    sti
    sub eax, ebx
    and eax, KBD_BUF_SIZE - 1
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  kbd_consume:从队尾丢掉 ecx 个字节
; ---------------------------------------------------------------------------
kbd_consume:
    push eax
    cli
    mov eax, [kbd_tail]
    add eax, ecx
    and eax, KBD_BUF_SIZE - 1
    mov [kbd_tail], eax
    sti
    pop eax
    ret

; ---------------------------------------------------------------------------
;  kbd_seq_len:看队尾这两个字节是不是"ESC + 0x80|编号"
;              是 → eax = 1(并且 edx = 编号),不是 → eax = 0
;  ★ 这里踩过一个坑:`call kbd_avail` 会把 eax 改成"缓冲区里有几个字节",
;    所以"不是序列"那条路**必须显式把 eax 清零** —— 不然返回的是个数(2、3…),
;    调用方以为"这是个方向键",一次吃掉两个字节还把它翻译成扩展键,
;    结果打字全乱(表现为"键盘失灵",其实是取键的那头吃错了)。
; ---------------------------------------------------------------------------
kbd_seq_len:
    push ebx
    push ecx
    call kbd_avail
    cmp eax, 2
    jb .no                              ; 只有一个字节,肯定不是序列
    mov ebx, [kbd_tail]
    cmp byte [kbd_buf + ebx], 27
    jne .no
    inc ebx
    and ebx, KBD_BUF_SIZE - 1
    movzx edx, byte [kbd_buf + ebx]
    mov ecx, edx
    and ecx, 0xF0
    cmp ecx, 0x80
    jne .no
    and edx, 0x0F                       ; 编号
    mov eax, 1
    pop ecx
    pop ebx
    ret
.no:
    xor eax, eax
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  kbd_getkey:取一个"键事件"(没有就 hlt 等中断)
;      普通键 → eax = ASCII(0..0xFF;回车 13、退格 8、ESC 27、Ctrl-S 19 …)
;      扩展键 → eax = 0x100 + 编号(1 上 2 下 3 左 4 右 5 Home 6 End 7 Del 8 PgUp 9 PgDn)
;  程序要用方向键就用这个;老代码用 kbd_getchar(它会把扩展键跳过去)。
; ---------------------------------------------------------------------------
kbd_getkey:
    push ebx
.loop:
    call kbd_seq_len
    test eax, eax
    jz .plain
    mov ecx, 2                          ; 扩展键:吃掉 ESC + 编号
    call kbd_consume
    mov eax, edx
    add eax, 0x100
    pop ebx
    ret
.plain:
    call kbd_avail
    test eax, eax
    jz .wait
    mov ebx, [kbd_tail]
    movzx eax, byte [kbd_buf + ebx]
    mov ecx, 1
    call kbd_consume
    pop ebx
    ret
.wait:
    hlt                                ; 睡着等键盘中断把 CPU 叫醒
    jmp .loop

; ---------------------------------------------------------------------------
;  kbd_getchar:取一个字符(没有就 hlt 等中断),返回 al
;  扩展键(方向键…)会被**跳过** —— 只想读打字的老程序不会突然收到 0x1B
; ---------------------------------------------------------------------------
kbd_getchar:
    push ebx
.loop:
    call kbd_seq_len
    test eax, eax
    jz .plain
    mov ecx, 2
    call kbd_consume
    jmp .loop                           ; 扩展键:丢掉,继续等下一个
.plain:
    call kbd_avail
    test eax, eax
    jz .wait
    mov ebx, [kbd_tail]
    movzx eax, byte [kbd_buf + ebx]
    mov ecx, 1
    call kbd_consume
    pop ebx
    ret
.wait:
    hlt
    jmp .loop

; ---------------------------------------------------------------------------
;  扫描码 → 字符表(Set 1)。索引 = 扫描码,值 = 字符,0 = 不处理
; ---------------------------------------------------------------------------
sc_lo:
    db 0                               ; 00
    db 27                              ; 01 ESC
    db '1','2','3','4','5','6','7','8','9','0','-','='   ; 02-0D
    db 8                               ; 0E Backspace
    db 9                               ; 0F Tab
    db 'q','w','e','r','t','y','u','i','o','p','[',']'   ; 10-1B
    db 13                              ; 1C Enter
    db 0                               ; 1D 左 Ctrl(没实现)
    db 'a','s','d','f','g','h','j','k','l',';',39        ; 1E-28
    db '`'                             ; 29
    db 0                               ; 2A 左 Shift(单独处理)
    db 92                              ; 2B 反斜杠
    db 'z','x','c','v','b','n','m',',','.','/'           ; 2C-35
    db 0                               ; 36 右 Shift
    db '*'                             ; 37 小键盘 *
    db 0                               ; 38 左 Alt
    db ' '                             ; 39 空格
    db 0                               ; 3A Caps Lock
    times 0x80 - ($ - sc_lo) db 0

sc_hi:
    db 0
    db 27
    db '!','@','#','$','%','^','&','*','(',')','_','+'   ; 02-0D
    db 8
    db 9
    db 'Q','W','E','R','T','Y','U','I','O','P','{','}'   ; 10-1B
    db 13
    db 0
    db 'A','S','D','F','G','H','J','K','L',':',34        ; 1E-28
    db '~'
    db 0
    db '|'
    db 'Z','X','C','V','B','N','M','<','>','?'
    db 0
    db '*'
    db 0
    db ' '
    db 0
    times 0x80 - ($ - sc_hi) db 0

shift_down db 0
caps_down  db 0                        ; Caps Lock 状态(按一下翻一次)
ctrl_down  db 0
ext_pending db 0
ext_code   db 0
; ---- Alt 码位输入(按住 Alt 敲十进制码,松开变成那个字符)----
alt_down   db 0
alt_len    db 0
alt_buf    times 8 db 0

kbd_buf    times KBD_BUF_SIZE db 0
kbd_head   dd 0
kbd_tail   dd 0

; ---------------------------------------------------------------------------
;  扩展键(0xE0 前缀后面那个扫描码 → 编号,0 = 不管)
;  编号:1 上 2 下 3 左 4 右 5 Home 6 End 7 Delete 8 PgUp 9 PgDn
; ---------------------------------------------------------------------------
sc_ext:
    times 0x47 db 0
    db 5                               ; 47 Home
    db 1                               ; 48 ↑
    db 8                               ; 49 PgUp
    db 0                               ; 4A(小键盘 -)
    db 3                               ; 4B ←  ★ 带 0xE0 前缀的 0x4B 就是左方向键
    db 0                               ; 4C(小键盘 5)
    db 4                               ; 4D →  (0x4D 同理,是右方向键)
    db 0                               ; 4E(小键盘 +)
    db 6                               ; 4F End
    db 2                               ; 50 ↓
    db 9                               ; 51 PgDn
    db 0                               ; 52 Insert
    db 7                               ; 53 Delete
    times 0x80 - ($ - sc_ext) db 0

; ---------------------------------------------------------------------------
;  kbd_set_leds:把键盘上的 Caps Lock 灯点亮/熄灭
;  PS/2 键盘:先往 0x60 发命令字节 0xED("设置指示灯"),再发一个数据字节
;      bit0 = Scroll Lock,bit1 = Num Lock,bit2 = Caps Lock
;  往 0x60 写之前要先看 0x64 的状态位 bit1(输入缓冲满不满);键盘忙就等一小会儿,
;  还忙就放弃 —— 灯不亮不影响打字(真机上 QEMU/VMware 会把灯状态转给宿主键盘)。
; ---------------------------------------------------------------------------
kbd_set_leds:
    push eax
    mov al, 0xED
    call kbd_send
    test al, al
    jz .out
    mov al, 0
    test byte [caps_down], 1
    jz .send
    or  al, 4                          ; bit2 = Caps Lock
.send:
    call kbd_send
.out:
    pop eax
    ret

; kbd_send:al = 要发给键盘的字节;返回 al = 1 成功 / 0 键盘一直忙(放弃)
kbd_send:
    push ecx
    push edx
    mov dl, al
    mov ecx, 0x10000
.wait:
    in  al, KBD_STATUS
    test al, 2                         ; bit1 = 输入缓冲满
    jz .ready
    dec ecx
    jnz .wait
    xor al, al                         ; 超时
    jmp .out
.ready:
    mov al, dl
    out KBD_DATA, al
    mov al, 1
.out:
    pop edx
    pop ecx
    ret
