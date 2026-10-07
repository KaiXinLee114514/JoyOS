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
;  ── 程序地址空间(全分页的第一步)────────────────────────────────────────
;  之前:内核和程序共用一套页表,程序被平铺在 0x120000(虚拟 = 物理),
;        跑完什么也不回收,下一个程序接着用同一块内存。
;  现在:每个程序跑之前先给它建一套**自己的页目录**:
;
;        页目录   = 内核页目录的副本(内核、VGA、IDT、栈、帧缓冲都还在)
;        页表[0]  = PT_LOW 的副本,但 0x120000-0x1EFFFF 换成**私有页**
;        私有页   = 从页池现拿的两段连续页(镜像 512 KiB + 堆 320 KiB,都清零)
;
;  于是程序的代码/数据/堆在物理上和别人无关:虚拟地址不变(程序不用改、链接
;  地址还是 0x120000),物理页每次运行换一批,跑完连页表一起还给页池。
;
;  内核窗口继续恒等映射 —— 所以 int 0x30 那些内核函数照旧能用,**不需要 ring 3**;
;  程序传给内核的指针也照旧解得开(那会儿用的就是程序这套页表)。
; ===========================================================================
SPACE_IMG_VA     equ 0x120000          ; 程序镜像窗口(shell.asm 的 PROG_ADDR)
SPACE_IMG_PAGES  equ 0x80              ; 512 KiB(0x120000-0x19FFFF,见 include/joyos.h)
SPACE_HEAP_VA    equ 0x1A0000          ; 堆窗口(JOY_HEAP_START)
SPACE_HEAP_PAGES equ 0x50              ; 320 KiB(0x1A0000-0x1EFFFF)

; ---------------------------------------------------------------------------
;  space_create:建一套程序地址空间
;  返回 eax = 页目录物理地址(0 = 页池不够);另外填好 space_pt / space_img_pa /
;  space_heap_pa / space_pages
; ---------------------------------------------------------------------------
space_create:
    pushad
    mov dword [space_pd], 0
    mov dword [space_pt], 0
    mov dword [space_img_pa], 0
    mov dword [space_heap_pa], 0
    mov dword [space_pages], 0

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
    or  eax, PAGE_P | PAGE_RW
    mov edi, [space_pd]
    mov [edi], eax

    ; ---- 3) 镜像窗口:连续 128 页(512 KiB),清零后映到 0x120000 ----
    mov ecx, SPACE_IMG_PAGES
    call pmem_alloc_pages
    test eax, eax
    jz .fail
    mov [space_img_pa], eax
    mov ecx, SPACE_IMG_PAGES
    call space_zero
    mov eax, [space_img_pa]
    mov edi, SPACE_IMG_VA
    mov ecx, SPACE_IMG_PAGES
    call space_map_window

    ; ---- 4) 堆窗口:连续 80 页(320 KiB)----
    mov ecx, SPACE_HEAP_PAGES
    call pmem_alloc_pages
    test eax, eax
    jz .fail
    mov [space_heap_pa], eax
    mov ecx, SPACE_HEAP_PAGES
    call space_zero
    mov eax, [space_heap_pa]
    mov edi, SPACE_HEAP_VA
    mov ecx, SPACE_HEAP_PAGES
    call space_map_window

    ; ---- 5) 记账:两段私有页 + 私有页表 + 页目录 ----
    mov dword [space_pages], SPACE_IMG_PAGES + SPACE_HEAP_PAGES + 2
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
;  space_destroy:拆掉程序地址空间,私有页 / 私有页表 / 页目录全还给页池
;  (半路建失败时也能调:指针是 0 的步骤直接跳过)
;  返回 eax = 还回去的页数
; ---------------------------------------------------------------------------
space_destroy:
    pushad
    mov dword [sd_pages], 0

    mov eax, [space_img_pa]
    test eax, eax
    jz .no_img
    mov ecx, SPACE_IMG_PAGES
    call pmem_free_pages
    add [sd_pages], eax
.no_img:
    mov eax, [space_heap_pa]
    test eax, eax
    jz .no_heap
    mov ecx, SPACE_HEAP_PAGES
    call pmem_free_pages
    add [sd_pages], eax
.no_heap:
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
    mov dword [space_img_pa], 0
    mov dword [space_heap_pa], 0
    mov dword [space_pt], 0
    mov dword [space_pd], 0
    popad
    mov eax, [sd_pages]
    ret

; ---------------------------------------------------------------------------
;  内部小工具(给 space_create 用)
; ---------------------------------------------------------------------------
; 把 eax 起的 ecx 页清零(这块在恒等映射里,拿到地址就能直接写)
space_zero:
    push edi
    push ecx
    mov edi, eax
    shl ecx, 10                        ; 页数 × 每页 1024 个 dword
    xor eax, eax
    rep stosd
    pop ecx
    pop edi
    ret

; 把 [space_pt] 里从虚拟地址 edi 起的 ecx 项,指向 eax 起的连续物理页
space_map_window:
    push ecx
    push esi
.loop:
    mov ebx, edi
    shr ebx, 12
    and ebx, 0x3FF                     ; 页表项下标
    mov esi, [space_pt]
    mov edx, eax
    and edx, 0xFFFFF000
    or  edx, PAGE_P | PAGE_RW
    mov [esi + ebx * 4], edx
    add eax, 4096
    add edi, 4096
    dec ecx
    jnz .loop
    pop esi
    pop ecx
    ret

lfb_pde_idx  dd 0
lfb_base     dd 0
map_va       dd 0
map_pa       dd 0
map_flags    dd 0
space_pd      dd 0                     ; 当前程序空间的页目录(物理地址,给 CR3)
space_pt      dd 0                     ; 它的私有页表
space_img_pa  dd 0                     ; 镜像窗口第一页的物理地址(拷镜像用)
space_heap_pa dd 0                     ; 堆窗口第一页的物理地址
space_pages   dd 0                     ; 这套空间一共占了几页(显示用)
sd_pages      dd 0                     ; space_destroy 数的页数
