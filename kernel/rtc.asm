; ============================================================================
;  rtc.asm —— CMOS 实时时钟(读日期 / 时间)
;
;  主板上那颗"关机也在走字"的时钟芯片(MC146818 那一路),用两个 I/O 口访问:
;    0x70 = 索引口:先写"我要看哪个寄存器"
;    0x71 = 数据口:再把这个寄存器的值读回来
;  它自己不带电,靠主板上的纽扣电池续命;QEMU 模拟这颗芯片,值来自宿主时钟。
;
;  寄存器(我们只读这几个):
;    0x00 秒   0x02 分   0x04 时   0x06 星期   0x07 日   0x08 月   0x09 年
;    0x0A 状态 A:bit7 = UIP(Update In Progress)—— 更新中的值不能读
;    0x0B 状态 B:bit2 = 0 表示值写成 BCD,1 表示二进制
;                 bit1 = 1 表示 24 小时制,0 表示 12 小时制(小时的 bit7 是 PM 标志)
;    0x32 世纪:非标准寄存器,但几乎所有机器都有;读不到就猜 20
;
;  读法(芯片手册上的标准姿势,别嫌啰嗦 —— 少一步就会读到"半新半旧"的时间):
;    1. 等 UIP 变 0(不在更新中)
;    2. 一口气读完 7 个寄存器
;    3. 再读一遍,和第一遍逐字节比对;不一样说明读的途中翻秒了,重来(最多 3 遍)
;    4. 把 BCD 转二进制、12 小时制转 24 小时制,再做一遍范围检查
;  第 3 步是重点:芯片在整点时会把秒从 59 翻回 00,正好卡在这中间读,
;  就会拿到"秒是 59、分已经加过"这种拼起来的时间。
;
;  局限:没有时区、没有夏令时 —— 芯片里存的是什么,我们就读什么。
;        QEMU 默认把 RTC 设成 UTC(-rtc base=utc),所以 guest 里看到的是 UTC;
;        Makefile 的 run / hd / hd32 都加了 -rtc base=localtime,窗口里就是你墙上钟的时间。
;        真机上这颗芯片记的是"本地时间"(Windows 的路子);
;        先读不写 —— 我们没有权限模型,也不打算让任何一个程序能改系统时间。
; ============================================================================

CMOS_INDEX  equ 0x70
CMOS_DATA   equ 0x71

CMOS_R_SEC  equ 0x00
CMOS_R_MIN  equ 0x02
CMOS_R_HOUR equ 0x04
CMOS_R_WDAY equ 0x06
CMOS_R_DAY  equ 0x07
CMOS_R_MON  equ 0x08
CMOS_R_YEAR equ 0x09
CMOS_R_SRA  equ 0x0A
CMOS_R_SRB  equ 0x0B
CMOS_R_CENT equ 0x32

; ---------------------------------------------------------------------------
;  rtc_read:al = 寄存器号 → al = 值
;  只碰 al(调用者可以先 pushad);索引口 bit7 = 0,顺便保持 NMI 开着
; ---------------------------------------------------------------------------
rtc_read:
    out CMOS_INDEX, al
    jmp short $+2                         ; 老芯片写完索引要喘口气,
    jmp short $+2                         ; 两个短跳足够(不去碰 0x80 那个诊断口)
    in al, CMOS_DATA
    ret

; ---------------------------------------------------------------------------
;  rtc_wait_uip:等状态 A 的 UIP 变 0(更新结束)
;  带次数上限:芯片要是坏了,宁可读到错时间也别把内核卡死在这儿
; ---------------------------------------------------------------------------
rtc_wait_uip:
    push eax
    push ecx
    mov ecx, 200000
.loop:
    mov al, CMOS_R_SRA
    call rtc_read
    test al, 0x80
    jz .done
    dec ecx
    jnz .loop
.done:
    pop ecx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  rtc_snapshot:esi = 7 字节的落脚点 → 原样读进 秒/分/时/星期/日/月/年
;  不做任何转换 —— 转换要等确认两遍读数一致之后再做
; ---------------------------------------------------------------------------
rtc_snapshot:
    push eax
    push edi
    mov edi, esi
    mov al, CMOS_R_SEC
    call rtc_read
    mov [edi + 0], al
    mov al, CMOS_R_MIN
    call rtc_read
    mov [edi + 1], al
    mov al, CMOS_R_HOUR
    call rtc_read
    mov [edi + 2], al
    mov al, CMOS_R_WDAY
    call rtc_read
    mov [edi + 3], al
    mov al, CMOS_R_DAY
    call rtc_read
    mov [edi + 4], al
    mov al, CMOS_R_MON
    call rtc_read
    mov [edi + 5], al
    mov al, CMOS_R_YEAR
    call rtc_read
    mov [edi + 6], al
    pop edi
    pop eax
    ret

