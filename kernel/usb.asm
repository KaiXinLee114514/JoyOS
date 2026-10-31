; ============================================================================
;  JoyOS — USB 第一步:UHCI 控制器 + 端口枚举 + HID boot 键盘
;
;  目标:把 USB 键盘的字符**推进 PS/2 那条 kbd_buf**(kbd_push),这样 shell 和
;  EDIT 一行都不用改。存储(U 盘/大容量)是下一步,这里只做 UHCI。
;
;  ── 为什么是 UHCI ────────────────────────────────────────────────────────
;  QEMU 的 PIIX3 自带 UHCI(USB 1.1),`pci` 已经把它认出来了:
;      00:01.2  8086:7020  BAR4 = I/O 0xC040
;  pci.asm 把 BAR4 原样记在 [pci_usb_bar](低两位是 I/O 空间标志,要 & 0xFFFC)。
;
;  ── 内存放哪(任务里写 0x200000,但那里不是空的!)──────────────────────
;  0x200000 是 fontdisk.asm 的字库(FONT_LOAD_ADDR),启动时 1.7 MB 从磁盘读进来,
;  现在运行时搬到恒等映射顶部(ident-2 MiB);0x3B0000 起是 PINYIN.BIN 的拼音表;
;  0x400000 起才是 pmem 的物理页池。所以 USB 的帧列表/QH/TD 放在 **0x3C0000–0x3C1FFF**:
;  在拼音表之后、页池之前,恒等映射里,也没有别人用。具体分配见下面的 equ。
;
;  ── UHCI 最小模型(只讲我们用的)──────────────────────────────────────
;    · 帧列表:1024 个 32 位指针,每 1 ms 一帧,硬件把一项当"这一帧要跑的
;      队列头"。4 KiB 对齐,FLBASEADD 指向它。
;    · QH(队列头,16 字节对齐,硬件只用前 8 字节):
;          +0 link     → 下一个 QH(地址 | 2);1 = 结束
;          +4 element  → 本 QH 的第一个 TD;1 = 空
;    · TD(16 字节):
;          +0 link     → 下一个 TD(地址 | 4 = 深度优先);1 = 结束
;          +4 status   → 位 23 = Active;完成时硬件写回实际长度/错误位
;          +8 token    → PID | 设备地址 | 端点 | toggle | 长度-1
;          +12 buffer  → 数据缓冲区物理地址
;    · 一个控制传输 = SETUP TD → 若干 DATA TD → STATUS TD,用 |4 串起来,
;      QEMU 会在同一帧里一路跑完;最后一个 TD 的 link=1。
;
;  ── QEMU 的坑(实测,别照"真硬件"想当然)──────────────────────────────
;    · HCRESET 会把端口 PE 清掉,但 CCS 还在(usb_port_reset 重新 attach 过),
;      所以复位后必须**自己写 PE**,否则 uhci_find_device 永远找不到设备。
;      探针实测:复位后 PORTSC1=0x0083,写 PE 后 =0x0085。
;    · PE 只有在 CCS=1 时写得进去(QEMU uhci_port_write 会把 PE 抠掉)。
;    · 状态位是"写 1 清":写 PORTSC 时要把 CSC/PEC/OCC 位写成 1 才会清掉;
;      但如果不小心把当前值原样写回,CSC=1 也会被清 —— 所以写前先 & 0xF5F5。
;    · NAK 时 TD 保持 Active、QH.element 不动,下一帧自动重试;我们不用管。
;    · 控制传输中途出错会停住整条链(QH.element 停在出错的 TD),所以超时/出错
;      要把所有 TD 的 Active 清掉、QH.element 置 1,否则下一笔传输会重跑坏 TD。
;    · QEMU 的 uhci_find_device 只认 PORTSC.PE 的端口。
;
;  ── 轮询 ────────────────────────────────────────────────────────────────
;  USBINTR=0,不占 IRQ11。控制传输在 usb_init 里同步等(用 pit tick 超时);
;  中断 IN 端点则挂在一个常驻 QH 上,由 PIT 的 100 Hz IRQ0 调 usb_poll:
;  每 10 ms 看一眼 TD 完成没有,收到 8 字节 HID 报告就翻译成字符塞 kbd_buf。
;  usb_ready=0 时 usb_poll 立刻返回,保证初始化期间 IRQ0 不会碰这些结构。
; ============================================================================

; ---- UHCI 寄存器(相对 BAR4 的 I/O 偏移)----
USB_CMD       equ 0x00
USB_STS       equ 0x02
USB_INTR      equ 0x04
USB_FRNUM     equ 0x06
USB_FLBASE    equ 0x08
USB_PORT1     equ 0x10
USB_PORT2     equ 0x12

; USBCMD
USB_CMD_RS      equ 0x0001
USB_CMD_HCRESET equ 0x0002
USB_CMD_CF      equ 0x0040

