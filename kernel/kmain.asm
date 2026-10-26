; ============================================================================
;  JoyOS — 内核入口
;
;  这个文件负责"开机报到"+ 终端输出,其它功能在各自文件里:
;      kernel/idt.asm       中断描述符表 + CPU 异常(panic 屏)
;      kernel/paging.asm    页目录/页表 + 开分页
;      kernel/keyboard.asm  PS/2 键盘(PIC 重映射 + IRQ1)
;      kernel/shell.asm     那个很土的 shell
;
;  构建: nasm -f bin -I kernel/ kernel/kmain.asm -o build/kernel.bin
;        (要 -I kernel/ 才能 %include 到同目录的文件)
;
;  内存布局(这个阶段的约定):
;      0x00000-0x004FF   中断向量表 / BIOS 数据区
;      0x01000-0x01FFF   页目录(PD_ADDR)
;      0x02000           恒等 0-4 MiB 页表(PT_LOW)
;      0x04000           VBE 帧缓冲页表(PT_LFB,仅图形模式)
;      (4 MiB 以上的恒等页表:运行时从页池拿,没固定地址)
;      0x07C00           引导扇区(512 字节)
;      0x10000-0x2FFFF   内核区(128 KiB = 256 扇区,引导扇区读进来的;
;                        内核映像本身约 48 KiB,后面是补零)
;      0x90000           内核栈(往下长)
;      0xB8000           VGA 文本缓冲(80×25,每格 2 字节:字符 + 颜色)
;      0x100000-0x10FFFF FAT 扇区缓冲(FAT_BUF)
;      0x110000-0x11EFFF cat 的文件缓冲(FILE_BUF)
;      0x11F000          程序参数块(PROG_ARG_ADDR)
;      0x120000-0x19FFFF 用户程序镜像(PROG_ADDR;加载器硬上限是 PROG_MAX_SIZE 896 KiB,
;                        但超过 512 KiB 就会压到堆 —— 以 include/joyos.h 为准)
;      0x180000-0x1EDFFF 堆(malloc,440 KB)※ 和程序加载区有重叠,见 include/joyos.h
;      0x1F0000          内核临时缓冲(读字库描述块)
;      0x200000-0x3AFFFF 完整字库(FONT_LOAD_ADDR,1.7 MB)
;      0x3B0000-0x3BFFFF PINYIN 拼音表(ime.asm)
;      0x3C0000-0x3C1FFF USB 帧列表/QH/TD(usb.asm)
;      0x3D0000-0x3D1FFF 页池位图(pmem.asm;8 KiB,最多记 64512 页 = 252 MiB)
;      0x400000-ident    物理页池(pmem.asm 的位图分配器;上界按 RAM 自适应,最大 252 MiB)
;      0xFD000000…       VBE 线性帧缓冲(页表按 4 MiB 窗口映射,真实基址看 fb_phys)
;      0~ident 全是恒等映射(ident 按 E820 自适应,4~256 MiB;虚拟地址 = 物理地址),
;      所以指针就是物理地址;页池只从 0x400000 往上发,
;      低 4 MiB 被上面这些固定区域占满了。
; ============================================================================

BOOTINFO   equ 0x8000
VGA_MEM    equ 0xB8000
VGA_COLS   equ 80
VGA_ROWS   equ 25
; 恒等映射的上限:0~16 MiB 线性 = 物理(paging.asm 建表),页池也顶在这儿(pmem.asm)。
; 内核里凡是"地址能不能直接当指针用"的判断都以它为准(比如 ata.asm 的安全闸)。
IDENT_LIMIT equ 0x10000000             ; 恒等映射的**编译期上限** 256 MiB(运行时用 ident_limit)

; 用户程序地址窗口(与 kernel/paging.asm 的 SPACE_* 必须一致;
; paging.asm 那边用 %ifndef 守着,只认这里的一份)。
SPACE_IMG_VA     equ 0x120000
SPACE_IMG_PAGES  equ 0x60              ; 384 KiB
SPACE_HEAP_VA    equ 0x180000
SPACE_HEAP_PAGES equ 0x70              ; 448 KiB
SPACE_TRAMP_VA   equ SPACE_IMG_VA + (SPACE_IMG_PAGES - 1) * 4096
SPACE_ARGS_VA    equ SPACE_HEAP_VA + (SPACE_HEAP_PAGES - 2) * 4096
SPACE_STACK_VA   equ SPACE_HEAP_VA + (SPACE_HEAP_PAGES - 1) * 4096
SPACE_USER_STACK_TOP equ SPACE_STACK_VA + 4092

