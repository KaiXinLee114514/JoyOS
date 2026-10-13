; ============================================================================
;  JoyOS — PCI 总线枚举(第一份"机器上有什么"的清单)
;
;  为什么需要它:ATA 可以硬编码 0x1F0,但 USB 控制器、网卡、声卡这些
;  "在哪、用哪个口、是哪一版",只能问 PCI。这也是给以后的 USB 铺路的第一步
;  (USB 还要靠它打开 Bus Master,不然 DMA 一个字节都动不了)。
;
;  怎么问(配置机制 #1):
;     0x0CF8  写地址:bit31=1 | bus[23:16] | slot[15:11] | func[10:8] | offset[7:0](4 字节对齐)
;     0x0CFC  读写数据(32 位;写 16 位只动命令寄存器,见下)
;
;  配置空间里我们要的几格:
;     0x00  vendor(低 16 位) + device(高 16 位)   —— vendor = 0xFFFF 表示这个位置没设备
;     0x04  command(低 16 位) + status(高 16 位)
;     0x08  revision / prog-if / subclass / class   (从低到高各一字节)
;     0x0C  cache line / latency / header type / BIST
;     0x10  BAR0..BAR5(每个 4 字节,0x10-0x24)
;     0x3C  irq line(低字节)/ irq pin
;
;  踩过的坑(README 第 6 节有全文):
;    · bit31 忘了置 1 → 读回来永远是 0,看着像"机器上一片空白";
;    · 只扫 func 0 → 会漏掉 00:01.1(IDE)、00:01.2(USB)这些多功能设备的兄弟;
;      header type(0x0E)的 bit7 = 1 才说明这个 slot 是多功能的;
;    · 读不存在的设备返回 **0xFFFF(全 1)**,不是 0 —— 判空要用 vendor != 0xFFFF;
;    · 想量 BAR 多大:先关掉命令寄存器里的 I/O/MEM 译码,写全 1 读回来反推,
;      再把原值写回去、译码恢复。顺序错了会真的去解码,甚至把 BAR 弄丢;
;    · 命令寄存器只有 16 位,而且邻居 0x06 的 status 是"写 1 清"标志位 ——
;      所以写命令寄存器要用 **16 位写**(out dx, ax),别拿 32 位写顺手指带;
;    · 想 DMA 的设备(USB 就是)必须打开 Bus Master 位(bit2),不然症状是
;      "初始化全对、一个包都收不到"。
;
;  现在只扫 bus 0(桥后面的总线得去看 bridge 的 secondary bus 号,以后再说);
;  中断也没路由:IRQ 号读得到,但 IDT 里还没有对应的门,USB 那一步再装。
; ============================================================================

PCI_CFG_ADDR    equ 0x0CF8
PCI_CFG_DATA    equ 0x0CFC

PCI_R_VENDOR    equ 0x00        ; vendor + device
PCI_R_COMMAND   equ 0x04        ; command(低 16)+ status(高 16)
PCI_R_CLASSREV  equ 0x08        ; rev / prog-if / subclass / class
PCI_R_HEADER    equ 0x0C        ; cache line / latency / header type / BIST
PCI_R_BAR0      equ 0x10        ; 六个 BAR,每个 4 字节
PCI_R_IRQ       equ 0x3C        ; irq line / irq pin

PCI_CMD_IO      equ 0x0001
PCI_CMD_MEM     equ 0x0002
PCI_CMD_BM      equ 0x0004      ; Bus Master(DMA 的总开关)

; class / subclass(配置空间 0x0A/0x0B 那两个字节)
PCI_CLS_STORAGE equ 0x01
PCI_CLS_DISPLAY equ 0x03
PCI_CLS_BRIDGE  equ 0x06
PCI_CLS_SERIAL  equ 0x0C
PCI_SUB_IDE     equ 0x01
PCI_SUB_USB     equ 0x03

; ---------------------------------------------------------------------------
;  原始的配置空间读写
; ---------------------------------------------------------------------------

; eax = 完整配置地址 → eax = 读到的 32 位值(只动 eax/edx)
pci_read32:
    push edx
    or eax, 0x80000000              ; ⚠️ bit31 是"使能"位,忘了它读回来永远是 0
    mov dx, PCI_CFG_ADDR
    out dx, eax
    mov dx, PCI_CFG_DATA
    in eax, dx
    pop edx
    ret

; eax = 完整配置地址,edx = 要写的 32 位值(只动 eax/edx)
pci_write32:
    push edx
    or eax, 0x80000000
    mov dx, PCI_CFG_ADDR
    out dx, eax
    pop edx
    mov dx, PCI_CFG_DATA
    mov eax, edx
    out dx, eax
    ret

; eax=bus ebx=slot ecx=func edx=offset → eax = 完整配置地址(输入寄存器都会被改)
pci_mk_addr:
    shl eax, 16
    shl ebx, 11
    or eax, ebx
    shl ecx, 8
    or eax, ecx
    or eax, edx
    ret

; 当前设备([pci_bus]/[pci_slot]/[pci_func])+ dl = 偏移 → eax = 完整地址(改 eax/ebx/ecx/edx)
pci_cur_addr:
    movzx eax, byte [pci_bus]
    shl eax, 16
    movzx ebx, byte [pci_slot]
    shl ebx, 11
    or eax, ebx
    movzx ecx, byte [pci_func]
    shl ecx, 8
    or eax, ecx
    movzx edx, dl
    or eax, edx
    ret

; dl = 偏移 → eax = 当前设备的那个寄存器(改 eax/ebx/ecx/edx)
pci_cur_read:
    call pci_cur_addr
    call pci_read32
    ret

; ax = 新的命令寄存器值(只动 eax/edx)
; 16 位写:0x06 那半是 status,里面全是"写 1 清"的标志位,不能顺手 32 位写回去。
pci_write_command:
    push eax
    mov dl, PCI_R_COMMAND
    call pci_cur_addr
    or eax, 0x80000000
    mov dx, PCI_CFG_ADDR
    out dx, eax
    pop eax
    mov dx, PCI_CFG_DATA
    out dx, ax
    ret

; 给当前设备打开 I/O + 内存译码 + Bus Master(USB 那种要 DMA 的必须开)
pci_cur_enable:
    pushad
    mov dl, PCI_R_COMMAND
    call pci_cur_read
    and eax, 0xFFFF
    or eax, PCI_CMD_IO | PCI_CMD_MEM | PCI_CMD_BM
    call pci_write_command
    popad
    ret

; ---------------------------------------------------------------------------
;  打印小工具(定宽十六进制 + 十进制)
; ---------------------------------------------------------------------------

; eax = 数字 → 打 n 位十六进制(pci_ph1/2/4 只是定宽入口)
; ⚠️ 第一版这里手写 push/pop 配平,结果 pci_ph2/4 少了一个 pop ——
;    弹出的其实是返回地址,ret 直接飞到 0x9208(屏幕当场变 panic 屏)。
;    改成 pushad/popad + 循环,位数由 ecx 定。
pci_ph1:
    mov ecx, 1
    jmp pci_phn

pci_ph2:
    mov ecx, 2
    jmp pci_phn

pci_ph4:
    mov ecx, 4

; eax = 值,ecx = 要打几位(1..8)
pci_phn:
    pushad
    shl ecx, 2                          ; 位数 → 位移量
.loop:
    sub ecx, 4
    mov edx, eax
    shr edx, cl
    and edx, 0x0F
    push eax
    mov eax, edx
    call pci_digit
    pop eax
    test ecx, ecx
    jnz .loop
    popad
    ret

; eax(0..15)→ 一个十六进制字符;别的寄存器不动
pci_digit:
    push eax
    push ebx
    and eax, 0x0F
    mov bl, '0'
    cmp al, 10
    jb .out
    mov bl, 'A' - 10
.out:
    add al, bl
    call term_putc
    pop ebx
    pop eax
    ret

; esi = 字符串 → 直接打(term_print 会保护 eax/esi,这里再多护一层)
pci_puts:
    push eax
    push esi
    call term_print
    pop esi
    pop eax
    ret

; ---------------------------------------------------------------------------
;  类别名字表:key = (class << 8) | subclass
; ---------------------------------------------------------------------------

; eax = class << 8 | subclass → esi = 名字指针(查不到就是 "unknown device")
pci_class_name:
    mov edx, eax
    mov ecx, pci_class_tab
.next:
    movzx eax, word [ecx]
    cmp ax, 0xFFFF                  ; 表尾
    je .unknown
    cmp eax, edx
    je .hit
    add ecx, 6                      ; dw key + dd 指针
    jmp .next
.hit:
    mov esi, [ecx + 2]
    ret
.unknown:
    mov esi, msg_pci_unknown
    ret

; 当前设备的类别名(USB 那几种按 prog-if 细分:00=UHCI / 10=OHCI / 20=EHCI / 30=xHCI)
pci_cur_class_name:
    push eax
    mov eax, [pci_last_class]
    shr eax, 16                     ; class<<8 | subclass
    movzx ebx, byte [pci_last_progif]
    cmp eax, (PCI_CLS_SERIAL << 8) | PCI_SUB_USB
    jne .generic
    cmp bl, 0x00
    je .uhci
    cmp bl, 0x10
    je .ohci
    cmp bl, 0x20
    je .ehci
    cmp bl, 0x30
    je .xhci
    mov esi, msg_pci_usb_other
    jmp .out
.uhci:
    mov esi, msg_pci_usb_uhci
    jmp .out
.ohci:
    mov esi, msg_pci_usb_ohci
    jmp .out
.ehci:
    mov esi, msg_pci_usb_ehci
    jmp .out
.xhci:
    mov esi, msg_pci_usb_xhci
    jmp .out
.generic:
    call pci_class_name
.out:
    pop eax
    ret

; ---------------------------------------------------------------------------
;  扫一遍总线
; ---------------------------------------------------------------------------

; 把一台设备记进账:统计、记 IDE / USB、顺手打开译码 + Bus Master
pci_note_device:
    pushad
    inc dword [pci_count]

    ; class / subclass / prog-if / revision
    mov dl, PCI_R_CLASSREV
    call pci_cur_read
    mov [pci_last_class], eax
    mov [pci_last_id], ebx          ; ebx 里是 vendor|device(下面重读一次更保险)
    mov dl, PCI_R_VENDOR
    call pci_cur_read
    mov [pci_last_id], eax
    mov ecx, eax
    and ecx, 0xFFFF                 ; vendor
    shr eax, 16                     ; device
    mov [pci_last_vendor], ecx
    mov [pci_last_device], eax

    mov eax, [pci_last_class]
    mov ebx, eax
    shr ebx, 24                     ; class
    mov [pci_last_cls], ebx
    mov ebx, eax
    shr ebx, 16
    and ebx, 0xFF                   ; subclass
    mov [pci_last_sub], ebx
    mov ebx, eax
    shr ebx, 8
    and ebx, 0xFF                   ; prog-if
    mov [pci_last_progif], bl

    ; 打开 I/O + MEM + Bus Master(USB 要 DMA)
    call pci_cur_enable

    ; IDE 控制器(第一次见到的)
    cmp dword [pci_last_cls], PCI_CLS_STORAGE
    jne .usb
    cmp dword [pci_last_sub], PCI_SUB_IDE
    jne .usb
    cmp dword [pci_ide_addr], -1
    jne .print
    call pci_pack_addr
    mov [pci_ide_addr], eax
    mov eax, [pci_last_id]
    mov [pci_ide_id], eax

.usb:
    cmp dword [pci_last_cls], PCI_CLS_SERIAL
    jne .print
    cmp dword [pci_last_sub], PCI_SUB_USB
    jne .print
    cmp dword [pci_usb_addr], -1
    jne .print
    call pci_pack_addr
    mov [pci_usb_addr], eax
    mov eax, [pci_last_id]
    mov [pci_usb_id], eax
    movzx eax, byte [pci_last_progif]
    mov [pci_usb_iface], eax
    mov dl, PCI_R_BAR0 + 4 * 4      ; USB 控制器的 BAR4:UHCI 是 I/O 口,OHCI/EHCI 是内存
    call pci_cur_read
    mov [pci_usb_bar], eax

.print:
    cmp byte [pci_verbose], 0
    je .done
    call pci_print_one
.done:
    popad
    ret

; 把当前 [pci_bus]/[pci_slot]/[pci_func] 打包成 (bus<<16)|(slot<<11)|(func<<8)
pci_pack_addr:
    movzx eax, byte [pci_bus]
    shl eax, 16
    movzx ebx, byte [pci_slot]
    shl ebx, 11
    or eax, ebx
    movzx ecx, byte [pci_func]
    shl ecx, 8
    or eax, ecx
    ret

; 看一个 func。有设备的话记账,verbose 时逐行打印。
pci_scan_func:
    mov dl, PCI_R_VENDOR
    call pci_cur_read
    cmp ax, 0xFFFF                  ; 全 1 = 这个位置没插东西
    je .out
    call pci_note_device
.out:
    ret

; 整个 bus 0:slot 0..31;多功能设备还要把 func 1..7 扫一遍
; (只扫 func 0 的话,00:01.1 的 IDE、00:01.2 的 USB 就全漏了)
pci_scan_all:
    pushad
    mov dword [pci_count], 0
    mov dword [pci_ide_addr], -1
    mov dword [pci_usb_addr], -1
    mov dword [pci_usb_iface], 0xFF
    mov byte [pci_bus], 0
    mov byte [pci_slot], 0
.slot:
    cmp byte [pci_slot], 32
    jae .done
    mov byte [pci_func], 0
    call pci_scan_func
    ; header type 的 bit7 = 多功能标志(在 0x0E,也就是 0x0C 那个 dword 的 bit23)
    mov dl, PCI_R_HEADER
    call pci_cur_read
    test eax, 0x00800000
    jz .next_slot
    mov byte [pci_func], 1
.func:
    cmp byte [pci_func], 8
    jae .next_slot
    call pci_scan_func
    inc byte [pci_func]
    jmp .func
.next_slot:
    inc byte [pci_slot]
    jmp .slot
.done:
    popad
    ret

; ---------------------------------------------------------------------------
;  对外:开机点名 / 列清单 / 看一台设备
; ---------------------------------------------------------------------------

; 开机那一行:pci: 14 devices on bus 0, IDE 8086:7010, USB 8086:7020 (UHCI 1.1)
pci_scan:
    pushad
    mov byte [pci_verbose], 0
    call pci_scan_all
    mov esi, msg_pci_boot
    call pci_puts
    mov eax, [pci_count]
    call term_print_dec
    mov esi, msg_pci_devices
    call pci_puts
    cmp dword [pci_ide_addr], -1
    je .usb
    mov esi, msg_pci_ide
    call pci_puts
    mov eax, [pci_ide_id]
    call pci_ph4
    mov al, ':'
    call term_putc
    mov eax, [pci_ide_id]
    shr eax, 16
    call pci_ph4
.usb:
    cmp dword [pci_usb_addr], -1
    je .end
    mov esi, msg_pci_usb
    call pci_puts
    mov eax, [pci_usb_id]
    call pci_ph4
    mov al, ':'
    call term_putc
    mov eax, [pci_usb_id]
    shr eax, 16
    call pci_ph4
    mov esi, msg_pci_lparen
    call pci_puts
    mov eax, [pci_usb_iface]
    cmp eax, 0x00
    je .uhci
    cmp eax, 0x10
    je .ohci
    cmp eax, 0x20
    je .ehci
    cmp eax, 0x30
    je .xhci
    mov esi, msg_pci_usb_other
    jmp .name
.uhci:
    mov esi, msg_pci_usb_uhci
    jmp .name
.ohci:
    mov esi, msg_pci_usb_ohci
    jmp .name
.ehci:
    mov esi, msg_pci_usb_ehci
    jmp .name
.xhci:
    mov esi, msg_pci_usb_xhci
.name:
    call pci_puts
    mov esi, msg_pci_rparen
    call pci_puts
.end:
    mov al, 10
    call term_putc
    popad
    ret

; pci 命令:表头 + 每台一行 + 小结
pci_list:
    pushad
    mov esi, msg_pci_head
    call pci_puts
    mov byte [pci_verbose], 1
    call pci_scan_all
    mov byte [pci_verbose], 0
    mov esi, msg_pci_found
    call pci_puts
    mov eax, [pci_count]
    call term_print_dec
    mov esi, msg_pci_on_bus0
    call pci_puts
    popad
    ret

pci_print_one:
    pushad
    mov al, ' '
    call term_putc
    movzx eax, byte [pci_bus]
    call pci_ph2
    mov al, ':'
    call term_putc
    movzx eax, byte [pci_slot]
    call pci_ph2
    mov al, '.'
    call term_putc
    movzx eax, byte [pci_func]
    call pci_ph1
    mov esi, msg_pci_gap
    call pci_puts
    mov eax, [pci_last_vendor]
    call pci_ph4
    mov al, ':'
    call term_putc
    mov eax, [pci_last_device]
    call pci_ph4
    mov esi, msg_pci_gap
    call pci_puts
    mov eax, [pci_last_cls]
    call pci_ph2
    mov al, '.'
    call term_putc
    mov eax, [pci_last_sub]
    call pci_ph2
    mov esi, msg_pci_gap
    call pci_puts
    call pci_cur_class_name
    call pci_puts
    mov esi, msg_pci_irq
    call pci_puts
    mov dl, PCI_R_IRQ
    call pci_cur_read
    and eax, 0xFF
    call term_print_dec
    mov al, 10
    call term_putc
    popad
    ret

; eax = 打包地址(来自 pci_parse_addr 或 pci_pack_addr)→ 详情
pci_show:
    pushad
    mov byte [pci_bus], 0
    mov byte [pci_slot], 0
    mov byte [pci_func], 0
    mov ebx, eax
    shr eax, 16
    mov [pci_bus], al
    mov eax, ebx
    shr eax, 11
    and eax, 0x1F
    mov [pci_slot], al
    mov eax, ebx
    shr eax, 8
    and eax, 0x07
    mov [pci_func], al

    mov dl, PCI_R_VENDOR
    call pci_cur_read
    cmp ax, 0xFFFF
    jne .found
    mov esi, msg_pci_nodev
    call pci_puts
    jmp .done
.found:
    mov [pci_last_id], eax
    mov ecx, eax
    and ecx, 0xFFFF
    mov [pci_last_vendor], ecx
    shr eax, 16
    mov [pci_last_device], eax
    mov dl, PCI_R_CLASSREV
    call pci_cur_read
    mov [pci_last_class], eax
    mov ebx, eax
    shr ebx, 24
    mov [pci_last_cls], ebx
    mov ebx, eax
    shr ebx, 16
    and ebx, 0xFF
    mov [pci_last_sub], ebx
    mov ebx, eax
    shr ebx, 8
    and ebx, 0xFF
    mov [pci_last_progif], bl

    ; 第一行:和清单里同款
    call pci_print_one

    ; 第二行:class/prog-if/rev/header/irq/command
    mov esi, msg_pci_class_is
    call pci_puts
    mov eax, [pci_last_cls]
    call pci_ph2
    mov al, '.'
    call term_putc
    mov eax, [pci_last_sub]
    call pci_ph2
    mov esi, msg_pci_progif
    call pci_puts
    movzx eax, byte [pci_last_progif]
    call pci_ph2
    mov esi, msg_pci_rev
    call pci_puts
    mov eax, [pci_last_class]
    and eax, 0xFF
    call pci_ph2
    mov esi, msg_pci_header
    call pci_puts
    mov dl, PCI_R_HEADER
    call pci_cur_read
    shr eax, 16
    and eax, 0xFF
    call pci_ph2
    test al, 0x80
    jz .irq
    mov esi, msg_pci_multifunc
    call pci_puts
.irq:
    mov esi, msg_pci_irq
    call pci_puts
    mov dl, PCI_R_IRQ
    call pci_cur_read
    push eax
    and eax, 0xFF
    call term_print_dec
    mov esi, msg_pci_cmd
    call pci_puts
    pop eax
    mov dl, PCI_R_COMMAND
    call pci_cur_read
    and eax, 0xFFFF
    call pci_ph4
    mov esi, msg_pci_bm
    call pci_puts
    mov dl, PCI_R_COMMAND
    call pci_cur_read
    test eax, PCI_CMD_BM
    jz .no_bm
    mov esi, msg_pci_yes
    call pci_puts
    jmp .bars
.no_bm:
    mov esi, msg_pci_no
    call pci_puts
.bars:
    mov al, 10
    call term_putc
    mov byte [pci_bar_i], 0
.bar_loop:
    cmp byte [pci_bar_i], 6
    jae .done
    call pci_show_bar
    inc byte [pci_bar_i]
    jmp .bar_loop
.done:
    popad
    ret

; 打一行 BAR:  BAR0  I/O   0xc020  size 32 bytes
pci_show_bar:
    pushad
    mov esi, msg_pci_bar
    call pci_puts
    movzx eax, byte [pci_bar_i]
    call term_print_dec
    mov esi, msg_pci_gap
    call pci_puts

    mov al, [pci_bar_i]
    shl al, 2                       ; offset = 0x10 + i*4
    add al, PCI_R_BAR0
    mov dl, al
    call pci_cur_read
    mov [pci_bar_val], eax
    test eax, eax
    jnz .have
    mov esi, msg_pci_bar_none
    call pci_puts
    mov al, 10
    call term_putc
    popad
    ret
.have:
    test eax, 1                     ; bit0 = 1 → I/O 空间
    jz .mem
    mov esi, msg_pci_bar_io
    call pci_puts
    and eax, 0xFFFFFFFC
    call term_print_hex
    ; ⚠️ 这里**故意不量尺寸**:I/O BAR 写全 1 再读回,在这台 QEMU 上会把后面的
    ;    配置空间读写整个搞挂(现象:之后所有设备都读成 0x0004/全 0,
    ;    连 IDE 的 BAR4 尺寸都读成 62224 这种鬼数字)。只报地址就够用了 ——
    ;    USB 驱动要的 UHCI BAR4 正是这个 I/O 基址。
    jmp .noline
.mem:
    mov esi, msg_pci_bar_mem
    call pci_puts
    mov ecx, eax
    shr ecx, 1
    and ecx, 3                      ; 类型:0=32 位以下,2=64 位
    cmp ecx, 2
    jne .mem32
    mov esi, msg_pci_bar_mem64
    call pci_puts
    and eax, 0xFFFFFFF0
    call term_print_hex
    mov al, 10
    call term_putc
    popad
    ret
.mem32:
    and eax, 0xFFFFFFF0
    call term_print_hex
.size:
    call pci_bar_size
    test eax, eax
    jz .noline
    mov esi, msg_pci_bar_size
    call pci_puts
    call term_print_dec
    mov esi, msg_pci_bytes
    call pci_puts
.noline:
    mov al, 10
    call term_putc
    popad
    ret

; 当前设备、当前 BAR(pci_bar_i)的尺寸(字节;0 = 量不出来)
; 量法:关掉 I/O/MEM 译码 → 写全 1 → 读回来反推 → 原值写回 → 译码恢复。
; 不关译码就写全 1,设备可能真的拿它去解码。
; 当前设备、当前 BAR(pci_bar_i)的尺寸(字节;0 = 量不出来)
; 量法(只给内存 BAR 用):先关掉命令寄存器里的 I/O/MEM 译码 → 往 BAR 写全 1 →
; 读回来反推 → 原值写回 → 译码恢复。不关译码就写全 1,设备可能真的拿它去解码。
; I/O BAR 不走这条路(pci_show_bar 里直接跳过),原因写在那儿。
pci_bar_size:
    pushad
    mov dword [pci_bar_size_v], 0

    mov dl, PCI_R_COMMAND
    call pci_cur_read
    mov [pci_saved_cmd], eax
    and eax, 0xFFFF
    and eax, ~(PCI_CMD_IO | PCI_CMD_MEM)
    call pci_write_command

    mov al, [pci_bar_i]
    shl al, 2
    add al, PCI_R_BAR0
    mov [pci_bar_off], al               ; 偏移存起来,后面反复要用(dl 会被别的调用吃掉)
    mov dl, al
    call pci_cur_read
    mov [pci_saved_bar], eax

    mov dl, [pci_bar_off]
    call pci_cur_addr
    mov edx, 0xFFFFFFFF
    call pci_write32

    mov dl, [pci_bar_off]
    call pci_cur_read
    and eax, 0xFFFFFFF0                 ; 低 4 位是类型标志,不参与"有多大"
    test eax, eax
    jz .restore
    not eax
    inc eax                             ; size = ~mask + 1
    mov [pci_bar_size_v], eax

.restore:
    mov dl, [pci_bar_off]
    call pci_cur_addr
    mov edx, [pci_saved_bar]
    call pci_write32
    mov ax, [pci_saved_cmd]
    call pci_write_command
    popad
    mov eax, [pci_bar_size_v]
    ret

; ---------------------------------------------------------------------------
;  "0:1.2" / "1.2" → eax = 打包地址,CF=0;格式不对 CF=1
; ---------------------------------------------------------------------------
pci_parse_addr:
    push ebx
    push ecx
    push edx
    push esi
    mov byte [pci_p_have_colon], 0
    mov byte [pci_p_have_dot], 0
    mov dword [pci_p_first], 0
    mov dword [pci_p_second], 0
    mov dword [pci_p_third], 0
    xor ebx, ebx                    ; 当前累积的数
    xor ecx, ecx                    ; 这一段读了几位(0 = 空段,算错)
.next:
    mov al, [esi]
    inc esi
    test al, al
    jz .fin
    cmp al, ':'
    je .colon
    cmp al, '.'
    je .dot
    call pci_hexval
    jc .bad
    shl ebx, 4
    or ebx, eax
    inc ecx
    cmp ecx, 4                      ; 一个段最多 2 位十六进制
    ja .bad
    jmp .next
.colon:
    test ecx, ecx
    jz .bad
    cmp byte [pci_p_have_colon], 0
    jne .bad
    mov [pci_p_first], ebx          ; 冒号前 = bus
    mov byte [pci_p_have_colon], 1
    xor ebx, ebx
    xor ecx, ecx
    jmp .next
.dot:
    test ecx, ecx
    jz .bad
    cmp byte [pci_p_have_dot], 0
    jne .bad
    mov [pci_p_second], ebx         ; 点前 = slot
    mov byte [pci_p_have_dot], 1
    xor ebx, ebx
    xor ecx, ecx
    jmp .next
.fin:
    test ecx, ecx
    jz .bad
    cmp byte [pci_p_have_dot], 0
    je .bad                         ; 至少要写成 slot.func
    mov [pci_p_third], ebx
    cmp dword [pci_p_second], 32
    jae .bad
    cmp dword [pci_p_third], 8
    jae .bad
    mov eax, [pci_p_second]
    shl eax, 11
    mov ebx, [pci_p_third]
    shl ebx, 8
    or eax, ebx
    cmp byte [pci_p_have_colon], 0
    je .ok
    cmp dword [pci_p_first], 256
    jae .bad
    mov ebx, [pci_p_first]
    shl ebx, 16
    or eax, ebx
.ok:
    pop esi
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.bad:
    pop esi
    pop edx
    pop ecx
    pop ebx
    stc
    ret

; al = 字符 → eax = 0..15;不是十六进制数字就 CF=1
pci_hexval:
    cmp al, '0'
    jb .bad
    cmp al, '9'
    jbe .dec
    cmp al, 'A'
    jb .low
    cmp al, 'F'
    jbe .up
    jmp .bad
.low:
    cmp al, 'a'
    jb .bad
    cmp al, 'f'
    ja .bad
    sub al, 'a' - 10
    jmp .ok
.up:
    sub al, 'A' - 10
    jmp .ok
.dec:
    sub al, '0'
.ok:
    movzx eax, al
    clc
    ret
.bad:
    stc
    ret

; ---------------------------------------------------------------------------
;  shell 的 pci 命令:不带参数 = 列表;带 0:1.2 = 看那一台的详情
; ---------------------------------------------------------------------------
cmd_pci:
    pushad
    call strip_name                     ; 只吃一个参数(带空格会被截断,这里用不着)
    mov esi, [cmd_arg]
    cmp byte [esi], 0
    je .list
    call pci_parse_addr
    jc .bad
    call pci_show
    jmp .done
.list:
    call pci_list
    jmp .done
.bad:
    mov esi, msg_pci_usage
    call pci_puts
.done:
    popad
    ret

; ---------------------------------------------------------------------------
;  数据
; ---------------------------------------------------------------------------

pci_count       dd 0
pci_verbose     db 0
pci_bus         db 0
pci_slot        db 0
pci_func        db 0
pci_bar_i       db 0
pci_p_have_colon db 0
pci_p_have_dot  db 0

pci_last_id     dd 0
pci_last_vendor dd 0
pci_last_device dd 0
pci_last_class  dd 0
pci_last_cls    dd 0
pci_last_sub    dd 0
pci_last_progif db 0

; 给以后的 USB 用:这几位一开机就填好了
pci_ide_addr    dd -1
pci_ide_id      dd 0
pci_usb_addr    dd -1
pci_usb_id      dd 0
pci_usb_iface   dd 0xFF
pci_usb_bar     dd 0

pci_p_first     dd 0
pci_p_second    dd 0
pci_p_third     dd 0
pci_saved_cmd   dd 0
pci_saved_bar   dd 0
pci_bar_val     dd 0
pci_bar_off     db 0
pci_bar_size_v  dd 0
pci_tmp         dd 0

; class<<8 | subclass → 名字。查不到用 msg_pci_unknown。
pci_class_tab:
    dw (0x00 << 8) | 0x00
    dd s_pci_cls_unclassified
    dw (0x00 << 8) | 0x01
    dd s_pci_cls_vga_legacy
    dw (PCI_CLS_STORAGE << 8) | 0x00
    dd s_pci_cls_scsi
    dw (PCI_CLS_STORAGE << 8) | PCI_SUB_IDE
    dd s_pci_cls_ide
    dw (PCI_CLS_STORAGE << 8) | 0x06
    dd s_pci_cls_ahci
    dw (PCI_CLS_STORAGE << 8) | 0x80
    dd s_pci_cls_storage_other
    dw (0x02 << 8) | 0x00
    dd s_pci_cls_ethernet
    dw (PCI_CLS_DISPLAY << 8) | 0x00
    dd s_pci_cls_vga
    dw (PCI_CLS_DISPLAY << 8) | 0x01
    dd s_pci_cls_xga
    dw (0x04 << 8) | 0x00
    dd s_pci_cls_video
    dw (0x04 << 8) | 0x01
    dd s_pci_cls_audio
    dw (PCI_CLS_BRIDGE << 8) | 0x00
    dd s_pci_cls_host
    dw (PCI_CLS_BRIDGE << 8) | 0x01
    dd s_pci_cls_isa
    dw (PCI_CLS_BRIDGE << 8) | 0x04
    dd s_pci_cls_pcibridge
    dw (PCI_CLS_BRIDGE << 8) | 0x80
    dd s_pci_cls_bridge_other
    dw (0x07 << 8) | 0x00
    dd s_pci_cls_serial
    dw (PCI_CLS_SERIAL << 8) | 0x00
    dd s_pci_cls_firewire
    dw (PCI_CLS_SERIAL << 8) | PCI_SUB_USB
    dd s_pci_cls_usb
    dw (PCI_CLS_SERIAL << 8) | 0x05
    dd s_pci_cls_smbus
    dw 0xFFFF                       ; 表尾

s_pci_cls_unclassified  db 'unclassified', 0
s_pci_cls_vga_legacy    db 'VGA-compatible device', 0
s_pci_cls_scsi          db 'SCSI storage controller', 0
s_pci_cls_ide           db 'IDE controller', 0
s_pci_cls_ahci          db 'SATA/AHCI controller', 0
s_pci_cls_storage_other db 'storage controller (other)', 0
s_pci_cls_ethernet      db 'Ethernet controller', 0
s_pci_cls_vga           db 'VGA display controller', 0
s_pci_cls_xga           db 'XGA display controller', 0
s_pci_cls_video         db 'video/multimedia device', 0
s_pci_cls_audio         db 'audio device', 0
s_pci_cls_host          db 'host bridge', 0
s_pci_cls_isa           db 'ISA bridge', 0
s_pci_cls_pcibridge     db 'PCI bridge', 0
s_pci_cls_bridge_other  db 'bridge (other)', 0
s_pci_cls_serial        db 'serial port', 0
s_pci_cls_firewire      db 'FireWire controller', 0
s_pci_cls_usb           db 'USB controller', 0
s_pci_cls_smbus         db 'SMBus controller', 0

msg_pci_boot     db 'pci: ', 0
msg_pci_devices  db ' devices on bus 0', 0
msg_pci_ide      db ', IDE ', 0
msg_pci_usb      db ', USB ', 0
msg_pci_lparen   db ' (', 0
msg_pci_rparen   db ')', 0
msg_pci_usb_uhci db 'UHCI 1.1', 0
msg_pci_usb_ohci db 'OHCI 1.1', 0
msg_pci_usb_ehci db 'EHCI 2.0', 0
msg_pci_usb_xhci db 'xHCI 3.x', 0
msg_pci_usb_other db 'USB (unknown interface)', 0
msg_pci_head     db 'PCI devices on bus 0:', 10, 0
msg_pci_found    db 'pci: ', 0
msg_pci_on_bus0  db ' device(s) found on bus 0', 10, 0
msg_pci_gap      db '  ', 0
msg_pci_unknown  db 'unknown device', 0
msg_pci_irq      db '  irq ', 0
msg_pci_nodev    db 'pci: no device at that address', 10, 0
msg_pci_class_is db '  class ', 0
msg_pci_progif   db '  prog-if ', 0
msg_pci_rev      db '  rev ', 0
msg_pci_header   db '  header ', 0
msg_pci_multifunc db ' (multifunction)', 0
msg_pci_cmd      db '  command ', 0
msg_pci_bm       db '  bus master: ', 0
msg_pci_yes      db 'yes', 0
msg_pci_no       db 'no', 0
msg_pci_bar      db '  BAR', 0
msg_pci_bar_none db '  --', 0
msg_pci_bar_io   db 'I/O    ', 0
msg_pci_bar_mem  db 'memory ', 0
msg_pci_bar_mem64 db 'memory (64-bit) ', 0
msg_pci_bar_size db '  size ', 0
msg_pci_bytes    db ' bytes', 0
msg_pci_usage    db 'pci: usage: pci [bus:slot.func]  (no argument = list devices)', 10, 0