; ---------------------------------------------------------------------------
;  rtc_bcd2bin:eax = 原始值 → eax = 二进制值
;  rtc_bcd 为 0 时原样返回(状态 B 说这颗芯片是用二进制写的)
;  坏值(比如 0x1A)会算出 20 这种越界数,交给后面的范围检查去喊
; ---------------------------------------------------------------------------
rtc_bcd2bin:
    cmp byte [rtc_bcd], 0
    je .out
    mov edx, eax
    shr edx, 4                            ; 十位
    lea edx, [edx + edx * 4]              ; ×5
    add edx, edx                          ; ×10
    and eax, 0x0F                         ; 个位
    add eax, edx
.out:
    ret

; ---------------------------------------------------------------------------
;  rtc_get:读一次时间,填满 rtc_ 那一堆字段
;    rtc_ok   = 1 两遍读数一致(可信);0 = 试了 3 遍还在变,值可能差一秒
;    rtc_sane = 1 各字段都在合理范围内
;  不改芯片里的任何东西(只读)
; ---------------------------------------------------------------------------
rtc_get:
    pushad
    mov byte [rtc_ok], 0
    mov byte [rtc_sane], 0
    mov byte [rtc_bcd], 1
    mov byte [rtc_h24], 1
    mov dword [rtc_tries], 3

.try:
    call rtc_wait_uip
    mov esi, rtc_raw1
    call rtc_snapshot
    call rtc_wait_uip
    mov esi, rtc_raw2
    call rtc_snapshot
    mov esi, rtc_raw1
    mov edi, rtc_raw2
    mov ecx, 7
    repe cmpsb
    je .stable
    dec dword [rtc_tries]
    jnz .try
    jmp .use_it                          ; 还在变:拿最后一遍凑合,rtc_ok 保持 0
.stable:
    mov byte [rtc_ok], 1

.use_it:
    mov esi, rtc_raw2                     ; 两遍一样,取哪份都一样

    ; ---- 状态 B:值是 BCD 还是二进制?小时是 12 还是 24 小时制?----
    mov al, CMOS_R_SRB
    call rtc_read
    mov [rtc_status_b], al
    test al, 0x04
    jnz .binary
    mov byte [rtc_bcd], 1
    jmp .hour_mode
.binary:
    mov byte [rtc_bcd], 0
.hour_mode:
    test byte [rtc_status_b], 0x02
    jnz .h24
    mov byte [rtc_h24], 0                ; 12 小时制:小时的 bit7 = PM

.h24:
    ; ---- 秒 / 分 ----
    movzx eax, byte [esi + 0]
    call rtc_bcd2bin
    mov [rtc_sec], al
    movzx eax, byte [esi + 1]
    call rtc_bcd2bin
    mov [rtc_min], al

    ; ---- 时(12 小时制要先把 PM 位摘下来)----
    movzx eax, byte [esi + 2]
    mov bl, 0                             ; bl = 是不是下午
    cmp byte [rtc_h24], 0
    jne .hour_plain
    test al, 0x80
    jz .hour_am
    mov bl, 1
.hour_am:
    and al, 0x7F
.hour_plain:
    call rtc_bcd2bin
    cmp byte [rtc_h24], 0
    jne .hour_done
    ; 12 小时制里没有 0 点:12 AM = 0 点,12 PM = 12 点
    cmp eax, 12
    jne .hour_not12
    mov eax, 0
.hour_not12:
    test bl, bl
    jz .hour_done
    add eax, 12
.hour_done:
    mov [rtc_hour], al

    ; ---- 星期(1 = 星期日)/ 日 / 月 / 年 ----
    movzx eax, byte [esi + 3]
    call rtc_bcd2bin
    mov [rtc_wday], al
    movzx eax, byte [esi + 4]
    call rtc_bcd2bin
    mov [rtc_day], al
    movzx eax, byte [esi + 5]
    call rtc_bcd2bin
    mov [rtc_mon], al
    movzx eax, byte [esi + 6]
    call rtc_bcd2bin
    mov [rtc_yy], eax                     ; 两位年(0..99)

    ; ---- 世纪:0x32 读不到就猜 20 ----
    mov al, CMOS_R_CENT
    call rtc_read
    movzx eax, al
    call rtc_bcd2bin
    cmp eax, 19
    jb .cent_guess
    cmp eax, 99
    ja .cent_guess
    jmp .cent_ok