COL_NORMAL equ 0x07                    ; 浅灰
COL_HEADER equ 0x0B                    ; 亮青
COL_OK     equ 0x0A                    ; 亮绿
COL_ERR    equ 0x0C                    ; 亮红

    ; 启动参数由引导扇区/实模式 stub 写在固定地址 BOOTINFO(0x8000)
    mov eax, [BOOTINFO + 4]
    mov [boot_sectors], eax            ; 内核区扇区数
    mov eax, [BOOTINFO + 8]
    mov [boot_lba], eax                ; 内核起始 LBA
    mov eax, [BOOTINFO + 12]
    mov [boot_mode], eax               ; 1 = LBA(EDD),0 = CHS 退回
    mov eax, [BOOTINFO + 64]
    mov [vbe_ok], eax                  ; 1 = 拿到图形模式
    mov eax, [BOOTINFO + 16]
    mov [fb_phys], eax
    mov eax, [BOOTINFO + 20]
    mov [fb_width], eax
    mov eax, [BOOTINFO + 24]
    mov [fb_height], eax
    mov eax, [BOOTINFO + 28]
    mov [fb_pitch], eax
    mov eax, [BOOTINFO + 32]
    mov [fb_bpp], eax

    ; ---- 物理内存探测结果 → 运行时布局(阶段 1:自适应)----
    ;   ram_top     = 引导 stub 探到的可用 RAM 顶端(字节;0 = 没探到)
    ;   ident_limit = 恒等映射上限 = min(ram_top 向下取整到 4 MiB, 256 MiB),最少 4 MiB
    ;   pmem        = 0x400000 ~ ident_limit(恒等映射以内才发得出去)
    mov eax, [BOOTINFO + 96]
    test eax, eax
    jnz .ram_top_ok
    mov eax, IDENT_LIMIT                ; 兜底:老约定 16 MiB
.ram_top_ok:
    mov [ram_top], eax
    mov ecx, eax
    shr ecx, 22                         ; 4 MiB 为单位
    test ecx, ecx
    jnz .ident_units_ok
    mov ecx, 1                          ; 至少 4 MiB(内核低区要用)
.ident_units_ok:
    cmp ecx, 64                         ; 最多 256 MiB(页池位图 8 KiB 记 64512 页)
    jbe .ident_cap_ok
    mov ecx, 64
.ident_cap_ok:
    shl ecx, 22
    mov [ident_limit], ecx
    mov dword [pmem_start], 0x400000
    mov [pmem_end], ecx
    mov eax, ecx
    sub eax, 0x400000
    shr eax, 12
    mov [pmem_total], eax
    mov [pmem_pages], eax
    add eax, 31
    shr eax, 5
    mov [pmem_words], eax
    mov eax, [BOOTINFO + 104]
    mov [e820_entries], eax

    ; ---- 字库:先从磁盘尝试读完整版(读不到就退回内建子集)----
    call font_load_from_disk

    ; ---- 物理页池(位图分配器):4 MiB ~ ident 交给它 ----
    ;  ★ 必须赶在 fb_init 之前:帧缓冲终端的"当前行"缓冲要从这里要 13 页
    ;    (52 KiB,内核静态区塞不下)。pmem_init 只动 0x3D0000 的位图和几个计数器,
    ;    那时还没开分页,地址本来就是线性=物理,直接访问没有问题。
    call pmem_init

    ; 图形模式:先把帧缓冲终端初始化(它自己会清屏,所以要在任何打印之前)
    cmp dword [vbe_ok], 0
    je .skip_fb_early
    call fb_init
.skip_fb_early:

%ifdef USE_CUSTOM_FONT
    call vgafont_init                  ; 实验中的自定义点阵字模(见 font/README.md)
%endif

    call term_init                     ; 清屏 + 光标归位

    ; ---- 开机报到 ----
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_title
    call term_print
    mov al, 10
    call term_putc


    mov al, COL_NORMAL
    call term_set_color
    mov esi, msg_chain
    call term_print

%ifdef USE_CUSTOM_FONT
    ; 中文自检:这一行是从 Unifont 点阵拼出来的
    mov esi, msg_utf8_tag
    call term_print
    mov esi, zh_str_2                   ; "这是 JoyOS 的中文显示。"
    call term_print_zh
