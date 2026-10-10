; ============================================================================
;  JoyOS (胡闹OS) — 分页(页目录 + 页表)
;
;  ── 分页在干嘛 ──────────────────────────────────────────────────────────
;  开分页之前,线性地址就是物理地址。开了 CR0.PG 之后,CPU 把线性地址
;  按 两级页表 翻译成物理地址:
;
;      线性地址 = [ 页目录索引(10 位) | 页表索引(10 位) | 页内偏移(12 位) ]
;                    ↓ 查 CR3 指向的页目录(4 KiB,1024 项 × 4 字节)
;                    ↓ 查出页表基址,再查页表(4 KiB,1024 项)
;                    ↓ 查出**物理页**基址,加上偏移
;
;  每个表项 4 字节:高 20 位 = 物理页基址(所以页必须 4 KiB 对齐),
;  低 12 位是标志位。这里只用两个:
;      bit0 P   present   1 = 这页存在,0 = 不存在(访问就触发 14 号页错误)
;      bit1 R/W writable  1 = 可写,0 = 只读
;  所以 "物理页 | 0x3" = 存在且可写。
;
;  一个页表管 4 MiB(1024 项 × 4 KiB),一个页目录管 4 GiB。
;
;  ── 这个阶段的布局 ──────────────────────────────────────────────────────
;  1. 恒等映射(线性 = 物理)前 16 MiB —— 内核、VGA(0xB8000)、IDT、栈、各种缓冲、
;     字库,还有 4 MiB 以上的**页池**都在里面,所以指针可以直接当物理地址用,
;     写代码完全不用想 MMU(这就是"平铺的手感")
;  2. VBE 线性帧缓冲通常在 0xFD000000 这种高地址,单独挂一张页表映射进来
;     (不映射的话第一次往屏幕写像素就吃 14 号页错误)
;  3. paging_map / paging_unmap 是**动态建表**:页表不存在就从页池里拿一页现建,
;     映射完还能解掉、把页还回页池 —— shell 里的 pmap / pumap / ptest 玩的就是它
;
;  开分页之前必须先把要用的表都填好,开之后下一条指令就得在映射范围内 —— 顺序不能错。
;
;  表放哪儿:页目录 0x1000,四张恒等页表 0x2000/0x3000/0x5000/0x7000,
;  帧缓冲页表 0x4000;0x6000 留给 pmem.asm 的页池位图。
;  这些还是硬编码的(开机太早,页池还没起来),运行期新建的页表才走页池。
; ============================================================================

PD_ADDR     equ 0x1000                 ; 页目录(4 KiB)
PT_LOW      equ 0x2000                 ; 页表:恒等 0x000000-0x3FFFFF
PT_ID1      equ 0x3000                 ; 页表:恒等 0x400000-0x7FFFFF
PT_LFB      equ 0x4000                 ; 页表:给 VBE 线性帧缓冲用
PT_ID2      equ 0x5000                 ; 页表:恒等 0x800000-0xBFFFFF
PT_ID3      equ 0x7000                 ; 页表:恒等 0xC00000-0xFFFFFF

PAGE_P      equ 1                      ; bit0 present
PAGE_RW     equ 2                      ; bit1 writable
PAGE_USER   equ 4                      ; bit2 ring 3 也能碰(U/S)。内核页故意不设这一位

; 注意:帧缓冲地址用 kmain.asm 里的 fb_phys 变量(内核启动时从 BOOTINFO 抄过来的)

; 把一张页表填满:恒等映射从 %2 开始的 4 MiB
%macro IDENT_PT 2
    mov edi, %1
    mov eax, %2
    or  eax, PAGE_P | PAGE_RW
    mov ecx, 1024
%%loop:
    mov [edi], eax
    add edi, 4
    add eax, 4096                      ; 下一页
    dec ecx
    jnz %%loop
%endmacro