; PORTSC 位
USB_P_CCS   equ 0x0001
USB_P_CSC   equ 0x0002
USB_P_PE    equ 0x0004
USB_P_PEC   equ 0x0008
USB_P_PR    equ 0x0200
USB_P_OCC   equ 0x0800
; 写 PORTSC 前先清掉:PR + 四个"写 1 清"的变化位
USB_P_WMASK equ 0xF5F5
; 单独写 PE 时顺手把变化位清掉(这些位写 1 = 清)
USB_P_WCLR  equ USB_P_CSC | USB_P_PEC

; TD 位
TD_ACTIVE   equ 0x00800000
TD_ERRMASK  equ 0x00770000      ; STALL/TIMEOUT/BABBLE/DBUFERR/BITSTUFF(不含 NAK)
TD_STATUS   equ TD_ACTIVE | (3 << 27)

; ---- 结构区(0x3C0000–0x3C1FFF,PINYIN 之后、pmem 之前)----
USB_FRAME_LIST equ 0x3C0000     ; 1024 × 4 B,4 KiB 对齐
USB_CTRL_QH    equ 0x3C1000     ; 控制传输的 QH
USB_CTRL_TD    equ 0x3C1010     ; 8 个 TD × 16 B = 128 B
USB_SETUP_BUF  equ 0x3C10A0     ; 8 B SETUP 包
USB_DATA_BUF   equ 0x3C10B0     ; 64 B 控制传输数据
USB_INT_QH     equ 0x3C1100     ; 中断 IN 的常驻 QH
USB_INT_TD     equ 0x3C1110     ; 中断 IN 的 TD
USB_INT_BUF    equ 0x3C1120     ; 8 B HID 报告
USB_DEV_DESC   equ 0x3C1140     ; 18 B 设备描述符
USB_CFG_DESC   equ 0x3C1180     ; 64 B 配置描述符(含接口/端点)

; ===========================================================================
;  usb_init:开机调一次(kmain 在 pci_scan 之后)。失败不停机。
;  没控制器时**静默返回**(没有 USB 的机器行为不变);控制器在但复位/枚举
;  失败才打一行,免得每次开机都多一行。
; ===========================================================================
usb_init:
    pushad
    mov byte [usb_ready], 0
    mov byte [usb_hid_ok], 0
    mov dword [usb_state], 0
    mov dword [usb_dev_addr], 0
    mov byte [usb_toggle], 0
    mov dword [usb_iobase], 0

    cmp dword [pci_usb_addr], -1
    je .silent                      ; 机器上没有 USB 控制器
    mov eax, [pci_usb_bar]
    test eax, eax
    jz .silent
    test al, 1                      ; bit0=1 才是 I/O 空间(UHCI)
    jz .silent
    and eax, 0xFFFC
    mov [usb_iobase], eax

    call usb_hw_reset
    test eax, eax
    jnz .reset_fail

    call usb_build_frames

    ; 端口 1、2:谁先连上设备就枚举谁(够用了;一个键盘不需要多设备地址管理)
    xor ebx, ebx
.port:
    mov ecx, ebx
    call usb_port_reset
    test eax, eax
    jz .next
    mov eax, ebx
    inc eax
    mov [usb_port], eax
    call usb_enumerate
    cmp dword [usb_state], 0
    jne .done                       ; 找到了设备(不管是不是键盘)就停
.next:
    inc ebx
    cmp ebx, 2
    jb .port

.done:
    mov byte [usb_ready], 1
    popad
    ret

.reset_fail:
    mov esi, msg_usb_reset
    call term_print
    popad
    ret
.silent:
    popad
    ret

; ===========================================================================
;  usb_hw_reset:USBCMD.HCRESET → 等它自清;清状态/关中断/FRNUM=0/清端口变化位
;  返回 eax=0 成功,-1 超时
; ===========================================================================
usb_hw_reset:
    push edx
    mov dx, [usb_iobase]
    mov ax, USB_CMD_HCRESET
    out dx, ax

    call pit_get_ticks
    add eax, 100                    ; 1 秒超时(正常几毫秒内就清了)
    mov [usb_deadline], eax
.wait:
    in ax, dx
    test ax, USB_CMD_HCRESET
    jz .clear
    call pit_get_ticks
    sub eax, [usb_deadline]
    jns .timeout
    hlt
    jmp .wait

.clear:
    mov dx, [usb_iobase]
    add dx, USB_STS
    mov ax, 0x003F                  ; 写 1 清所有状态位
    out dx, ax

    mov dx, [usb_iobase]
    add dx, USB_INTR
    xor ax, ax                      ; 轮询,不开中断
    out dx, ax

    mov dx, [usb_iobase]
    add dx, USB_FRNUM
    xor ax, ax
    out dx, ax

    ; 两个端口的变化位清掉
    mov dx, [usb_iobase]
    add dx, USB_PORT1
    mov ax, USB_P_CSC | USB_P_PEC | USB_P_OCC
    out dx, ax
    mov dx, [usb_iobase]
    add dx, USB_PORT2
    out dx, ax

    xor eax, eax
    pop edx
    ret
