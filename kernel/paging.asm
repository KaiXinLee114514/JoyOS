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

lfb_pde_idx  dd 0
lfb_base     dd 0
map_va       dd 0
map_pa       dd 0
map_flags    dd 0
