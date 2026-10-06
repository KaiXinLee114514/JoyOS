; ============================================================================
;  JoyOS (胡闹OS) — PC 蜂鸣器(主板上那个小喇叭)
;
;  目标就一句话:**能听见 JoyOS 自己唱歌**。所以这里不搞"驱动框架",就一个函数:
;
;      speaker_beep    ebx = 频率 Hz,ecx = 持续毫秒
;
;  ── 为什么是忙等,不加 IRQ0 ────────────────────────────────────────────
;  内核现在根本没有时钟中断:IRQ0 在 PIC 里是屏蔽的(只放行 IRQ1 给键盘,见
;  keyboard.asm)。为了几声"嘀"去装 IRQ0、发 EOI、再搞一套"到点了关扬声器"的
;  状态机,代码量和出错面都比收益大 —— 于是 beep 就四步:
;
;      设频率 → 开扬声器 → 空转等 ms → 关扬声器
;
;  代价说清楚:**音高是准的,时值是估的**。音高由 PIT 硬件按 1193182 Hz 分频,
;  什么宿主、什么虚拟机都一样;而"毫秒"没人能问,只能数指令圈数(标定见下面
;  SPKR_LOOPS_PER_MS)。听着对就行 —— 想真准就得加 IRQ0 或者去读 PIT 通道 0
;  的计数器,那是下一步的事。
;
;  ── 硬件(PC 兼容机的老规矩)──────────────────────────────────────────
;    · 0x43 = PIT 命令口,0x42 = 通道 2 数据口。通道 2 的输出去驱动扬声器,
;      写 0xB6 = 通道 2 / 先低字节后高字节 / 模式 3(方波)/ 二进制计数;
;      然后 divisor = 1193182 / 频率,低字节、高字节各写一次。
;    · 0x61 的**低两位**:bit0 = 定时器 2 门控,bit1 = 扬声器数据,两个都置 1
;      才响(老机器上这两级是串联的:门控放方波过来,数据位再把它接到喇叭)。
;      高 6 位是别的东西在用(键盘、奇偶校验那些),所以只改低两位、别的原样写回。
; ============================================================================

PIT_HZ      equ 1193182                 ; PIT 输入时钟(不是 1 MHz 整,老 IBM PC 拿 14.31818 MHz 除 12 来的)
PIT_CMD     equ 0x43                    ; PIT 命令口
PIT_CH2     equ 0x42                    ; 通道 2 = 扬声器那条
SPKR_PORT   equ 0x61                    ; 低两位控制扬声器通断

; 忙等标定:内层循环(dec ecx / jnz)转多少圈算 1 毫秒。
;   ★ 这是**估的**,而且只能估:QEMU(TCG)里本机实测,标称 300 ms 实际等了
;     289~318 ms(约 ±5%,宿主负载不同就有这个抖动),所以取 355000 圈/ms 当中间值。
;     换台机器/开 KVM/跑在真机上会差好几倍 —— 听着明显赶或明显慢,就改这一个数。
SPKR_LOOPS_PER_MS equ 355000

; ---------------------------------------------------------------------------
;  speaker_beep:ebx = 频率 Hz,ecx = 持续毫秒
;    · ebx <= 0:不出声,但仍然等 ecx 毫秒 —— 这就是"静音等待",谱子里的休止符用它
;      (与其让 C 程序自己再写一套忙等,不如复用这里:两边标定一次就够)
;    · ecx <= 0:什么都不做(0 毫秒的"嘀"没有意义)
; ---------------------------------------------------------------------------
speaker_beep:
    push eax
    push ebx
    push ecx
    push edx
    test ecx, ecx
    jle .done                           ; 时长为 0 或负数:连等都不用等
    test ebx, ebx
    jle .silent                         ; 频率 <= 0:只等,不响
    ; ---- 0) 频率夹到 PIT 能表达的范围内(divisor 必须落在 1..65535)----
    ;   太低的频率人耳本来也听不见,太高的分频值会小到失去意义;
    ;   夹一下还能保证下面的 div 不会除出越界的商。
    cmp ebx, 20
    jge .freq_min_ok
    mov ebx, 20
.freq_min_ok:
    cmp ebx, 20000
    jle .freq_ok
    mov ebx, 20000
.freq_ok:
    ; ---- 1) 给通道 2 设频率:divisor = 1193182 / freq ----
    mov eax, PIT_HZ
    xor edx, edx                        ; div 用 edx:eax 当被除数,高位得清 0
    div ebx
    mov ebx, eax                        ; 频率用完了,ebx 改存 divisor
    mov al, 0xB6                        ; 通道 2 / 先低后高 / 模式 3 方波 / 二进制
    out PIT_CMD, al
    mov eax, ebx
    out PIT_CH2, al                     ; 低字节
    mov al, ah
    out PIT_CH2, al                     ; 高字节
    ; ---- 2) 开扬声器(只动低两位,高 6 位原样)----
    in al, SPKR_PORT
    or al, 3
    out SPKR_PORT, al
    ; ---- 3) 等 ms(估的)----
    mov eax, ecx
    call speaker_delay_ms
    ; ---- 4) 关扬声器:音高留着没关系,门一关就没声了 ----
    in al, SPKR_PORT
    and al, 0xFC
    out SPKR_PORT, al
    jmp .done
.silent:
    mov eax, ecx
    call speaker_delay_ms
.done:
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  speaker_delay_ms:eax = 毫秒(估的)
;    双层空转:内层数到 SPKR_LOOPS_PER_MS,外层数毫秒。
;    ★ 这里**故意不读时钟**:理由写在文件开头。eax/ecx 会被改掉。
; ---------------------------------------------------------------------------
speaker_delay_ms:
    test eax, eax
    jle .done
.ms:
    push eax                            ; 内层要用 ecx,外层计数先存栈上
    mov ecx, SPKR_LOOPS_PER_MS
.inner:
    dec ecx
    jnz .inner
    pop eax
    dec eax
    jnz .ms
.done:
    ret
