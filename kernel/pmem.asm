; ============================================================================
;  JoyOS (胡闹OS) — 物理页池(位图分配器)
;
;  ── 这是在解决什么问题 ──────────────────────────────────────────────────
;  分页需要页表,页表自己也要占物理内存(4 KiB 一张)。开机时是硬编码在
;  0x1000/0x2000/... 的,但那只能有固定几张 —— 想在运行期新建页表、想给
;  程序分配内存,就得知道"哪页物理内存是空的"。
;
;  ── 怎么记哪页被用了 ────────────────────────────────────────────────────
;  最简单粗暴的办法:**一位一页**。3072 页 = 3072 位 = 384 字节的位图,
;  位是 1 = 已占用,0 = 空闲。分配就是"找第一个 0 位顺便置 1"
;  (not + bsf + bts 三条指令),释放就是清位(btr)。
;
;  页池范围:物理 0x00400000 ~ 0x00FFFFFF(4 MiB ~ 16 MiB,共 12 MiB)。
;  为什么从 4 MiB 开始:低 4 MiB 是内核的地盘(BIOS/VGA/页表/内核/各种缓冲/
;  程序加载区/堆/字库都在里面),与其一条条列出来"这些不能用",不如整段划出去 ——
;  反正 4 MiB 以上现在全空。
;  为什么到 16 MiB 为止:分页只恒等映射了 0~16 MiB,发出去的页必须是内核能
;  直接访问的(指针就是物理地址),所以池子不能越过恒等映射的边界。
;  真实机器内存多少没探测(E820 还没做),16 MiB 是写死的约定。
;
;  池里的页在恒等映射范围内,所以拿到地址就能直接读写 —— 不用再 paging_map 一次。
; ============================================================================

PMEM_BITMAP  equ 0x6000                ; 位图(384 字节,放在低内存空闲处)
PMEM_START   equ 0x400000              ; 页池起点(4 MiB)
PMEM_END     equ IDENT_LIMIT           ; 页池终点(16 MiB,= 恒等映射边界)
PAGE_BYTES   equ 4096                  ; 一页 4 KiB

PMEM_TOTAL   equ (PMEM_END - PMEM_START) / PAGE_BYTES   ; 3072 页
PMEM_MIB     equ (PMEM_END - PMEM_START) / 0x100000     ; 12 MiB(shell 显示用)
PMEM_WORDS   equ PMEM_TOTAL / 32                          ; 96 个 dword

; ---------------------------------------------------------------------------
;  pmem_init:位图清零 = 全部空闲
; ---------------------------------------------------------------------------
pmem_init:
    pushad
    mov edi, PMEM_BITMAP
    mov ecx, PMEM_WORDS
    xor eax, eax
    rep stosd
    mov dword [pmem_free_pages], PMEM_TOTAL
    mov dword [pmem_alloced], 0
    mov dword [pmem_hi], PMEM_START
    popad
    ret

; ---------------------------------------------------------------------------
;  pmem_alloc:要一页 → eax = 物理地址(4 KiB 对齐);页池空了返回 0
;  破坏 ebx / ecx / edx
; ---------------------------------------------------------------------------
pmem_alloc:
    push esi
    mov esi, PMEM_BITMAP
    xor edx, edx                       ; dword 下标
.scan:
    mov eax, [esi + edx * 4]
    cmp eax, -1                        ; 全 1 = 这个 dword 全占了
    jne .found                         ; (别写成 not+jnz:not 不动标志位!踩过)
    inc edx
    cmp edx, PMEM_WORDS
    jb .scan
    pop esi
    xor eax, eax                       ; 一页都没有了
    ret
.found:
    not eax                            ; 空闲位变成 1,方便 bsf
    bsf ecx, eax                       ; 第一个空闲位
    bts dword [esi + edx * 4], ecx     ; 置 1 = 占住
    mov eax, edx
    shl eax, 5                         ; dword 下标 × 32
    add eax, ecx                       ; 页号
    shl eax, 12                        ; × 4096
    add eax, PMEM_START                ; 物理地址
    dec dword [pmem_free_pages]
    inc dword [pmem_alloced]
    cmp eax, [pmem_hi]
    jbe .no_hi
    mov [pmem_hi], eax                 ; 记一下分配到的最高地址(给 pmem 命令看)
.no_hi:
    pop esi
    ret

; ---------------------------------------------------------------------------
;  pmem_free:还一页,eax = 物理地址。不是池里的页 / 没对齐 / 重复释放 → CF=1
; ---------------------------------------------------------------------------
pmem_free:
    push ebx
    test eax, PAGE_BYTES - 1
    jnz .bad                           ; 没页对齐
    cmp eax, PMEM_START
    jb .bad                            ; 低于池子(内核地盘,不归我们管)
    cmp eax, PMEM_END
    jae .bad                           ; 高于池子
    sub eax, PMEM_START
    shr eax, 12                        ; 页号
    mov ebx, eax
    shr ebx, 5                         ; dword 下标
    and eax, 31                        ; 位号
    btr dword [PMEM_BITMAP + ebx * 4], eax   ; 清位,CF = 原来的值
    jnc .bad                           ; 本来就是 0 = 重复释放
    inc dword [pmem_free_pages]
    dec dword [pmem_alloced]
    pop ebx
    clc
    ret
.bad:
    pop ebx
    stc
    ret

pmem_free_pages dd 0                   ; 空闲页数
pmem_alloced    dd 0                   ; 已分配页数
pmem_hi         dd 0                   ; 分配过的最高地址(纯给 shell 显示)