%endif

    mov esi, msg_sectors
    call term_print
    mov eax, [boot_sectors]
    call term_print_dec
    mov esi, msg_equals
    call term_print
    mov eax, [boot_sectors]
    shl eax, 9
    call term_print_dec
    mov esi, msg_bytes
    call term_print

    mov esi, msg_kmain
    call term_print
    call term_print_addr
    mov esi, msg_pm
    call term_print

    mov esi, msg_seg
    call term_print
    mov ax, ds
    movzx eax, ax
    call term_print_hex
    mov esi, msg_seg2
    call term_print

    ; 引导扇区是用哪种方式读的盘
    mov esi, msg_disk
    call term_print
    cmp dword [boot_mode], 0
    je .chs
    mov esi, msg_disk_lba
    jmp .disk_done
.chs:
    mov esi, msg_disk_chs
.disk_done:
    call term_print

    ; ---- 装 IDT ----
    call idt_init
    mov esi, msg_idt
    call term_print

    ; ---- x87 浮点单元:CR0 的 NE 位改成现代语义,异常走 #MF(向量 16)----
    ;  ★ 必须在 idt_init 之后:NE=1 时浮点错误会进 #MF,没有 IDT 就三重故障。
    call fpu_init
    test al, al
    jz .fpu_none
    mov esi, msg_fpu_ok
    call term_print
    jmp .fpu_done
.fpu_none:
    mov esi, msg_fpu_none
    call term_print
.fpu_done:

    ; ---- ring 3 的地基:换一张带用户段的 GDT + 建 TSS + ltr ----
    ;  必须赶在开中断之前(函数自己也 pushfd/cli)。TSS 是 CPU 从 ring 3 掉回
    ;  ring 0 时唯一的"内核栈在哪"来源,没它就三重故障重启。
    call gdt_tss_init
    mov esi, msg_ring3
    call term_print

    ; ---- 开分页 ----
    call paging_init
    mov esi, msg_paging
    call term_print
    mov eax, [ident_limit]
    shr eax, 20
    call term_print_dec
    mov esi, msg_paging2
    call term_print

    ; ---- 物理页池:开机更早的地方已经初始化过(见上面 —— fb_init 要先用)----
    ; 这里把实际布局报出来(数字来自启动时的运行时计算,不是写死的)
    mov esi, msg_pmem
    call term_print
    mov eax, [pmem_start]
    call term_print_hex
    mov esi, msg_layout_dash
    call term_print
    mov eax, [pmem_end]
    call term_print_hex
    mov esi, msg_layout_comma
    call term_print
    mov eax, [pmem_total]
    call term_print_dec
    mov esi, msg_pmem2
    call term_print

    ; ---- 机器可读的布局行(测试脚本/调试用,别改格式;太长就分三行)----
    mov esi, msg_layout1
    call term_print
    mov eax, [ram_top]
    shr eax, 20
    call term_print_dec
    mov esi, msg_layout1b
    call term_print
    mov eax, [e820_entries]
    call term_print_dec
    mov esi, msg_layout1c
    call term_print
    mov eax, [ident_limit]
    shr eax, 20
    call term_print_dec
    mov esi, msg_layout_mib
    call term_print

    mov esi, msg_layout2
    call term_print
    mov eax, [pmem_start]
    call term_print_hex
    mov esi, msg_layout_dash
    call term_print
    mov eax, [pmem_end]
    call term_print_hex
    mov esi, msg_layout2b
    call term_print
    mov eax, [pmem_total]
    call term_print_dec
    mov al, 10
    call term_putc

    mov esi, msg_layout3
    call term_print
    mov eax, SPACE_IMG_VA
    call term_print_hex
    mov esi, msg_layout_plus
    call term_print
    mov eax, SPACE_IMG_PAGES
    call term_print_dec
    mov esi, msg_layout_p
    call term_print
    mov eax, SPACE_HEAP_VA
    call term_print_hex
    mov esi, msg_layout_plus
    call term_print
    mov eax, SPACE_HEAP_PAGES
    call term_print_dec
    mov al, 'p'
    call term_putc
    mov al, 10
    call term_putc

    mov esi, msg_layout4
    call term_print
    mov eax, SPACE_TRAMP_VA
    call term_print_hex
    mov esi, msg_layout_tramp
    call term_print
    mov eax, SPACE_ARGS_VA
    call term_print_hex
    mov esi, msg_layout_args
    call term_print
    mov eax, SPACE_USER_STACK_TOP
    call term_print_hex
    mov al, 10
    call term_putc

    ; ---- 调度器:线程表清干净,0 号登记成"现在这个上下文"(shell 自己)----
    ; 轮转不在这儿开:开机流程本身也被 IRQ0 打着,现在就换人会把启动信息打得
    ; 七零八落。真正开是 shell 起来之前那一句 sched_enable。
    call sched_init
    mov esi, msg_sched                   ; 一行说完:调度器 + 4 条 shell(见 6.16)
    call term_print

    ; (帧缓冲终端在开头已经初始化过 —— 它自带清屏,调两次会把前面的输出擦掉)

    ; ---- 报一下字库用了哪个 ----
    ; ---- 帧缓冲几何(排 QEMU / VirtualBox 差异:谁报的行距对不上一眼可见)----
    mov esi, msg_fbdump
    call term_print
    mov eax, [fb_phys]
    call term_print_hex
    mov esi, msg_fbw
    call term_print
    mov eax, [fb_width]
    call term_print_dec
    mov esi, msg_fbh
    call term_print
    mov eax, [fb_height]
    call term_print_dec
    mov esi, msg_fbp
    call term_print
    mov eax, [fb_pitch]
    call term_print_dec
    mov esi, msg_fbb
    call term_print
    mov eax, [fb_bpp]
    call term_print_dec
    mov esi, msg_fbmi16
    call term_print
    mov eax, [BOOTINFO + 80]
    call term_print_dec
    mov esi, msg_fbmi32
    call term_print
    mov eax, [BOOTINFO + 84]
    call term_print_dec
    mov esi, msg_fbvbe
    call term_print
    mov eax, [BOOTINFO + 76]
    call term_print_hex
    mov al, 10
    call term_putc

    mov esi, msg_font
    call term_print
    cmp dword [font_from_disk], 0
    je .font_builtin
    mov esi, msg_font_disk
    call term_print
    jmp .font_done