.timeout:
    mov eax, -1
    pop edx
    ret

; ===========================================================================
;  usb_build_frames:填 1024 项帧列表(全指向控制 QH)、串好两个 QH、
;  设 FLBASEADD、开 Run+CF
; ===========================================================================
usb_build_frames:
    pushad
    cld
    mov edi, USB_FRAME_LIST
    mov eax, USB_CTRL_QH | 2
    mov ecx, 1024
    rep stosd

    ; 控制 QH → 中断 QH → 结束;两个 element 先都空
    mov dword [USB_CTRL_QH], USB_INT_QH | 2
    mov dword [USB_CTRL_QH + 4], 1
    mov dword [USB_INT_QH], 1
    mov dword [USB_INT_QH + 4], 1

    ; FLBASEADD = 0x3C0000(低 16 位 0,高 16 位 0x003C)
    mov dx, [usb_iobase]
    add dx, USB_FLBASE
    xor ax, ax
    out dx, ax
    mov dx, [usb_iobase]
    add dx, USB_FLBASE + 2
    mov ax, 0x003C
    out dx, ax

    ; Run + Configure Flag
    mov dx, [usb_iobase]
    add dx, USB_CMD
    mov ax, USB_CMD_RS | USB_CMD_CF
    out dx, ax

    popad
    ret

; ===========================================================================
;  usb_port_reset:ecx = 端口号(0/1)
;  连着设备 → 置 PR 50 ms → 清 PR → 写 PE + 清变化位 → 读回确认
;  返回 eax=1 已使能,0 没设备/没使能
; ===========================================================================
usb_port_reset:
    push ebx
    push ecx
    push edx
    mov [usb_port_idx], ecx

    mov dx, [usb_iobase]
    add dx, USB_PORT1
    shl ecx, 1
    add dx, cx
    in ax, dx
    test ax, USB_P_CCS
    jz .none

    ; 置 PR。注意先把 PR 和变化位清掉,别把 CSC=1 原样写回去
    and ax, USB_P_WMASK
    or ax, USB_P_PR
    out dx, ax

    mov ecx, 5                      ; 50 ms
    call pit_wait_ticks

    ; 清 PR(重新算 dx:pit_wait_ticks 会动 ecx)
    mov ecx, [usb_port_idx]
    mov dx, [usb_iobase]
    add dx, USB_PORT1
    shl ecx, 1
    add dx, cx
    in ax, dx
    and ax, USB_P_WMASK
    out dx, ax

    ; 写 PE,顺手清 CSC/PEC
    in ax, dx
    and ax, USB_P_WMASK
    or ax, USB_P_PE | USB_P_WCLR
    out dx, ax

    mov ecx, 1
    call pit_wait_ticks

    mov ecx, [usb_port_idx]
    mov dx, [usb_iobase]
    add dx, USB_PORT1
    shl ecx, 1
    add dx, cx
    in ax, dx
    test ax, USB_P_PE
    jz .none
    mov eax, 1
    jmp .out

.none:
    xor eax, eax
.out:
    pop edx
    pop ecx
    pop ebx
    ret

; ===========================================================================
;  usb_control:同步控制传输
;    esi = SETUP 包(8 字节)
;    edi = 数据缓冲区(无数据时随便)
;    ecx = 数据长度
;    edx = 1 = IN(设备→主机),0 = 无数据
;  返回 eax=0 成功,-1 失败/超时
; ===========================================================================
usb_control:
    pushad
    mov [usb_xfer_setup], esi
    mov [usb_xfer_buf], edi
    mov [usb_xfer_len], ecx
    mov [usb_xfer_dir], edx

    ; 先把 QH 停掉,再清 TD 区(避免上一笔的残留被硬件捡起来)
    mov dword [USB_CTRL_QH + 4], 1
    cld
    mov edi, USB_CTRL_TD
    xor eax, eax
    mov ecx, 8 * 4
    rep stosd

    ; ---- SETUP TD ----
    mov ebx, USB_CTRL_TD
    mov dword [ebx + 4], TD_STATUS
    mov eax, [usb_dev_addr]
    shl eax, 8
    or eax, 0x2D | (7 << 21)        ; SETUP(0x2D),长度 8 → 字段 7
    mov [ebx + 8], eax
    mov eax, [usb_xfer_setup]
    mov [ebx + 12], eax
    add ebx, 16

    ; ---- DATA TD(只支持 IN;我们的请求要么无数据,要么 GET_DESCRIPTOR)----
    cmp dword [usb_xfer_dir], 1
    jne .no_data
    mov ecx, [usb_xfer_len]
    test ecx, ecx
    jz .no_data
    mov esi, [usb_xfer_buf]
    mov ebp, 1                      ; 数据阶段从 DATA1 开始,每包翻转