; ---------------------------------------------------------------------------
;  paging_init:建表 → 开分页
; ---------------------------------------------------------------------------
paging_init:
    pushad

    ; ---- 1) 清页目录(1024 项全得是 0;页表下面整张填满,不用先清)----
    mov edi, PD_ADDR
    xor eax, eax
    mov ecx, 1024
    rep stosd

    ; ---- 2) 页目录前 4 项各挂一张恒等页表(0-4 / 4-8 / 8-12 / 12-16 MiB)----
    mov eax, PT_LOW | PAGE_P | PAGE_RW
    mov [PD_ADDR + 0 * 4], eax         ; 管 0x00000000-0x003FFFFF
    mov eax, PT_ID1 | PAGE_P | PAGE_RW
    mov [PD_ADDR + 1 * 4], eax         ; 管 0x00400000-0x007FFFFF
    mov eax, PT_ID2 | PAGE_P | PAGE_RW
    mov [PD_ADDR + 2 * 4], eax         ; 管 0x00800000-0x00BFFFFF
    mov eax, PT_ID3 | PAGE_P | PAGE_RW
    mov [PD_ADDR + 3 * 4], eax         ; 管 0x00C00000-0x00FFFFFF

    ; ---- 3) 四张表都填成恒等映射 ----
    IDENT_PT PT_LOW, 0x000000
    IDENT_PT PT_ID1, 0x400000
    IDENT_PT PT_ID2, 0x800000
    IDENT_PT PT_ID3, 0xC00000

    ; ---- 4) 把 VBE 线性帧缓冲也映射进来 ----
    ; 做法:按 4 MiB 对齐算出页目录索引,给它挂一张新页表,里面 1024 项都指向那 4 MiB。
    cmp dword [fb_phys], 0             ; stub 没拿到图形模式就跳过
    je .no_lfb
    mov eax, [fb_phys]
    shr eax, 22                        ; 页目录索引(4 MiB 为单位)
    mov [lfb_pde_idx], eax
    shl eax, 22                        ; 对齐到 4 MiB 的基址
    mov [lfb_base], eax

    mov edi, PT_LFB
    mov eax, [lfb_base]
    or  eax, PAGE_P | PAGE_RW
    mov ecx, 1024
.fill_lfb:
    mov [edi], eax
    add edi, 4
    add eax, 4096
    dec ecx
    jnz .fill_lfb

    mov eax, PT_LFB
    or  eax, PAGE_P | PAGE_RW
    mov edi, [lfb_pde_idx]
    mov [PD_ADDR + edi * 4], eax

.no_lfb:

    ; ---- 5) CR3 ← 页目录物理地址,然后开 CR0.PG ----
    mov eax, PD_ADDR
    mov cr3, eax
    mov eax, cr0
    or  eax, 0x80000000                ; CR0.PG = 1
    mov cr0, eax

    popad
    ret

; ---------------------------------------------------------------------------
;  paging_map:把虚拟地址 eax 映射到物理地址 ebx(都要 4 KiB 对齐),ecx = 标志
;  页表不存在就找页池要一页现建(这就是动态建表)。CF=1 = 失败(页池空了)
;  破坏 eax/ebx/ecx/edx/edi(调用方不用指望它们)
; ---------------------------------------------------------------------------
paging_map:
    pushad
    mov [map_va], eax
    mov [map_pa], ebx
    mov [map_flags], ecx

    mov edi, eax
    shr edi, 22
    and edi, 0x3FF                     ; 页目录项下标
    mov edx, [PD_ADDR + edi * 4]
    test edx, 1
    jnz .have_pt                       ; 已经有页表了,直接用

    ; ---- 没有页表:从页池拿一页,清零,挂进页目录 ----
    call pmem_alloc
    test eax, eax
    jz .fail                           ; 页池空了
    mov ebx, eax
    mov edi, eax                       ; 页池在恒等映射里,可以直接写
    xor eax, eax
    mov ecx, 1024
    rep stosd
    mov eax, ebx
    or  eax, PAGE_P | PAGE_RW
    mov edi, [map_va]
    shr edi, 22
    and edi, 0x3FF
    mov [PD_ADDR + edi * 4], eax
    mov edx, eax

.have_pt:
    and edx, 0xFFFFF000                ; 页表的物理地址
    mov edi, [map_va]
    shr edi, 12
    and edi, 0x3FF                     ; 页表项下标
    mov eax, [map_pa]
    and eax, 0xFFFFF000
    or  eax, [map_flags]
    mov [edx + edi * 4], eax
    mov eax, [map_va]
    invlpg [eax]                       ; 让 CPU 忘掉这个地址的旧翻译
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; ---------------------------------------------------------------------------
;  paging_unmap:解掉虚拟地址 eax 处的映射
;  返回 eax = 原来映到的物理地址(本来没映 = 0)
;  如果这张页表被解空了,连页表一起还给页池(PDE 也清掉)
; ---------------------------------------------------------------------------
paging_unmap:
    pushad
    mov [map_va], eax
    mov dword [map_pa], 0

    mov edi, eax
    shr edi, 22
    and edi, 0x3FF
    mov edx, [PD_ADDR + edi * 4]
    test edx, 1
    jz .done                           ; 连页表都没有
    and edx, 0xFFFFF000
    mov edi, [map_va]
    shr edi, 12
    and edi, 0x3FF
    mov eax, [edx + edi * 4]
    mov [map_pa], eax                  ; 记下旧 PTE(当返回值)
    test eax, 1
    jz .done                           ; 本来就没映
    mov dword [edx + edi * 4], 0
    mov eax, [map_va]
    invlpg [eax]

    ; ---- 这张页表还有别的映射吗?没有就整张还回去 ----
    xor ecx, ecx