.font_builtin:
    mov esi, msg_font_builtin
    call term_print
.font_done:
    mov eax, [font_glyphs]
    call term_print_dec
    mov esi, msg_font_glyphs
    call term_print

    ; ---- 文件系统 + 程序接口 ----
    call fat_mount
    call api_install
    cmp byte [fat_ok], 0
    je .fs_none_print
    cmp byte [fat_fat32], 0
    je .fs16
    mov esi, msg_fs32
    call term_print
    jmp .fs_done
.fs16:
    mov esi, msg_fs
    call term_print
    mov esi, msg_fs_ok
    call term_print
    jmp .fs_done
.fs_none_print:
    mov esi, msg_fs
    call term_print
    jmp .fs_none
.fs_none:
    mov esi, msg_fs_none
    call term_print
.fs_done:

    ; ---- 软盘版说明 ----
    ; 软盘镜像只有 boot + stub + kernel(没有 FAT 盘、没有字库盘、没有 RC.CONF),
    ; 所以这里明说一句:想要完整功能请用硬盘版。
    ; 判据是 BOOTINFO+72 的启动盘号(< 0x80 = 软盘)。
    cmp byte [BOOTINFO + 72], 0x80
    jae .not_floppy
    mov al, COL_HEADER
    call term_set_color
    mov esi, msg_floppy_edition
    call term_print
    mov al, COL_NORMAL
    call term_set_color
    mov esi, msg_floppy_bye
    call term_print                      ; 一句话告别:软盘这条线到此为止
.not_floppy:

    ; ---- 键盘 ----
    call kbd_init
    mov esi, msg_kbd
    call term_print

    ; ---- 定时器:通道 0 → 100 Hz 心跳 ----
    ; 必须排在 kbd_init 后面:PIC 的重映射是键盘那边做的,PIT 只是把 IRQ0 放行。
    call pit_init
    mov esi, msg_pit
    call term_print

    ; ---- 实时时钟(CMOS):读日期/时间,顺手报到屏幕上 ----
    ; 只读不写:这颗芯片会一直走到电池没电,我们不去改它
    call rtc_get
    call rtc_print_boot

    ; PCI:把机器上有什么设备点名一遍(IDE / USB 的地址也顺手记下来,
    ; 给以后的 USB 驱动用)
    call pci_scan

    ; USB:UHCI 控制器 + 端口枚举(失败只打一行,不停机;没有 USB 控制器时静默)
    call usb_init

    ; ---- rc.conf(磁盘根目录的 RC.CONF)+ 事件账本 ----
    ; 为啥是 rc.conf 而不是 systemd 的 unit:玩具 OS 要的是"一行一个 key=value",
    ; 用 shell 的 write 就能改,改完 rc reload 立刻生效。详见 kernel/rc.asm 文件头。
    mov eax, EV_BOOT                     ; 开机这件事本身也记一笔
    xor ebx, ebx
    call evt_log
    call rc_load                         ; 读 + 解析 + 报一行
    call ime_load                        ; 拼音输入法的字表(没有就安静地关掉)
    call rc_print_osname                 ; 显示名(默认 JoyOS,RC.CONF 的 osname 可改)
    call rc_print_bootmsg                ; 配置里写了的开机提示
    call shell_apply_rc_style            ; RC.CONF 里写了 style = moe 就换提示符
    call rc_autostart                    ; autostart=YES 就把启用的服务跑一遍
                                         ; (放在 sched_enable 之前:跑服务时还没别的东西抢 CPU)

    mov al, COL_OK
    call term_set_color
    mov esi, msg_ok
    call term_print