.data_loop:
    mov eax, ecx
    cmp eax, 8
    jbe .chunk
    mov eax, 8                      ; EP0 的 bMaxPacketSize0 = 8
.chunk:
    mov dword [ebx + 4], TD_STATUS
    mov edx, [usb_dev_addr]
    shl edx, 8
    or edx, 0x69                    ; IN(0x69),端点 0
    mov edi, ebp
    shl edi, 19
    or edx, edi
    mov edi, eax
    dec edi
    and edi, 0x7FF
    shl edi, 21
    or edx, edi
    mov [ebx + 8], edx
    mov [ebx + 12], esi
    add esi, eax
    sub ecx, eax
    xor ebp, 1
    add ebx, 16
    test ecx, ecx
    jnz .data_loop

.no_data:
    ; ---- STATUS TD ----
    mov dword [ebx + 4], TD_STATUS
    mov edx, 0x69                   ; 无数据请求 → 状态阶段是 IN
    cmp dword [usb_xfer_dir], 1
    jne .status_pid
    mov edx, 0xE1                   ; IN 数据 → 状态阶段是 OUT
.status_pid:
    mov eax, [usb_dev_addr]
    shl eax, 8
    or edx, eax
    or edx, (1 << 19)               ; 状态阶段 DATA1
    or edx, (0x7FF << 21)           ; 长度 0 的编码
    mov [ebx + 8], edx
    mov dword [ebx + 12], 0
    mov [usb_ctrl_last], ebx

    mov eax, ebx
    sub eax, USB_CTRL_TD
    shr eax, 4
    inc eax
    mov [usb_ctrl_ntd], eax

    ; ---- 串 TD:中间用 |4(深度优先),最后一个 link=1 ----
    mov edi, USB_CTRL_TD
    mov ecx, [usb_ctrl_ntd]
.link_loop:
    lea eax, [edi + 16]
    cmp ecx, 1
    jne .mid
    mov eax, 1
    jmp .store
.mid:
    or eax, 4
.store:
    mov [edi], eax
    add edi, 16
    dec ecx
    jnz .link_loop

    mov dword [USB_CTRL_QH + 4], USB_CTRL_TD

    call pit_get_ticks
    add eax, 100                    ; 1 秒
    mov [usb_deadline], eax

.wait:
    ; 出错时 QEMU 会停在中途,status TD 永远不完成 → 每轮扫一遍所有 TD
    mov ebx, USB_CTRL_TD
    mov ecx, [usb_ctrl_ntd]
.scan:
    mov eax, [ebx + 4]
    test eax, TD_ERRMASK
    jnz .fail
    add ebx, 16
    dec ecx
    jnz .scan

    mov ebx, [usb_ctrl_last]
    mov eax, [ebx + 4]
    test eax, TD_ACTIVE
    jz .ok

    call pit_get_ticks
    sub eax, [usb_deadline]
    jns .fail
    hlt
    jmp .wait

.ok:
    mov dword [USB_CTRL_QH + 4], 1
    popad
    xor eax, eax
    ret

.fail:
    ; 清 Active,别让下一笔传输重跑坏 TD
    mov ebx, USB_CTRL_TD
    mov ecx, [usb_ctrl_ntd]
.clr:
    and dword [ebx + 4], 0xFF7FFFFF
    add ebx, 16
    dec ecx
    jnz .clr
    mov dword [USB_CTRL_QH + 4], 1
    popad
    mov eax, -1
    ret