.scan:
    cmp dword [edx + ecx * 4], 0
    jne .done                          ; 还有别的项,页表留着
    inc ecx
    cmp ecx, 1024
    jb .scan

    mov eax, [map_va]
    shr eax, 22
    and eax, 0x3FF
    mov dword [PD_ADDR + eax * 4], 0   ; PDE 清掉
    mov eax, [map_va]
    invlpg [eax]
    mov eax, edx
    call pmem_free                     ; 页表页还给页池(不是池里的会被拒,无所谓)

.done:
    mov eax, [map_pa]
    and eax, 0xFFFFF000
    mov [map_pa], eax
    popad
    mov eax, [map_pa]                  ; popad 会把 eax 冲掉,所以从内存里取
    ret

; ---------------------------------------------------------------------------
;  paging_translate:eax = 虚拟地址 → eax = 物理地址。CF=1 = 没映射
; ---------------------------------------------------------------------------
paging_translate:
    push ebx
    push edi
    mov edi, eax
    shr edi, 22
    and edi, 0x3FF
    mov ebx, [PD_ADDR + edi * 4]
    test ebx, 1
    jz .no
    and ebx, 0xFFFFF000
    mov edi, eax
    shr edi, 12
    and edi, 0x3FF
    mov ebx, [ebx + edi * 4]
    test ebx, 1
    jz .no
    and ebx, 0xFFFFF000
    and eax, 0xFFF                     ; 页内偏移
    add eax, ebx
    pop edi
    pop ebx
    clc
    ret
.no:
    xor eax, eax
    pop edi
    pop ebx
    stc
    ret

; ===========================================================================
;  ── 程序地址空间:每个程序一套页目录 + 按需分页 ──────────────────────────
;  第一步(全分页)已经做完:每个程序跑之前先给它建一套**自己的页目录**:
;
;        页目录   = 内核页目录的副本(内核、VGA、IDT、栈、帧缓冲都还在)
;        页表[0]  = PT_LOW 的副本,但两个窗口的项被清成"不存在"
;
;  第二步就是**按需分页**(demand paging):程序拿到的是 208 页的地址窗口,
;  但建表的时候**一页物理内存都不给**。程序第一次碰某页 → CPU 报 14 号页错误
;  → page_fault_try_handle 判断这个地址属于哪个窗口、从页池现拿一页、
;  把内容准备好(镜像页:从暂存区拷;堆/`.bss` 页:留 0)→ 填进页表 → iret
;  回去把那条指令**重执行一遍**,这次就通了。程序完全不知道发生过什么。
;
;     程序视角:                         物理内存:
;       0x120000 ┌──────────────┐          程序碰过的页才真的存在,
;                │  镜像 128 页  │          HELLO.BIN 这种小程序只拿走 1 页,
;       0x1A0000 ├──────────────┤          而不是像以前那样一上来就占 208 页。
;                │   堆 80 页    │
;       0x1F0000 └──────────────┘
;
;  好处:① 小程序不再白占 832 KiB;② `.bss`(文件之外的页)天然是零页;
;        ③ 一个程序能吃的上限是 208 页,越出窗口就是真错误(panic)。
;  还没做:页面换出/置换(没有 swap、没有"页用完了挑一页扔掉")、写时复制、
;         精确的越界检测(窗口内的空洞也会给页)。这几样都不打算做 —— 玩具够了。
;
;  内核窗口继续恒等映射 —— 所以 int 0x30 那些内核函数照旧能用,**不需要 ring 3**;
;  程序传给内核的指针也照旧解得开(那会儿用的就是程序这套页表)。
; ===========================================================================
SPACE_IMG_VA     equ 0x120000          ; 程序镜像窗口(shell.asm 的 PROG_ADDR)
SPACE_IMG_PAGES  equ 0x80              ; 512 KiB(0x120000-0x19FFFF,见 include/joyos.h)
SPACE_HEAP_VA    equ 0x1A0000          ; 堆窗口(JOY_HEAP_START)
SPACE_HEAP_PAGES equ 0x50              ; 320 KiB(0x1A0000-0x1EFFFF)
; ---- ring 3 专用的两块页(都在窗口的最后一页,程序照样能用前面的部分)----
SPACE_TRAMP_VA   equ SPACE_IMG_VA + (SPACE_IMG_PAGES - 1) * 4096   ; 0x19F000 弹床
SPACE_STACK_VA   equ SPACE_HEAP_VA + (SPACE_HEAP_PAGES - 1) * 4096 ; 0x1EF000 用户栈
SPACE_USER_STACK_TOP equ SPACE_STACK_VA + 4092                      ; 0x1EFFFC