%ifdef SELFTEST_FAULT
    ; ---- 故意除零,验证异常处理真的生效 ----
    ; 只有 make div / make test-div 时才会编进去(-DSELFTEST_FAULT=1)
    mov eax, 1
    xor edx, edx
    xor ecx, ecx
    div ecx                              ; 除零 → 0 号异常
%endif


    ; ---- 开调度:从这句起 shell 会被 IRQ0 定期打断,时间片轮转开始 ----
    call shell_spawn_extra               ; 再起 3 条 shell(0 号就是主线程)
    call sched_enable

    jmp shell_main                       ; 进 shell(不返回)

.hang:
    hlt
    jmp .hang

; ============================================================================
;  终端驱动:在 VGA 文本缓冲上做一个会滚屏的光标终端
;
;  为什么不用"按行打印"那套:shell 要连续输出几十行,写满 25 行必须滚屏,
;  所以这里做成"一个光标 + 一个字符一个字符地吐",和真终端一个道理。
; ============================================================================

; 清屏:整屏填空格(0x0720 = 浅灰空格),光标回左上角
term_init:
    mov byte [term_row], 0
    mov byte [term_col], 0
    mov byte [term_color], COL_NORMAL
    ; 落到 term_clear
term_clear:
    cmp dword [vbe_ok], 0
    jne fb_clear
    push eax
    push ecx
    push edi
    mov edi, VGA_MEM
    mov eax, 0x0720                      ; 空格 + 浅灰
    mov ecx, VGA_COLS * VGA_ROWS / 2      ; 每双字两格
    rep stosd
    mov byte [term_row], 0
    mov byte [term_col], 0
    call term_move_hw_cursor
    pop edi
    pop ecx
    pop eax
    ret

; al = 颜色属性(文本模式直接存;图形模式还要换算成 RGB)
term_set_color:
    mov [term_color], al
    push eax
    call fb_color_of
    mov [term_fb_color], eax
    pop eax
    ret

; al = 字符(支持 \n \r \b)
term_putc:
    cmp dword [vbe_ok], 0
    jne fb_putc                         ; 图形模式:走帧缓冲终端
    push eax
    push ebx
    push edi
    cmp al, 10
    je .newline
    cmp al, 13
    je .cr
    cmp al, 8
    je .bs

    call term_addr                        ; edi = 当前光标处的显存地址
    mov [edi], al
    mov bl, [term_color]
    mov [edi + 1], bl
    inc byte [term_col]
    cmp byte [term_col], VGA_COLS
    jb .done
    call term_newline
    jmp .done

.newline:
    call term_newline
    jmp .done
.cr:
    mov byte [term_col], 0
    jmp .done
.bs:
    cmp byte [term_col], 0
    je .done
    dec byte [term_col]
    call term_addr                        ; 在退掉的那格上写空格
    mov byte [edi], ' '
    mov bl, [term_color]
    mov [edi + 1], bl
.done:
    call term_move_hw_cursor
    pop edi
    pop ebx
    pop eax
    ret

; edi = 光标处的显存地址 = VGA_MEM + 行×160 + 列×2
term_addr:
    push eax
    push ebx
    movzx edi, byte [term_row]
    imul edi, VGA_COLS * 2
    movzx ebx, byte [term_col]
    shl ebx, 1
    add edi, ebx
    add edi, VGA_MEM
    pop ebx
    pop eax
    ret

term_newline:
    mov byte [term_col], 0
    inc byte [term_row]
    cmp byte [term_row], VGA_ROWS
    jb .done
    dec byte [term_row]                   ; 停在最后一行,整屏往上滚
    call term_scroll
.done:
    ret

; 滚屏:第 1~24 行搬到第 0~23 行,最后一行清空
term_scroll:
    push eax
    push ecx
    push esi
    push edi
    mov esi, VGA_MEM + VGA_COLS * 2
    mov edi, VGA_MEM
    mov ecx, VGA_COLS * 2 * (VGA_ROWS - 1) / 4
    rep movsd
    mov edi, VGA_MEM + VGA_COLS * 2 * (VGA_ROWS - 1)
    mov eax, 0x0720
    mov ecx, VGA_COLS / 2
    rep stosd
    pop edi
    pop esi
    pop ecx
    pop eax
    ret

