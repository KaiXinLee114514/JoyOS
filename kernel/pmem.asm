; ============================================================================
;  JoyOS — 物理页池(位图分配器)
;
;  ── 这是在解决什么问题 ──────────────────────────────────────────────────
;  分页需要页表,页表自己也要占物理内存(4 KiB 一张)。开机时是硬编码在
;  0x1000/0x2000/... 的,但那只能有固定几张 —— 想在运行期新建页表、想给
;  程序分配内存,就得知道"哪页物理内存是空的"。
;
;  ── 怎么记哪页被用了 ────────────────────────────────────────────────────
;  最简单粗暴的办法:**一位一页**。64512 页 = 64512 位 = 8064 字节的位图,
;  位是 1 = 已占用,0 = 空闲。分配就是"找第一个 0 位顺便置 1"
;  (not + bsf + bts 三条指令),释放就是清位(btr)。
;
;  页池范围:物理 0x00400000 ~ ident_limit(运行时按 RAM 算,默认 128 MiB 机器上
;  是 4 MiB ~ 128 MiB,共 124 MiB;恒等映射封顶 256 MiB 时最大 252 MiB)。
;  为什么从 4 MiB 开始:低 4 MiB 是内核的地盘(BIOS/VGA/页表/内核/各种缓冲/
;  程序加载区/堆/字库都在里面),与其一条条列出来"这些不能用",不如整段划出去 ——
;  反正 4 MiB 以上现在全空。
;  为什么到 ident_limit 为止:分页只恒等映射了 0~ident_limit,发出去的页必须是
;  内核能直接访问的(指针就是物理地址),所以池子不能越过恒等映射的边界。
;
;  池里的页在恒等映射范围内,所以拿到地址就能直接读写 —— 不用再 paging_map 一次。
; ============================================================================

PMEM_BITMAP  equ 0x3D0000              ; 位图(8192 字节,最多 64512 页 = 252 MiB 页池)
                                       ;   0x3D0000 在 PINYIN(0x3B0000~0x3BFFFF)
                                       ;   和 USB 结构(0x3C0000~0x3C1FFF)之后的空闲区,
                                       ;   仍低于 4 MiB,恒等映射(PT_LOW)罩得住。
PAGE_BYTES   equ 4096                  ; 一页 4 KiB
; 页池范围不写死了:kmain.asm 启动时按 E820 探到的 RAM 算好
;   pmem_start / pmem_end / pmem_total / pmem_words
; 位图按"一页一位、一个 dword 记 32 页"排,上限 64512 页 = 252 MiB 页池
; (= 256 MiB 恒等映射减掉低 4 MiB)。

; ---------------------------------------------------------------------------
;  pmem_init:位图清零 = 全部空闲
; ---------------------------------------------------------------------------
pmem_init:
    pushad
    mov edi, PMEM_BITMAP
    mov ecx, [pmem_words]              ; 运行时算出来的位图 dword 数
    xor eax, eax
    rep stosd
    mov eax, [pmem_total]
    mov [pmem_free_count], eax
    mov dword [pmem_alloced], 0
    mov eax, [pmem_start]
    mov [pmem_hi], eax
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
    cmp edx, [pmem_words]
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
    add eax, [pmem_start]              ; 物理地址
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
    cmp eax, [pmem_start]
    jb .bad                            ; 低于池子(内核地盘,不归我们管)
    cmp eax, [pmem_end]
    jae .bad                           ; 高于池子
    sub eax, [pmem_start]
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
    ; 页池是空的(内存太小,恒等映射只有 4 MiB)或比要的还小:直接失败。
    ; 不先挡一下的话,下面的扫描在 total==0 时会绕 40 亿圈,最后"凭空"分出一页
    ; 落在恒等映射外面 —— 一写就 #PF。8 MiB 虚拟机的 panic 就是这么来的。
    mov eax, [pmem_total]
    test eax, eax
    jz .nomem
    cmp eax, ecx
    jb .nomem
    mov dword [pap_start], 0
    mov eax, [pmem_total]
    shl eax, 1
    mov [pap_left], eax                 ; 最多扫两圈

    mov esi, PMEM_BITMAP
    mov edi, [pmem_hint]               ; 从上次结束的地方开始
    xor ebx, ebx                       ; 已经连续空闲了几页
.scan:
    cmp edi, [pmem_total]
    jb .in_range
    sub edi, [pmem_total]              ; 扫到尾了,绕回开头
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
.nomem:
    pop ecx
    xor eax, eax                       ; 页池空/太小 或 找不到这么长的空档
    ret
.found:
    mov eax, edi                       ; 起点 = 当前位置 - need + 1(可能回绕)
    sub eax, [pap_need]
    inc eax
    jns .no_wrap
    add eax, [pmem_total]
.no_wrap:
    mov [pap_start], eax
    mov [pmem_hint], edi               ; 下次从这一段后面接着找
    inc dword [pmem_hint]
    mov eax, [pmem_hint]
    cmp eax, [pmem_total]
    jb .hint_ok
    mov eax, [pmem_total]
    sub dword [pmem_hint], eax
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
    cmp edi, [pmem_total]
    jb .mark_in
    sub edi, [pmem_total]
.mark_in:
    dec ecx
    jnz .mark

    mov eax, [pap_need]
    sub dword [pmem_free_count], eax
    add dword [pmem_alloced], eax
    mov eax, [pap_start]
    shl eax, 12
    add eax, [pmem_start]
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
