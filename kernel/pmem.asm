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
    mov dword [pmem_free_count], PMEM_TOTAL
    mov dword [pmem_alloced], 0
    mov dword [pmem_hi], PMEM_START
    mov dword [pmem_hint], 0           ; 连续分配从第 0 页开始找
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
    dec dword [pmem_free_count]
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
    inc dword [pmem_free_count]
    dec dword [pmem_alloced]
    pop ebx
    clc
    ret
.bad:
    pop ebx
    stc
    ret

; ---------------------------------------------------------------------------
;  pmem_alloc_pages:要一段**连续**的 ecx 页
;
;  为什么需要连续:程序地址空间的镜像/堆窗口拿连续页,往私有页里拷镜像就一次
;  rep movsd 搞定,不用一页页翻页表。
;
;  为什么从 pmem_hint 开始找:要是每次都从第 0 页开始扫,程序跑完把页还回来、
;  下次又拿到同一批地址 —— 看上去"页池像没动过"。从上次结束的地方接着找、
;  扫两圈(wrap),同一个程序跑两次就会落在不同的物理页上,一眼能看出虚拟 ≠ 物理。
;
;  返回 eax = 起始物理地址(4 KiB 对齐),0 = 没有这么长的空档
;  破坏 eax / ebx / ecx / edx / esi / edi
; ---------------------------------------------------------------------------
pmem_alloc_pages:
    push ecx
    mov [pap_need], ecx
    mov dword [pap_start], 0
    mov dword [pap_left], PMEM_TOTAL * 2   ; 最多扫两圈

    mov esi, PMEM_BITMAP
    mov edi, [pmem_hint]               ; 从上次结束的地方开始
    xor ebx, ebx                       ; 已经连续空闲了几页
.scan:
    cmp edi, PMEM_TOTAL
    jb .in_range
    sub edi, PMEM_TOTAL                ; 扫到尾了,绕回开头
.in_range:
    mov eax, edi                       ; 看位 edi
    shr eax, 5
    mov eax, [esi + eax * 4]
    mov ecx, edi
    and ecx, 31
    bt  eax, ecx                       ; CF = 这一位
    jc .used
    inc ebx                            ; 空闲,连着的又多一页
    cmp ebx, [pap_need]
    jae .found
    jmp .next
.used:
    xor ebx, ebx                       ; 断了,从头数
.next:
    inc edi
    dec dword [pap_left]
    jnz .scan
    pop ecx
    xor eax, eax                       ; 找不到这么长的空档
    ret
.found:
    mov eax, edi                       ; 起点 = 当前位置 - need + 1(可能回绕)
    sub eax, [pap_need]
    inc eax
    jns .no_wrap
    add eax, PMEM_TOTAL
.no_wrap:
    mov [pap_start], eax
    mov [pmem_hint], edi               ; 下次从这一段后面接着找
    inc dword [pmem_hint]
    cmp dword [pmem_hint], PMEM_TOTAL
    jb .hint_ok
    sub dword [pmem_hint], PMEM_TOTAL
.hint_ok:
    mov ecx, [pap_need]                ; ---- 把这些位全置 1 ----
    mov edi, [pap_start]
.mark:
    mov eax, edi
    shr eax, 5
    mov edx, edi
    and edx, 31
    bts dword [esi + eax * 4], edx
    inc edi
    cmp edi, PMEM_TOTAL
    jb .mark_in
    sub edi, PMEM_TOTAL
.mark_in:
    dec ecx
    jnz .mark

    mov eax, [pap_need]
    sub dword [pmem_free_count], eax
    add dword [pmem_alloced], eax
    mov eax, [pap_start]
    shl eax, 12
    add eax, PMEM_START
    cmp eax, [pmem_hi]
    jbe .no_hi
    mov [pmem_hi], eax
.no_hi:
    pop ecx
    ret

; ---------------------------------------------------------------------------
;  pmem_free_pages:还一段连续的页。eax = 起始物理地址,ecx = 页数
;  返回 eax = 实际还成功的页数(已被别人占了/越界的那几页不会算)
; ---------------------------------------------------------------------------
pmem_free_pages:
    push ebx
    push edi
    mov [pfp_addr], eax
    mov [pfp_left], ecx
    xor edi, edi                       ; 计数
.loop:
    mov eax, [pfp_addr]
    call pmem_free
    jc .next
    inc edi
.next:
    add dword [pfp_addr], PAGE_BYTES
    dec dword [pfp_left]
    jnz .loop
    mov eax, edi
    pop edi
    pop ebx
    ret

pmem_free_count dd 0                   ; 空闲页数
pmem_alloced    dd 0                   ; 已分配页数
pmem_hi         dd 0                   ; 分配过的最高地址(纯给 shell 显示)
pmem_hint       dd 0                   ; 连续分配的下次搜索起点(轮转用)
pap_need        dd 0                   ; pmem_alloc_pages 临时:要几页
pap_start       dd 0                   ; pmem_alloc_pages 临时:找到的起始页号
pap_left        dd 0                   ; pmem_alloc_pages 临时:还能扫多少位
pfp_addr        dd 0                   ; pmem_free_pages 临时
pfp_left        dd 0