.cent_guess:
    mov eax, 20
.cent_ok:
    mov [rtc_century], eax
    imul eax, 100
    add eax, [rtc_yy]
    mov [rtc_year], eax                   ; 2026 这样的四位年

    ; ---- 范围检查:对不上就当"这钟没设"----
    cmp byte [rtc_sec], 59
    ja .bogus
    cmp byte [rtc_min], 59
    ja .bogus
    cmp byte [rtc_hour], 23
    ja .bogus
    cmp byte [rtc_wday], 0
    je .bogus
    cmp byte [rtc_wday], 7
    ja .bogus
    cmp byte [rtc_day], 1
    jb .bogus
    cmp byte [rtc_day], 31
    ja .bogus
    cmp byte [rtc_mon], 1
    jb .bogus
    cmp byte [rtc_mon], 12
    ja .bogus
    mov byte [rtc_sane], 1
.bogus:
    popad
    ret

; ---------------------------------------------------------------------------
;  rtc_print2:eax = 0..99 → 打印两位(不足补 0)
; ---------------------------------------------------------------------------
rtc_print2:
    push eax
    push edx
    push ecx
    xor edx, edx
    mov ecx, 10
    div ecx                               ; eax = 十位, edx = 个位
    add al, '0'
    call term_putc
    mov eax, edx
    add al, '0'
    call term_putc
    pop ecx
    pop edx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  rtc_print_time:打印 `YYYY-MM-DD HH:MM:SS 星期X`(不带换行)
;  调用前先 rtc_get
; ---------------------------------------------------------------------------
rtc_print_time:
    pushad
    mov eax, [rtc_year]
    call term_print_dec
    mov esi, msg_rtc_dash
    call term_print
    movzx eax, byte [rtc_mon]
    call rtc_print2
    mov esi, msg_rtc_dash
    call term_print
    movzx eax, byte [rtc_day]
    call rtc_print2
    mov esi, msg_rtc_space
    call term_print
    movzx eax, byte [rtc_hour]
    call rtc_print2
    mov esi, msg_rtc_colon
    call term_print
    movzx eax, byte [rtc_min]
    call rtc_print2
    mov esi, msg_rtc_colon
    call term_print
    movzx eax, byte [rtc_sec]
    call rtc_print2
    movzx eax, byte [rtc_wday]            ; 1 = 星期日
    cmp eax, 7
    ja .no_wday
    mov esi, msg_rtc_space
    call term_print
    mov esi, [wd_names + eax * 4 - 4]
    call term_print
.no_wday:
    popad
    ret

; ---------------------------------------------------------------------------
;  rtc_print_ymd:打印 `YYYY-MM-DD`
;  rtc_print_mdy:打印 `MM/DD/YYYY`(月/日/年,美国人的写法)
;  rtc_print_dmy:打印 `DD/MM/YYYY`(日/月/年,欧洲人的写法)
;  rtc_print_hms:打印 `HH:MM:SS`
;  都先 call rtc_get;都只打印一行内容,不带换行
; ---------------------------------------------------------------------------
rtc_print_ymd:
    pushad
    mov eax, [rtc_year]
    call term_print_dec
    mov esi, msg_rtc_dash
    call term_print
    movzx eax, byte [rtc_mon]
    call rtc_print2
    mov esi, msg_rtc_dash
    call term_print
    movzx eax, byte [rtc_day]
    call rtc_print2
    popad
    ret

rtc_print_mdy:
    pushad
    movzx eax, byte [rtc_mon]
    call rtc_print2
    mov esi, msg_rtc_slash
    call term_print
    movzx eax, byte [rtc_day]
    call rtc_print2
    mov esi, msg_rtc_slash
    call term_print
    mov eax, [rtc_year]
    call term_print_dec
    popad
    ret

rtc_print_dmy:
    pushad
    movzx eax, byte [rtc_day]
    call rtc_print2
    mov esi, msg_rtc_slash
    call term_print
    movzx eax, byte [rtc_mon]
    call rtc_print2
    mov esi, msg_rtc_slash
    call term_print
    mov eax, [rtc_year]
    call term_print_dec
    popad
    ret

rtc_print_hms:
    pushad
    movzx eax, byte [rtc_hour]
    call rtc_print2
    mov esi, msg_rtc_colon
    call term_print
    movzx eax, byte [rtc_min]
    call rtc_print2
    mov esi, msg_rtc_colon
    call term_print
    movzx eax, byte [rtc_sec]
    call rtc_print2
    popad
    ret