; ===========================================================================
;  usb_enumerate:对已使能端口上的设备做 SET_ADDRESS → 描述符 → HID 配置
;  (设备地址固定 1;只支持一个设备)
; ===========================================================================
usb_enumerate:
    pushad

    ; ---- SET_ADDRESS(1) ----
    mov dword [USB_SETUP_BUF], 0x00010500
    mov dword [USB_SETUP_BUF + 4], 0
    mov esi, USB_SETUP_BUF
    xor edi, edi
    xor ecx, ecx
    xor edx, edx
    call usb_control
    test eax, eax
    jnz .fail
    mov dword [usb_dev_addr], 1

    ; ---- GET_DESCRIPTOR(设备,18 字节)----
    mov dword [USB_SETUP_BUF], 0x01000680
    mov dword [USB_SETUP_BUF + 4], 18 << 16   ; wIndex=0, wLength=18
    mov esi, USB_SETUP_BUF
    mov edi, USB_DEV_DESC
    mov ecx, 18
    mov edx, 1
    call usb_control
    test eax, eax
    jnz .fail

    movzx eax, word [USB_DEV_DESC + 8]
    mov [usb_vid], eax
    movzx eax, word [USB_DEV_DESC + 10]
    mov [usb_pid], eax
    movzx eax, byte [USB_DEV_DESC + 4]
    mov [usb_class], eax
    movzx eax, byte [USB_DEV_DESC + 17]
    mov [usb_ncfg], eax

    ; ---- GET_DESCRIPTOR(配置头 9 字节,拿 wTotalLength)----
    mov dword [USB_SETUP_BUF], 0x02000680
    mov dword [USB_SETUP_BUF + 4], 9 << 16    ; wIndex=0, wLength=9
    mov esi, USB_SETUP_BUF
    mov edi, USB_CFG_DESC
    mov ecx, 9
    mov edx, 1
    call usb_control
    test eax, eax
    jnz .fail

    movzx eax, word [USB_CFG_DESC + 2]
    test eax, eax
    jz .fail
    cmp eax, 64
    jbe .len_ok
    mov eax, 64                     ; 我们的缓冲区只有 64 字节
.len_ok:
    mov [usb_cfg_total], eax
    mov ecx, eax                    ; 长度先留给 usb_control
    shl eax, 16
    mov [USB_SETUP_BUF + 4], eax    ; wIndex=0, wLength=wTotalLength

    ; ---- GET_DESCRIPTOR(完整配置)----
    mov esi, USB_SETUP_BUF
    mov edi, USB_CFG_DESC
    mov edx, 1
    call usb_control
    test eax, eax
    jnz .fail

    ; ---- 解析:配置 / 接口 / 中断 IN 端点 ----
    movzx eax, byte [USB_CFG_DESC + 4]
    mov [usb_niface], eax

    movzx ebx, byte [USB_CFG_DESC]  ; bLength = 9
    movzx eax, byte [USB_CFG_DESC + ebx + 5]
    mov [usb_if_class], eax
    movzx eax, byte [USB_CFG_DESC + ebx + 6]
    mov [usb_if_sub], eax
    movzx eax, byte [USB_CFG_DESC + ebx + 7]
    mov [usb_if_proto], eax

    mov dword [usb_ep_addr], 0
    mov dword [usb_ep_mps], 0
    mov dword [usb_ep_interval], 0

    mov ebx, 9
.walk:
    cmp ebx, [usb_cfg_total]
    jae .walk_done
    movzx ecx, byte [USB_CFG_DESC + ebx]
    test ecx, ecx
    jz .walk_done
    movzx eax, byte [USB_CFG_DESC + ebx + 1]
    cmp eax, 5                      ; ENDPOINT
    jne .next
    movzx eax, byte [USB_CFG_DESC + ebx + 2]
    test al, 0x80                   ; 只看 IN
    jz .next
    movzx edx, byte [USB_CFG_DESC + ebx + 3]
    and edx, 3
    cmp edx, 3                      ; 中断传输
    jne .next
    cmp dword [usb_ep_addr], 0
    jne .next
    mov [usb_ep_addr], eax
    movzx edx, word [USB_CFG_DESC + ebx + 4]
    and edx, 0x7FF
    mov [usb_ep_mps], edx
    movzx edx, byte [USB_CFG_DESC + ebx + 6]
    mov [usb_ep_interval], edx
.next:
    add ebx, ecx
    jmp .walk
.walk_done:

    mov dword [usb_state], 1        ; 枚举到了,但还不一定是键盘

    ; ---- 接口类 3/1/1 = HID boot 键盘 ----
    cmp dword [usb_if_class], 3
    jne .not_hid
    cmp dword [usb_if_sub], 1
    jne .not_hid
    cmp dword [usb_if_proto], 1
    jne .not_hid
    cmp dword [usb_ep_addr], 0
    je .not_hid

    ; SET_CONFIGURATION(1)
    mov dword [USB_SETUP_BUF], 0x00010900
    mov dword [USB_SETUP_BUF + 4], 0
    mov esi, USB_SETUP_BUF
    xor edi, edi
    xor ecx, ecx
    xor edx, edx
    call usb_control
    test eax, eax
    jnz .fail

    ; SET_IDLE(0):不自动重复,省得报告刷屏
    mov dword [USB_SETUP_BUF], 0x00000A21
    mov dword [USB_SETUP_BUF + 4], 0
    mov esi, USB_SETUP_BUF
    xor edi, edi
    xor ecx, ecx
    xor edx, edx
    call usb_control
    test eax, eax
    jnz .fail

    ; SET_PROTOCOL(0 = boot protocol),报告固定 8 字节
    mov dword [USB_SETUP_BUF], 0x00000B21
    mov dword [USB_SETUP_BUF + 4], 0
    mov esi, USB_SETUP_BUF
    xor edi, edi
    xor ecx, ecx
    xor edx, edx
    call usb_control
    test eax, eax
    jnz .fail

    mov byte [usb_toggle], 0
    mov byte [usb_hid_ok], 1
    mov dword [usb_state], 2
    call usb_arm_int
    popad
    ret