; 把光标位置告诉 VGA 硬件(不然屏幕上不会有那个闪的方块)
term_move_hw_cursor:
    cmp dword [vbe_ok], 0
    jne .skip                           ; 图形模式没有硬件字符光标
    push eax
    push ebx
    push edx
    movzx eax, byte [term_row]
    imul eax, VGA_COLS
    movzx ebx, byte [term_col]
    add eax, ebx                          ; 位置 = 行×80 + 列
    mov ebx, eax
    mov dx, 0x3D4                         ; CRT 索引口
    mov al, 0x0F                          ; 光标位置低 8 位
    out dx, al
    inc dx                                ; 0x3D5 = 数据口
    mov al, bl
    out dx, al
    dec dx
    mov al, 0x0E                          ; 光标位置高 8 位
    out dx, al
    inc dx
    mov al, bh
    out dx, al
    pop edx
    pop ebx
    pop eax
.skip:
    ret

; ============================================================================
;  全屏程序要用的三个终端功能(编辑器那种"画面由我控制"的程序)
;
;  普通程序用 term_print 一行行往下吐就行,但编辑器要**在屏幕任意位置写字**、
;  要**知道屏幕多大**、还要**不滚屏**(滚屏会把刚画好的界面顶掉)。
;  所以这里给三个:定位光标、问屏幕大小、在指定位置画一串字。
; ============================================================================

; ---------------------------------------------------------------------------
;  term_size:→ eax = 每行几个字符格,ebx = 几行
;  字符格 = 8 像素宽、16 像素高(VGA 文本模式固定 80×25)
; ---------------------------------------------------------------------------
term_size:
    cmp dword [vbe_ok], 0
    jne .fb
    mov eax, VGA_COLS
    mov ebx, VGA_ROWS
    ret
.fb:
    mov eax, [fb_width]
    shr eax, 3                          ; 像素宽 ÷ 8
    mov ebx, [fb_height]
    shr ebx, 4                          ; 像素高 ÷ 16
    ret

; ---------------------------------------------------------------------------
;  term_set_cursor:ebx = 行,ecx = 列(超出屏幕就夹到边界内)
; ---------------------------------------------------------------------------
term_set_cursor:
    push eax
    push ebx
    push ecx
    cmp dword [vbe_ok], 0
    jne .fb

    ; ---- 文本模式:行/列各自夹住 ----
    cmp ebx, VGA_ROWS
    jb .row_ok
    mov ebx, VGA_ROWS - 1
.row_ok:
    cmp ecx, VGA_COLS
    jb .col_ok
    mov ecx, VGA_COLS - 1
.col_ok:
    mov [term_row], bl
    mov [term_col], cl
    call term_move_hw_cursor
    jmp .done

.fb:
    ; ---- 图形模式:光标是像素坐标(fb_cur_x / fb_cur_y)----
    call term_size                      ; eax = 列数,ebx = 行数
    cmp ecx, eax
    jb .fcol_ok
    lea ecx, [eax - 1]
.fcol_ok:
    mov eax, [fb_height]
    shr eax, 4
    cmp ebx, eax
    jb .frow_ok
    lea ebx, [eax - 1]
.frow_ok:
    shl ecx, 3                          ; 列 × 8 像素
    shl ebx, 4                          ; 行 × 16 像素
    mov [fb_cur_x], ecx
    mov [fb_cur_y], ebx
.done:
    pop ecx
    pop ebx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  term_puts_at:在指定位置画一串 UTF-8 字,**不滚屏、不动全局光标**
;      esi = 字符串   ebx = 行   ecx = 列   edx = 这一行最多占几个字符格
;      → eax = 实际占了几格
;  编辑器靠它重画一行:先定位,再整行写过去。写到 edx 就不写了(免得顶到
;  屏幕最后一格触发换行 → 滚屏,把界面顶掉)。
;  文本模式下只画 ASCII(8 像素的格子塞不下汉字),非 ASCII 画成 '?'。
; ---------------------------------------------------------------------------
term_puts_at:
    pushad
    mov [tpa_row], ebx
    mov [tpa_col], ecx
    mov [tpa_start], ecx
    mov [tpa_max], edx
.next:
    call utf8_decode                    ; eax = 码位(0 = 到头),esi 前进
    test eax, eax
    jz .done
    cmp eax, 10                         ; 换行:这一行画到这儿就够了
    je .done
    cmp eax, 13
    je .done
    cmp eax, 0x20
    jb .next                            ; 其它控制字符不画
    cmp dword [vbe_ok], 0
    je .text

    ; ---- 图形模式:先问字形多宽,放不下就停(不画半个字)----
    mov [tpa_cp], eax
    call fb_glyph                       ; eax = 点阵, ecx = 宽(像素)
    test eax, eax
    jnz .have_w
    mov ecx, 8                          ; 字库没这个字:按 8 像素(方框)算