; ---------------------------------------------------------------------------
;  rtc_print_mode:打印 `BCD, 24-hour mode` 这种(不带括号)
; ---------------------------------------------------------------------------
rtc_print_mode:
    push eax
    push esi
    cmp byte [rtc_bcd], 0
    je .binary
    mov esi, msg_rtc_bcd
    jmp .hour
.binary:
    mov esi, msg_rtc_binary
.hour:
    call term_print
    mov esi, msg_rtc_comma
    call term_print
    cmp byte [rtc_h24], 0
    je .h12
    mov esi, msg_rtc_24h
    jmp .emit
.h12:
    mov esi, msg_rtc_12h
.emit:
    call term_print
    pop esi
    pop eax
    ret

; ---------------------------------------------------------------------------
;  rtc_print_boot:开机那一行
;    rtc: CMOS clock 2026-02-14 15:33:27 星期六 (BCD, 24-hour mode)
;  顺带说一下读数可不可信 —— 屏幕上写着"时间",但得让人知道这时间靠不靠谱
; ---------------------------------------------------------------------------
rtc_print_boot:
    pushad
    mov esi, msg_rtc_prefix
    call term_print
    call rtc_print_time
    cmp byte [rtc_ok], 0
    je .unstable
    cmp byte [rtc_sane], 0
    je .insane
    mov esi, msg_rtc_lparen
    call term_print
    call rtc_print_mode
    mov esi, msg_rtc_rparen_nl
    call term_print
    jmp .done
.unstable:
    mov esi, msg_rtc_unstable
    call term_print
    jmp .done
.insane:
    mov esi, msg_rtc_insane
    call term_print
.done:
    popad
    ret

; ---------------------------------------------------------------------------
;  rtc_print_state:date 命令的第二行(模式 + 一句提醒),自带换行
; ---------------------------------------------------------------------------
rtc_print_state:
    pushad
    cmp byte [rtc_ok], 0
    je .unstable
    cmp byte [rtc_sane], 0
    je .insane
    mov esi, msg_rtc_state
    call term_print
    call rtc_print_mode
    mov esi, msg_rtc_no_tz
    call term_print
    jmp .done
.unstable:
    mov esi, msg_rtc_unstable
    call term_print
    jmp .done
.insane:
    mov esi, msg_rtc_insane
    call term_print
.done:
    popad
    ret

; ---------------------------------------------------------------------------
;  数据
; ---------------------------------------------------------------------------
rtc_raw1     times 7 db 0                 ; 第一遍读数(秒/分/时/星期/日/月/年)
rtc_raw2     times 7 db 0                 ; 第二遍,用来比对
rtc_tries    dd 3
rtc_status_b db 0
rtc_bcd      db 1                         ; 1 = 值是 BCD
rtc_h24      db 1                         ; 1 = 24 小时制
rtc_ok       db 0                         ; 1 = 两遍一致
rtc_sane     db 0                         ; 1 = 各字段范围合理
rtc_yy       dd 0                         ; 两位年
rtc_year     dd 0                         ; 四位年(世纪 * 100 + 两位年)
rtc_century  dd 0
rtc_mon      db 0
rtc_day      db 0
rtc_hour     db 0
rtc_min      db 0
rtc_sec      db 0
rtc_wday     db 0                         ; 1 = 星期日

msg_rtc_prefix     db 'rtc: CMOS clock ', 0
msg_rtc_dash       db '-', 0
msg_rtc_slash      db '/', 0
msg_rtc_colon      db ':', 0
msg_rtc_space      db ' ', 0
msg_rtc_comma      db ', ', 0
msg_rtc_lparen     db ' (', 0
msg_rtc_rparen_nl  db ')', 10, 0
msg_rtc_bcd        db 'BCD', 0
msg_rtc_binary     db 'binary', 0
msg_rtc_24h        db '24-hour mode', 0
msg_rtc_12h        db '12-hour mode', 0
msg_rtc_state      db 10, 'RTC: ', 0
msg_rtc_no_tz      db ' (no timezone handling)', 10, 0
msg_rtc_unstable   db ' -- read was unstable, values may be off by a second', 10, 0
msg_rtc_insane     db ' -- values look wrong (clock not set?)', 10, 0

wd_sun  db '星期日', 0
wd_mon  db '星期一', 0
wd_tue  db '星期二', 0
wd_wed  db '星期三', 0
wd_thu  db '星期四', 0
wd_fri  db '星期五', 0
wd_sat  db '星期六', 0
wd_names dd wd_sun, wd_mon, wd_tue, wd_wed, wd_thu, wd_fri, wd_sat