; 参数页:ring 3 程序读不到内核里的参数缓冲区(PROG_ARG_ADDR 在 0x11F000,
; 那是"supervisor only"的页),所以装载器把 4 字节魔数 + 参数字符串
; 整个拷进程序自己空间的这一页,API 12 返回的是这儿的地址。
SPACE_ARGS_VA    equ SPACE_HEAP_VA + (SPACE_HEAP_PAGES - 2) * 4096 ; 0x1EE000 参数页
SPACE_ARGS_COPY  equ (4 + 2048 + 3) / 4                            ; 拷贝长度(dword 数)
; ★ 栈顶那 4 字节(0x1EFFFC)就是 space_prepare_user 写进去的弹床地址:
;   程序 `ret` 时 [esp] 正是这里。**别**把 ESP 设成 0x1F0000(窗口外、内核临时缓冲):
;   程序第一次 ret 就会撞上"内核的页",错误码 bit0=1 —— 这个坑踩过一次。
; 两个窗口在 0x120000-0x1EFFFF 里是**连着**的(128 + 80 = 208 页),
; 所以在私有页表里清/扫这两个窗口用一段连续下标就够:
;   下标 = 0x120000>>12 = 288 起,共 208 项 → 0x120000-0x1EFFFF
;   后面 0x1F0000 是内核自己的临时缓冲,不能碰

; ---------------------------------------------------------------------------
;  space_create:建一套程序地址空间 —— 只给页目录 + 页表两页,窗口页一页不给
;  返回 eax = 页目录物理地址(0 = 页池不够);另外填好 space_pd / space_pt
; ---------------------------------------------------------------------------
space_create:
    pushad
    mov dword [space_pd], 0
    mov dword [space_pt], 0
    mov dword [space_pages], 0
    mov dword [space_live], 0
    ; ★ space_img_bytes 这里**不能清**:它是"这次要跑的镜像是多大"的输入参数,
    ;   由 space_set_image 填好 —— 之前在这里清成 0,结果整个镜像窗口都被当成
    ;   `.bss` 填零页,程序拿到的是一页页的 0 字节(执行起来一路乱跳到野地址)。
    mov dword [space_pf_run], 0
    mov dword [space_pf_img], 0
    mov dword [space_pf_heap], 0
    mov dword [space_first_pa], 0

    ; ---- 1) 页目录:从页池拿一页,把内核页目录整份拷过来 ----
    call pmem_alloc
    test eax, eax
    jz .fail
    mov [space_pd], eax
    mov edi, eax
    mov esi, PD_ADDR
    mov ecx, 1024
    rep movsd

    ; ---- 2) 私有页表:拷 PT_LOW(0-4 MiB 的映射),挂到页目录[0] ----
    call pmem_alloc
    test eax, eax
    jz .fail
    mov [space_pt], eax
    mov edi, eax
    mov esi, PT_LOW
    mov ecx, 1024
    rep movsd
    mov eax, [space_pt]
    or  eax, PAGE_P | PAGE_RW | PAGE_USER
    ; ★ 这一级也必须带 U/S —— 页表是"逐级查权限"的:PD 项说"用户不许",
    ;   下面页表项写得再漂亮,ring 3 一访问还是保护违规(#PF,错误码 bit0=1)。
    ;   这里踩过:程序第一条指令就挂在 0x120000,错误码 bit0=1 而不是"没有页"。
    mov edi, [space_pd]
    mov [edi], eax

    ; ---- 3) 两个窗口的项清成"不存在" —— 这一行就是按需分页的起点 ----
    ; PT_LOW 是恒等映射的,那两个窗口的项本来也"存在"(指向内核视角的物理页)。
    ; 不抹掉的话程序一访问就拿到内核的物理页,私有页就白搭了。
    mov edi, [space_pt]
    mov eax, SPACE_IMG_VA
    shr eax, 12
    and eax, 0x3FF                     ; 窗口第一页在页表里的下标(288)
    lea edi, [edi + eax * 4]
    mov ecx, SPACE_IMG_PAGES + SPACE_HEAP_PAGES   ; 208 项(窗口是连着的)
    xor eax, eax
    rep stosd

    ; ---- 4) 记账:固定只占页目录 + 页表两页 ----
    mov dword [space_pages], 2
    popad
    mov eax, [space_pd]
    clc
    ret