.not_hid:
    popad
    ret
.fail:
    mov dword [usb_state], 0
    mov esi, msg_usb_enum_fail      ; 只打一行,继续开机
    call term_print
    popad
    ret

; ===========================================================================
;  usb_arm_int:把中断 IN 的 TD 重新挂到常驻 QH 上
; ===========================================================================
usb_arm_int:
    push eax
    push ebx
    mov dword [USB_INT_QH + 4], USB_INT_TD
    mov dword [USB_INT_TD], 1
    mov dword [USB_INT_TD + 4], TD_STATUS
    mov eax, [usb_dev_addr]
    shl eax, 8
    or eax, 0x69 | (1 << 15) | (7 << 21)
    movzx ebx, byte [usb_toggle]
    shl ebx, 19
    or eax, ebx
    mov [USB_INT_TD + 8], eax
    mov dword [USB_INT_TD + 12], USB_INT_BUF
    pop ebx
    pop eax
    ret

; ===========================================================================
;  usb_poll:IRQ0(100 Hz)里调。看一眼中断 TD:
;    · 还 Active(含 NAK)→ 什么都不做,硬件下一帧自己重试
;    · 完成 → 解析 8 字节报告,翻转 toggle,重新挂上
;    · 出错 → 复位 toggle 重新挂(键盘不会 STALL,真出错也能自愈)
; ===========================================================================
usb_poll:
    pushad
    pushf
    cmp byte [usb_ready], 0
    je .out
    cmp byte [usb_hid_ok], 0
    je .out

    mov eax, [USB_INT_TD + 4]
    test eax, TD_ACTIVE
    jnz .out                        ; 还在等(NAK 也保持 Active)
    test eax, TD_ERRMASK
    jnz .recover

    and eax, 0x7FF
    inc eax
    and eax, 0x7FF
    jz .rearm                       ; 实际长度 0(理论上有报告就至少 8)
    call usb_handle_report

.rearm:
    xor byte [usb_toggle], 1
    call usb_arm_int
    jmp .out

.recover:
    mov byte [usb_toggle], 0
    call usb_arm_int
.out:
    popf
    popad
    ret

; ===========================================================================
;  usb_handle_report:8 字节 HID boot 报告
;    +0 修饰键(bit1/5 = Shift,bit0/4 = Ctrl)
;    +1 保留
;    +2..+7 六个 usage
;  只把**这一帧新出现的**键翻译成字符(按住不放不会刷屏)。
; ===========================================================================
usb_handle_report:
    pushad
    xor ebp, ebp
.slot:
    mov al, [USB_INT_BUF + 2 + ebp]
    test al, al
    jz .next

    ; 这个 usage 上一帧已经按着了吗?
    xor ebx, ebx
.search:
    cmp bl, 6
    jae .new
    mov dl, [usb_prev + 2 + ebx]
    cmp dl, al
    je .next                        ; 老键,跳过
    inc ebx
    jmp .search
.new:
    mov dl, [USB_INT_BUF]           ; 修饰键
    call usb_emit
.next:
    inc ebp
    cmp ebp, 6
    jb .slot

    ; 记下这一帧
    mov esi, USB_INT_BUF
    mov edi, usb_prev
    mov ecx, 8
    rep movsb
    popad
    ret

; ===========================================================================
;  usb_emit:al = HID usage,dl = 修饰键 → 翻译成 JoyOS 字符塞进 kbd_buf
;  (和 PS/2 的约定保持一致:Enter=13、Backspace=8、Tab=9、扩展键 = ESC + 0x80|编号)
; ===========================================================================
usb_emit:
    pushad
    movzx eax, al

    cmp al, 0x39                    ; Caps Lock:只翻状态,不出字符
    je .caps
    cmp al, 0xE0                    ; 修饰键本身不出字符
    jae .done

    ; ---- 字母 a-z ----
    cmp al, 0x04
    jb .special
    cmp al, 0x1D
    jbe .letter

    ; ---- 数字 1-0 ----
    cmp al, 0x1E
    jb .special
    cmp al, 0x27
    jbe .digit

    ; ---- 标点 ----
    cmp al, 0x2D
    jb .special
    cmp al, 0x38
    jbe .punct
    jmp .special

.letter:
    mov bl, al
    sub bl, 4
    add bl, 'a'
    mov ch, 0
    test dl, 0x22                   ; Shift(左 bit1 / 右 bit5)
    jz .no_shift
    mov ch, 1
.no_shift:
    xor ch, [usb_caps]              ; Shift XOR Caps
    test ch, ch
    jz .ctrl
    sub bl, 32