.have_w:
    shr ecx, 3                          ; 像素 → 格
    mov eax, [tpa_col]
    add eax, ecx
    cmp eax, [tpa_max]
    ja .done
    mov eax, [tpa_cp]
    mov ebx, [tpa_row]
    mov ecx, [tpa_col]
    call fb_putcp_at                    ; → [pa_cells] = 占几格
    mov eax, [pa_cells]
    add [tpa_col], eax
    jmp .check

.text:
    cmp eax, 0x80
    jb .ascii
    mov eax, '?'                        ; 文本模式画不了汉字,给个记号
.ascii:
    mov edx, [tpa_row]
    imul edx, VGA_COLS                  ; 行 × 80
    add edx, [tpa_col]
    shl edx, 1                          ; 每格 2 字节
    add edx, VGA_MEM
    mov [edx], al
    mov al, [term_color]
    mov [edx + 1], al
    inc dword [tpa_col]

.check:
    mov eax, [tpa_col]
    cmp eax, [tpa_max]
    jb .next
.done:
    mov eax, [tpa_col]
    sub eax, [tpa_start]
    mov [tpa_written], eax
    popad
    mov eax, [tpa_written]
    ret

; esi = 以 0 结尾的 **UTF-8** 字符串
; (以前是逐字节 lodsb,现在先解码成码位再画 —— 这样中英都走一条路,而且跟外界一致)
term_print:
    push eax
    push esi
.next:
    call utf8_decode                    ; eax = 码位(0 = 到头了),esi 前进
    test eax, eax
    jz .done
    call term_print_cp
    jmp .next
.done:
    pop esi
    pop eax
    ret

; eax = 数值 → 打 8 位十六进制,带 0x 前缀
term_print_hex:
    push eax
    push ebx
    push ecx
    mov ebx, eax
    mov al, '0'
    call term_putc
    mov al, 'x'
    call term_putc
    mov ecx, 8
.loop:
    mov eax, ebx
    push ecx
    sub ecx, 1
    shl ecx, 2
    shr eax, cl
    pop ecx
    and eax, 0x0F
    cmp al, 10
    jb .digit
    add al, 'A' - 10
    jmp .emit
.digit:
    add al, '0'
.emit:
    call term_putc
    sub ecx, 1
    jnz .loop
    pop ecx
    pop ebx
    pop eax
    ret

; eax = 数值 → 打十进制(无符号,不补零)
term_print_dec:
    push eax
    push ebx
    push ecx
    push edx
    mov ebx, 10
    xor ecx, ecx
.divide:
    xor edx, edx
    div ebx
    push edx                              ; 余数入栈 → 出栈自然逆序
    inc ecx
    test eax, eax
    jnz .divide
.emit:
    pop eax
    add al, '0'
    call term_putc
    sub ecx, 1
    jnz .emit
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; 打印 AL 的两位十六进制(不带前缀)
term_print_byte:
    push eax
    push ebx
    mov ebx, eax
    shr al, 4
    call .nib
    mov eax, ebx
    call .nib
    pop ebx
    pop eax
    ret
.nib:
    and al, 0x0F
    cmp al, 10
    jb .dig
    add al, 'A' - 10
    jmp .out
.dig:
    add al, '0'
.out:
    call term_putc
    ret