.fail:
    call space_destroy                 ; 半路失败也要把已经拿到的页还回去
    popad
    xor eax, eax
    stc
    ret

; ---------------------------------------------------------------------------
;  space_set_image:告诉分页层"这次要跑的镜像有多少字节"
;  页错误处理拿它判断:偏移 < 文件长度 → 从暂存区拷;否则留零(`.bss`)。
;  习惯上的顺序是 space_create 先、这个后(create 不碰这个输入);
;  反过来写也能用,但别在中间插一个会清 space_img_bytes 的调用。
; ---------------------------------------------------------------------------
space_set_image:
    mov [space_img_bytes], eax
    mov dword [space_pf_run], 0
    mov dword [space_pf_img], 0
    mov dword [space_pf_heap], 0
    mov dword [space_first_pa], 0
    ret

; ---------------------------------------------------------------------------
;  space_activate / space_deactivate:切到程序页目录 / 切回内核页目录
;
;  切换和 space_live 开关必须成对:开着的时候 14 号页错误才会走按需分页,
;  关着(或没有程序在跑)时页错误 = 真错误,照旧 panic。
; ---------------------------------------------------------------------------
space_activate:
    push eax
    mov dword [space_live], 1          ; 先开开关,再换 CR3
    mov eax, [space_pd]
    mov cr3, eax
    pop eax
    ret

space_deactivate:
    push eax
    mov dword [space_live], 0          ; 先关开关,再换回内核页目录
    mov eax, PD_ADDR
    mov cr3, eax
    pop eax
    ret

; ---------------------------------------------------------------------------
;  page_fault_try_handle:14 号页错误的"按需分页"部分(被 idt.asm 的 isr_common 调)
;  返回 eax = 1 = 页已经补好了,iret 回去重试那条指令;0 = 不是能补的页错误
;         (真越界 / 没有程序在跑 / 页池空了)→ 交给 panic 打印
;
;  进来时:CR2 = 出错地址,CR3 = 程序的页目录,中断关着(用户寄存器在 isr_common 压好了)
;  这里只碰内核低地址(恒等映射,程序页目录里也有)+ 页池(4 MiB 以上,恒等)——
;  所以处理过程本身不会再缺页。
; ---------------------------------------------------------------------------
page_fault_try_handle:
    pushad
    mov dword [pf_ret], 0
    cmp dword [space_live], 0
    je .out                            ; 没有程序在跑:不关我事
    cmp dword [space_pt], 0
    je .out                            ; 页表都没有,别硬撑

    mov eax, cr2
    mov [pf_va], eax

    ; ---- 这个地址落在哪个窗口?(窗口外 = 真错误)----
    mov ebx, eax
    sub ebx, SPACE_IMG_VA
    cmp ebx, SPACE_IMG_PAGES * 4096
    jb .image
    mov ebx, eax
    sub ebx, SPACE_HEAP_VA
    cmp ebx, SPACE_HEAP_PAGES * 4096
    jb .heap
    jmp .out
.image:
    mov byte [pf_is_img], 1
    jmp .check_pte
.heap:
    mov byte [pf_is_img], 0

.check_pte:
    ; 这一项要是已经"存在",说明不是缺页(比如写只读页)→ 别乱补,交给 panic
    mov eax, [pf_va]
    shr eax, 12
    and eax, 0x3FF
    mov edi, [space_pt]
    mov eax, [edi + eax * 4]
    test eax, 1
    jnz .out

    ; ---- 从页池拿一页(pmem_alloc_pages 会轮转,所以同一个程序跑两次
    ;     拿到的物理页不一样 —— 一眼能看出虚拟地址 ≠ 物理地址)----
    mov ecx, 1
    call pmem_alloc_pages
    test eax, eax
    jz .oom
    mov [pf_new_pa], eax

    ; ---- 先把这页清零:堆页和 `.bss` 要的零页就是它 ----
    mov edi, eax
    xor eax, eax
    mov ecx, 1024
    rep stosd

    cmp byte [pf_is_img], 0
    je .install
    ; ---- 镜像页:文件里有的部分从暂存区拷过来 ----
    ; ★ 这里必须**按页对齐**算偏移:缺页的地址不一定在页开头
    ;   (ring 3 用 call 跳进函数,取指就直接落在页中间 0x121C10)。
    ;   以前程序从 0x120000 顺序往下跑,缺页总是发生在页边界上,
    ;   拿"出错地址"当拷贝起点也看不出问题 —— 一旦从页中间进代码,
    ;   整页就会错位,程序跑的就是别人家的字节(踩过:CHELLO.BIN 崩在 0x0)。
    mov eax, [pf_va]
    sub eax, SPACE_IMG_VA
    and eax, 0xFFFFF000
    mov [pf_off], eax
    cmp eax, [space_img_bytes]
    jae .install                       ; 文件之外 → 就是 `.bss`,留零
    mov edx, [space_img_bytes]
    sub edx, eax                       ; 这页还剩多少字节要拷
    cmp edx, 4096
    jbe .have_len
    mov edx, 4096                      ; 整页