.ctrl:
    test dl, 0x11                   ; Ctrl(左 bit0 / 右 bit4)
    jz .push
    cmp bl, 'a'
    jb .push
    cmp bl, 'z'
    ja .push
    and bl, 0x1F
.push:
    mov al, bl
    call kbd_push
    jmp .done

.digit:
    sub al, 0x1E
    movzx ebx, al
    test dl, 0x22
    jz .digit_lo
    mov al, [usb_num_hi + ebx]
    jmp .push2
.digit_lo:
    mov al, [usb_num_lo + ebx]
.push2:
    call kbd_push
    jmp .done

.punct:
    sub al, 0x2D
    movzx ebx, al
    test dl, 0x22
    jz .punct_lo
    mov al, [usb_punct_hi + ebx]
    jmp .push2
.punct_lo:
    mov al, [usb_punct_lo + ebx]
    jmp .push2

.special:
    cmp al, 0x28                    ; Enter
    je .enter
    cmp al, 0x29                    ; Esc
    je .esc
    cmp al, 0x2A                    ; Backspace
    je .back
    cmp al, 0x2B                    ; Tab
    je .tab
    cmp al, 0x2C                    ; Space
    je .space
    cmp al, 0x4F                    ; Right
    je .right
    cmp al, 0x50                    ; Left
    je .left
    cmp al, 0x51                    ; Down
    je .down
    cmp al, 0x52                    ; Up
    je .up
    cmp al, 0x4A                    ; Home
    je .home
    cmp al, 0x4D                    ; End
    je .end
    cmp al, 0x4C                    ; Delete
    je .del
    cmp al, 0x4B                    ; PageUp
    je .pgup
    cmp al, 0x4E                    ; PageDown
    je .pgdn
    jmp .done

.enter: mov al, 13
        jmp .push2
.esc:   mov al, 27
        jmp .push2
.back:  mov al, 8
        jmp .push2
.tab:   mov al, 9
        jmp .push2
.space: mov al, 32
        jmp .push2

; 扩展键:先 ESC,再 0x80|编号(编号和 PS/2 键盘一致)
.right: mov al, 27
        call kbd_push
        mov al, 0x84
        jmp .push2
.left:  mov al, 27
        call kbd_push
        mov al, 0x83
        jmp .push2
.down:  mov al, 27
        call kbd_push
        mov al, 0x82
        jmp .push2
.up:    mov al, 27
        call kbd_push
        mov al, 0x81
        jmp .push2
.home:  mov al, 27
        call kbd_push
        mov al, 0x85
        jmp .push2
.end:   mov al, 27
        call kbd_push
        mov al, 0x86
        jmp .push2
.del:   mov al, 27
        call kbd_push
        mov al, 0x87
        jmp .push2
.pgup:  mov al, 27
        call kbd_push
        mov al, 0x88
        jmp .push2
.pgdn:  mov al, 27
        call kbd_push
        mov al, 0x89
        jmp .push2

.caps:
    xor byte [usb_caps], 1
.done:
    popad
    ret

; ===========================================================================
;  shell 的 usb 命令:控制器 / 端口 / 枚举结果 / 端点
; ===========================================================================
cmd_usb:
    pushad

    cmp dword [pci_usb_addr], -1
    je .none
    cmp dword [usb_iobase], 0
    je .notinit

    ; usb: UHCI 8086:7020 io C040 p1=0085 p2=0080
    mov esi, msg_usb_ctrl
    call term_print
    mov eax, [pci_usb_id]
    call pci_ph4
    mov al, ':'
    call term_putc
    mov eax, [pci_usb_id]
    shr eax, 16
    call pci_ph4
    mov esi, msg_usb_io
    call term_print
    mov eax, [usb_iobase]
    call pci_ph4
    mov esi, msg_usb_p1
    call term_print
    xor ecx, ecx
    call usb_read_port
    movzx eax, ax
    call pci_ph4
    mov esi, msg_usb_p2
    call term_print
    mov ecx, 1
    call usb_read_port
    movzx eax, ax
    call pci_ph4
    mov al, 10
    call term_putc

    cmp dword [usb_state], 0
    je .nodev

    ; usb: dev 0627:0001 class 00 cfg 1 iface 1
    mov esi, msg_usb_dev
    call term_print
    mov eax, [usb_vid]
    call pci_ph4
    mov al, ':'
    call term_putc
    mov eax, [usb_pid]
    call pci_ph4
    mov esi, msg_usb_class
    call term_print
    mov eax, [usb_class]
    call pci_ph2
    mov esi, msg_usb_cfg
    call term_print
    mov eax, [usb_ncfg]
    call term_print_dec
    mov esi, msg_usb_ifaces
    call term_print
    mov eax, [usb_niface]
    call term_print_dec
    mov al, 10
    call term_putc

    ; usb: iface 00 class 03/01/01 HID keyboard
    mov esi, msg_usb_iface
    call term_print
    mov eax, [usb_if_class]
    call pci_ph2
    mov al, '/'
    call term_putc
    mov eax, [usb_if_sub]
    call pci_ph2
    mov al, '/'
    call term_putc
    mov eax, [usb_if_proto]
    call pci_ph2
    mov esi, msg_usb_hidtag
    call term_print

    ; usb: ep 81 IN, max 8, interval 10 ms
    cmp dword [usb_ep_addr], 0
    je .noep
    mov esi, msg_usb_ep
    call term_print
    mov eax, [usb_ep_addr]
    call pci_ph2
    mov esi, msg_usb_epin
    call term_print
    mov eax, [usb_ep_mps]
    call term_print_dec
    mov esi, msg_usb_epint
    call term_print
    mov eax, [usb_ep_interval]
    call term_print_dec
    mov esi, msg_usb_ms
    call term_print