; ============================================================================
;  数据
; ============================================================================
; 第一行刻意不写系统名:名字可能被 RC.CONF 的 osname 改掉,而这一行
; 打在任何配置被读之前;真正的显示名由 rc_print_osname 在 rc_load 之后打。
msg_title   db 'boot: Operation System', 10, 0
msg_chain   db 'bootloader -> protected mode -> kernel', 10, 0
msg_fbdump  db 'fb: phys=', 0
; ---- 运行时内存布局(启动时由 BOOTINFO + paging/pmem 协商出来,见上面计算段)----
ram_top     dd 0                       ; 可用 RAM 顶端(字节)
ident_limit dd 0                       ; 恒等映射上限(4 MiB 对齐,≤ 16 MiB)
e820_entries dd 0                      ; E820 条目数(0 = 兜底算法探的)
pmem_start  dd 0                       ; 页池起点
pmem_end    dd 0                       ; 页池终点
pmem_total  dd 0                       ; 页池总页数
pmem_pages  dd 0                       ; (同 pmem_total,给 shell 用)
pmem_words  dd 0                       ; 位图需要多少个 dword
msg_fbw     db ' w=', 0
msg_fbh     db ' h=', 0
msg_fbp     db ' pitch=', 0
msg_fbb     db ' bpp=', 0
msg_fbmi16  db '  modeinfo: bytesPerScanLine=', 0
msg_fbmi32  db ' linBytesPerScanLine=', 0
msg_fbvbe   db ' vbe=0x', 0
msg_utf8_tag db 'utf8  : ', 0
msg_sectors db 'kernel area: ', 0
msg_equals  db ' sectors = ', 0
msg_bytes   db ' bytes loaded from disk', 10, 0
msg_kmain   db 'kmain at ', 0
msg_pm      db '  (32-bit protected mode)', 10, 0
msg_seg     db 'DS = ', 0
msg_seg2    db '  (0x10 = our GDT data segment)', 10, 0
msg_disk    db 'boot disk: ', 0
msg_disk_lba db 'LBA (EDD multi-sector read)', 10, 0
msg_disk_chs db 'CHS fallback (BIOS has no LBA)', 10, 0
msg_idt     db 'IDT: 256 vectors installed (errors 0-31 have handlers)', 10, 0
msg_ring3   db 'ring 3: user segments + TSS ready (programs run at CPL=3)', 10, 0
msg_fpu_ok  db 'fpu: x87 initialized (CR0.NE=1, #MF handler ready)', 10, 0
msg_fpu_none db 'fpu: no x87 detected (floating point unavailable)', 10, 0
msg_paging  db 'paging: CR0.PG=1, identity-mapped 0-', 0
msg_paging2 db ' MiB (+ VBE LFB high window)', 10, 0
msg_pmem    db 'pmem: page pool 0x', 0
msg_layout_dash db '-0x', 0
msg_layout_comma db ', ', 0
msg_pmem2   db ' pages (4 KiB each) + dynamic page tables (try: debug pmem / debug ptest)', 10, 0
msg_layout1 db 'layout: ram=', 0
msg_layout1b db 'M e820=', 0
msg_layout1c db ' ident=', 0
msg_layout_mib db 'M', 10, 0
msg_layout2 db 'layout: pool=0x', 0
msg_layout2b db ' pages=', 0
msg_layout3 db 'layout: img=0x', 0
msg_layout_plus db '+', 0
msg_layout_p db 'p heap=0x', 0
msg_layout4 db 'layout: tramp=0x', 0
msg_layout_tramp db ' args=0x', 0
msg_layout_args db ' stack=', 0
msg_kbd     db 'keyboard: PIC remapped to 0x20, IRQ1 enabled', 10, 0
msg_pit     db 'timer: PIT channel 0 at 100 Hz (IRQ0 0x20; try: uptime / sleep)', 10, 0
msg_sched   db 'sched: round-robin threads, 20 ms slice, 4 shells (Ctrl+Left / Ctrl+Right)', 10, 0
msg_font    db 'font: ', 0
msg_font_disk    db 'loaded from disk (ATA), ', 0
msg_font_builtin db 'built-in subset, ', 0
msg_font_glyphs  db ' glyphs', 10, 0
msg_fs      db 'fat16: ', 0
msg_fs_ok   db 'mounted at LBA 6144 (ls / cat / write / run)', 10, 0
msg_fs_none db 'not available (floppy boot?)', 10, 0
msg_floppy_edition db 'floppy edition: minimal - use the hard disk image for the full system', 10, 0
msg_floppy_bye db 'Goodbye Floppy disk', 10, 0
msg_fs32    db 'fat32: mounted at LBA 6144 (BPB 里的 f16 扇区数 = 0 → 32 位 FAT,根目录是簇链)', 10, 0
msg_ok      db 'OK - stage 5: boot + protection + IDT + paging + keyboard + shell.', 10, 0

vbe_ok       dd 0
fb_phys      dd 0
fb_width     dd 0
fb_height    dd 0
fb_pitch     dd 0
fb_bpp       dd 0

boot_sectors dd 0
boot_lba     dd 0
boot_mode    dd 0

term_row     db 0
term_col     db 0
term_color   db COL_NORMAL

; 全屏 API(term_puts_at / term_set_cursor)用的临时变量
tpa_row      dd 0
tpa_col      dd 0
tpa_start    dd 0
tpa_max      dd 0
tpa_cp       dd 0
tpa_written  dd 0

; 函数里用到的小工具:把当前执行地址(kmain 的偏移)打出来
term_print_addr:
    push eax
    mov eax, kmain
    call term_print_hex
    pop eax
    ret