.have_len:
    mov [pf_len], edx
    ; ★ 为什么这里要临时切回内核页目录:镜像暂存区就在 0x120000,和程序镜像
    ;   窗口**同一个虚拟地址** —— 在程序空间里它是"正在被填的这一页",看不到
    ;   文件。内核页目录里 0x120000 才是暂存区(恒等映射)。栈和这些变量都在
    ;   低地址恒等区,所以切来切去是安全的。
    mov eax, [space_pd]
    mov [pf_saved_cr3], eax
    mov eax, PD_ADDR
    mov cr3, eax
    mov esi, SPACE_IMG_VA              ; 内核视角里 0x120000 = shell 的暂存区(PROG_ADDR)
    add esi, [pf_off]
    mov edi, [pf_new_pa]
    mov ecx, [pf_len]
    add ecx, 3
    shr ecx, 2                         ; 字节 → dword(向上取整)
    rep movsd
    mov eax, [pf_saved_cr3]
    mov cr3, eax                       ; 切回程序空间

.install:
    ; ---- 把新页填进程序私有页表的对应项,并让 CPU 忘掉旧翻译 ----
    mov eax, [pf_va]
    shr eax, 12
    and eax, 0x3FF
    mov edi, [space_pt]
    mov edx, [pf_new_pa]
    or  edx, PAGE_P | PAGE_RW | PAGE_USER ; U/S=1:程序自己要用这些页(ring 3)
    mov [edi + eax * 4], edx
    mov eax, [pf_va]
    invlpg [eax]

    ; ---- 记账(给 run 的输出和测试用)----
    inc dword [space_pf_run]
    inc dword [space_pf_total]
    cmp byte [pf_is_img], 0
    je .count_heap
    inc dword [space_pf_img]
    jmp .first_page
.count_heap:
    inc dword [space_pf_heap]
.first_page:
    cmp dword [space_first_pa], 0
    jne .ok
    mov eax, [pf_new_pa]
    mov [space_first_pa], eax          ; 第一次补进来的是哪页(常是镜像第 0 页)
.ok:
    mov dword [pf_ret], 1
    popad
    mov eax, [pf_ret]
    ret

.oom:
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_pf_oom
    call term_print
    ; 掉到 .out 返回 0 → panic 屏还会打出错地址,方便对账
.out:
    popad
    mov eax, [pf_ret]
    ret

; ---------------------------------------------------------------------------
;  space_destroy:拆掉程序地址空间
;  只还"真正拿过"的页:扫私有页表,窗口里还挂着(存在)的项才是这一趟按需
;  分页给出去的页;再加上页目录 + 页表两页,一起还给页池。
;  (半路建失败时也能调:指针是 0 的步骤直接跳过)
;  返回 eax = 还回去的页数
; ---------------------------------------------------------------------------
space_destroy:
    pushad
    mov dword [sd_pages], 0
    mov dword [space_live], 0          ; 先把开关关掉,免得半路又触发按需分页

    ; ---- 窗口里已经补进来的私有页 ----
    mov edi, [space_pt]
    test edi, edi
    jz .no_scan
    mov ebx, SPACE_IMG_VA
    mov ecx, SPACE_IMG_PAGES
    call space_free_window
    mov ebx, SPACE_HEAP_VA
    mov ecx, SPACE_HEAP_PAGES
    call space_free_window
.no_scan:

    mov eax, [space_pt]
    test eax, eax
    jz .no_pt
    call pmem_free
    jc .no_pt
    inc dword [sd_pages]
.no_pt:
    mov eax, [space_pd]
    test eax, eax
    jz .out
    call pmem_free
    jc .out
    inc dword [sd_pages]
.out:
    mov dword [space_pd], 0
    mov dword [space_pt], 0
    mov dword [space_img_bytes], 0
    popad
    mov eax, [sd_pages]
    ret

; ---------------------------------------------------------------------------
;  内部小工具
; ---------------------------------------------------------------------------
; 把 [space_pt] 里从虚拟地址 ebx 起的 ecx 项中"存在的"页还给页池,并计数
; (存在的项 = 程序真的碰过、我们真给过的页;没碰过的项是 0,跳过)
space_free_window:
    push eax
    push ebx
    push ecx
    push edx
    push esi