.noep:

    cmp byte [usb_hid_ok], 0
    je .nohid
    mov esi, msg_usb_ok
    call term_print
    jmp .done
.nohid:
    mov esi, msg_usb_nohid
    call term_print
    jmp .done

.nodev:
    mov esi, msg_usb_nodev
    call term_print
    jmp .done
.notinit:
    mov esi, msg_usb_notinit
    call term_print
    jmp .done
.none:
    mov esi, msg_usb_none
    call term_print
.done:
    popad
    ret

; ecx = 0/1 → ax = PORTSC
usb_read_port:
    mov dx, [usb_iobase]
    add dx, USB_PORT1
    shl ecx, 1
    add dx, cx
    in ax, dx
    ret

; ---------------------------------------------------------------------------
;  数据
; ---------------------------------------------------------------------------
usb_iobase      dd 0
usb_ready       db 0
usb_hid_ok      db 0
usb_toggle      db 0
usb_caps        db 0
usb_port_idx    dd 0
usb_port        dd 0
usb_dev_addr    dd 0
usb_state       dd 0

usb_vid         dd 0
usb_pid         dd 0
usb_class       dd 0
usb_ncfg        dd 0
usb_niface      dd 0
usb_cfg_total   dd 0
usb_if_class    dd 0
usb_if_sub      dd 0
usb_if_proto    dd 0
usb_ep_addr     dd 0
usb_ep_mps      dd 0
usb_ep_interval dd 0

usb_deadline    dd 0
usb_ctrl_last   dd 0
usb_ctrl_ntd    dd 0
usb_xfer_setup  dd 0
usb_xfer_buf    dd 0
usb_xfer_len    dd 0
usb_xfer_dir    dd 0
usb_prev        times 8 db 0

; HID usage → 字符
usb_num_lo   db '1234567890'
usb_num_hi   db '!@#$%^&*()'
; 0x2D..0x38: - = [ ] \ # ; ' ` , . /
; 下标 0..11 = usage 0x2D..0x38
;   2D -  2E =  2F [  30 ]  31 \  32 #  33 ;  34 '  35 `  36 ,  37 .  38 /
usb_punct_lo db 0x2D,0x3D,0x5B,0x5D,0x5C,0x23,0x3B,0x27,0x60,0x2C,0x2E,0x2F
;   shift: _  +  {  }  |  ~  :  "  ~  <  >  ?
usb_punct_hi db 0x5F,0x2B,0x7B,0x7D,0x7C,0x7E,0x3A,0x22,0x7E,0x3C,0x3E,0x3F

msg_usb_ctrl    db 'usb: UHCI ', 0
msg_usb_io      db ' io ', 0
msg_usb_p1      db ' p1=', 0
msg_usb_p2      db ' p2=', 0
msg_usb_dev     db 'usb: dev ', 0
msg_usb_class   db ' class ', 0
msg_usb_cfg     db ' cfg ', 0
msg_usb_ifaces  db ' iface ', 0
msg_usb_iface   db 'usb: iface class ', 0
msg_usb_hidtag  db ' HID', 10, 0
msg_usb_ep      db 'usb: ep ', 0
msg_usb_epin    db ' IN, max ', 0
msg_usb_epint   db ', interval ', 0
msg_usb_ms      db ' ms', 10, 0
msg_usb_ok      db 'usb: HID boot keyboard ready', 10, 0
msg_usb_nohid   db 'usb: no boot keyboard on this device', 10, 0
msg_usb_nodev   db 'usb: no device connected', 10, 0
msg_usb_notinit db 'usb: controller present, driver not initialised', 10, 0
msg_usb_none    db 'usb: no UHCI controller', 10, 0
msg_usb_reset   db 'usb: UHCI reset timeout', 10, 0
msg_usb_enum_fail db 'usb: device enumeration failed', 10, 0