.loop:
    mov eax, ebx
    shr eax, 12
    and eax, 0x3FF                     ; 页表项下标
    mov esi, [space_pt]
    mov edx, [esi + eax * 4]
    test edx, 1
    jz .next                           ; 没映过 = 这页没拿过
    and edx, 0xFFFFF000
    mov eax, edx
    call pmem_free
    jc .next
    inc dword [sd_pages]
.next:
    add ebx, 4096
    dec ecx
    jnz .loop
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  space_user_page:给程序空间里某个虚拟地址**先**映射一页(带 U/S=1)
;    eax = 虚拟地址 → eax = 这页的物理地址(0 = 页池空了)
;  ring 3 有两块页不能等缺页:弹床页(程序 ret 回去执行 int 0x30 的地方)和用户
;  栈页(程序在 ring 3 用的栈)。写内容直接用返回的物理地址 —— 页池在 0x400000
;  以上是恒等映射的,内核视角里物理地址就是虚拟地址。
; ---------------------------------------------------------------------------
space_user_page:
    push ebx
    push ecx
    push edx
    push edi
    mov [sup_va], eax
    mov ecx, 1
    call pmem_alloc_pages
    test eax, eax
    jz .out
    mov [sup_pa], eax
    mov edi, eax                        ; 新页清零(栈页里除了返回地址都该是 0)
    xor eax, eax
    mov ecx, 1024
    rep stosd
    ; 装进私有页表 —— 这里**必须**带 PAGE_USER:没有这一位,ring 3 一碰就是
    ; "页在,但你没资格"(错误码 bit0=1)的保护违规,而不是缺页。
    mov ebx, [sup_va]
    shr ebx, 12
    and ebx, 0x3FF                      ; 页表项下标
    mov edi, [space_pt]
    mov edx, [sup_pa]
    or edx, PAGE_P | PAGE_RW | PAGE_USER
    mov [edi + ebx * 4], edx
    inc dword [space_pages]             ; 这两页不是"按需补的",跟着空间一起收摊
    mov eax, [sup_va]
    invlpg [eax]
    mov eax, [sup_pa]
.out:
    pop edi
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  space_prepare_user:准备 ring 3 的两块页
;    · 弹床页(镜像窗口最后一页 0x19F000)写三条指令:mov eax,15 / int 0x30 / jmp $
;    · 用户栈页(堆窗口最后一页 0x1EF000)的栈顶放一个返回地址 = 弹床
;  返回 eax = 弹床虚拟地址;0 = 页池不够(调用方按 OOM 处理)
;  为什么要弹床:现有程序的结尾都是 `ret`(汇编写的,C 那套也是),而 ret 的目标
;  地址是我们压进用户栈的。压内核地址没用 —— ring 3 一跳过去就是 #PF。所以压
;  一段"用户态里的小代码",它替程序喊一声"我退出"(int 0x30 功能号 15)。
;  好处:HELLO/TOUCH/EDIT/CALC/UTF8/HANG 一个字节都不用改。
; ---------------------------------------------------------------------------
space_prepare_user:
    pushad
    mov eax, SPACE_TRAMP_VA
    call space_user_page
    test eax, eax
    jz .fail
    mov edi, eax                        ; 往弹床页写那三条指令
    mov esi, tramp_code
    mov ecx, tramp_code_end - tramp_code
    rep movsb
    mov eax, SPACE_STACK_VA
    call space_user_page
    test eax, eax
    jz .fail
    mov edi, eax
    add edi, 4096 - 4                   ; 栈顶往下 4 字节:弹床的地址
    mov dword [edi], SPACE_TRAMP_VA
    popad
    mov eax, SPACE_TRAMP_VA
    ret
.fail:
    popad
    xor eax, eax
    ret

; ---------------------------------------------------------------------------
;  prog_kill_from_fault:ring 3 的程序犯错了(页错误/特权指令)→ 干掉它,系统活着
;    ebx = isr_common 的帧指针([+32] 向量 [+36] 错误码 [+40] EIP [+44] CS)
;  不返回:把内核现场恢复成"程序还没跑"的样子(和 api.asm 的 exit 门同一条路),
;  直接跳回 cmd_run。这正是 ring 3 的意义:玩具程序乱写地址,内核不受影响。
; ---------------------------------------------------------------------------
prog_kill_from_fault:
    pushad
    mov [pk_frame], ebx
    mov eax, EV_PROG_CRASH              ; 事件账本:程序崩了(附带出错处的 EIP)
    mov ebx, [ebx + 40]
    call evt_log
    call rc_on_crash                    ; on_crash="reboot" 的话,这里就去重启
    mov al, 10
    call term_putc
    mov al, COL_ERR
    call term_set_color
    mov esi, msg_pk_head
    call term_print
    mov eax, [pk_frame]
    cmp dword [eax + 32], 14
    jne .other
    ; ---- 14 号页错误:报 CR2(碰了哪儿)和 EIP(哪条指令碰的)----
    mov esi, msg_pk_pf
    call term_print
    mov eax, cr2
    call term_print_hex
    mov esi, msg_pk_eip
    call term_print
    mov eax, [pk_frame]
    mov eax, [eax + 40]
    call term_print_hex
    mov eax, [pk_frame]
    ; 错误码:bit0=页存在(1)/不存在(0),bit1=写操作,bit2=ring 3 访问。
    ;  bit0=1 = "页在,但没你的份"(碰内核内存就是这种);bit0=0 = 压根没映射。
    test dword [eax + 36], 1
    jz .notmapped
    mov esi, msg_pk_notyours
    call term_print
    jmp .done
.notmapped:
    mov esi, msg_pk_umapped
    call term_print
    jmp .done
.other:
    ; ---- 别的异常(#GP/#UD…):多半是碰了只有内核能用的指令 ----
    mov esi, msg_pk_exc
    call term_print
    mov eax, [pk_frame]
    mov eax, [eax + 32]
    call term_print_dec
    mov esi, msg_pk_eip
    call term_print
    mov eax, [pk_frame]
    mov eax, [eax + 40]
    call term_print_hex
    mov esi, msg_pk_priv
    call term_print
.done:
    mov al, 10
    call term_putc
    mov al, COL_NORMAL
    call term_set_color

    ; ---- 回 shell 的内核现场 ----
    mov dword [run_status], 1           ; 1 = 不是正常退出,是"被干掉的"
    mov esp, [run_esp]
    mov ax, GDT_KDATA
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov eax, PD_ADDR
    mov cr3, eax                        ; 换回内核页目录
    jmp run_resume_kernel

lfb_pde_idx  dd 0
lfb_base     dd 0
map_va       dd 0
map_pa       dd 0
map_flags    dd 0

space_pd       dd 0                    ; 当前程序空间的页目录(物理地址,给 CR3)
space_pt       dd 0                    ; 它的私有页表
space_pages    dd 0                    ; 这套空间**固定**占几页(页目录 + 页表 = 2)
space_live     dd 0                    ; 1 = 有程序在跑(14 号页错误才走按需分页)
space_img_bytes dd 0                   ; 这次要跑的镜像文件字节数(决定镜像页拷多少、`.bss` 从哪开始)
space_pf_run   dd 0                    ; 这一次运行补进来几页
space_pf_img   dd 0                    ;   其中镜像窗口几页
space_pf_heap  dd 0                    ;   其中堆窗口几页
space_pf_total dd 0                    ; 开机到现在一共补了几页(pmem 命令会显示)
space_first_pa dd 0                    ; 第一次补进来的物理页(显示"虚拟地址 ≠ 物理地址")
sd_pages       dd 0                    ; space_destroy 数的页数

pf_va          dd 0                    ; 出错地址(从 CR2 抄下来)
pf_new_pa      dd 0                    ; 这一页现拿的物理地址
pf_off         dd 0                    ; 镜像页在文件里的偏移(第几页 × 4096)
pf_len         dd 0                    ; 要从暂存区拷多少字节
pf_saved_cr3   dd 0                    ; 临时切内核页目录前的 CR3
pf_ret         dd 0                    ; page_fault_try_handle 的返回值
pf_is_img      db 0                    ; 出错的是镜像窗口(1)还是堆窗口(0)
msg_pf_oom     db 'out of physical pages while faulting in a page', 10, 0

sup_va         dd 0                    ; space_user_page:要映的虚拟地址
sup_pa         dd 0                    ; space_user_page:拿到的物理页
pk_frame       dd 0                    ; prog_kill_from_fault:异常现场的帧指针
; 弹床页里的三条指令:mov eax,15(退出) / int 0x30 / jmp $。程序 `ret` 到这里。
tramp_code:
    db 0xB8, 15, 0x00, 0x00, 0x00
    db 0xCD, 0x30
    db 0xEB, 0xFE
tramp_code_end:
msg_pk_head    db 'program crashed: ', 0
msg_pk_pf      db 'page fault at ', 0
msg_pk_exc     db 'exception ', 0
msg_pk_eip     db ' (EIP ', 0
msg_pk_notyours db ') -- that page belongs to the kernel, not to you', 10, 0
msg_pk_umapped  db ') -- that address is not mapped in your memory', 10, 0
msg_pk_priv    db ') -- that is a privileged instruction, only the kernel may run it', 10, 0
