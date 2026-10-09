; ============================================================================
;  JoyOS (胡闹OS) — 调度器:内核线程 + 抢占式轮转
;
;  在这之前,系统里只有一个"执行流":shell 敲命令 → 程序跑 → 回到 shell。
;  PIT 每 10 ms 敲一次 IRQ0,但我们只是数了个 tick 就返回了。这个文件把那次
;  中断变成"换人的机会":中断进来时 CPU 的现场已经在栈上了,只要我们把这个
;  esp 存起来、换成另一个线程的 esp,再按原路 popad + iret 回去 —— 回去的
;  就已经是另一个线程了。**OS 里的"并发"说白了就是这一下换栈。**
;
;  为什么能这么干:每个线程的栈上都有一份一模一样的现场
;     [pushad 八个寄存器][向量号][错误码][eip][cs][eflags]
;  (新线程的那份是我们自己搭出来的,见 sched_spawn)。所以"切线程"不需要什么
;  神奇的指令,只要 esp 指着谁的现场,iret 就回谁那儿去。
;
;  谁在管:irq0_stub(pit.asm)在 pushad 之后调 sched_pick ——
;    1. 把当前 esp / cr3 存进当前线程的 TCB
;    2. 时间片到了就从 sched_cur+1 开始找下一个活着的线程(轮转)
;    3. 返回它的 esp,stub 里一句 `mov esp, eax` 就换过去了
;  顺序上有个坑:p 必须**先发 EOI 再切** —— 不然新线程跑起来时 PIC 还在等这
;  一次的 EOI,IRQ0 就再也不来了(定时器"死"了,但屏幕上看不出来)。
;
;  老实交代的局限(玩具够用,别当正经调度器):
;    · 全是**内核线程**:同一个地址空间、同一个特权级,能直接碰任何内存
;    · 内核不是可重入的:线程最好只算自己的、只打印,别一起去读写文件系统
;      (FAT/ATA 那些全局缓冲会被互相踩)
;    · 打印会互相插队:两个线程同时 term_print,字可能串行(不崩,但难看)
;    · 没有优先级、没有阻塞队列、没有真正的 sleep 队列 —— 想等就 pit_wait_ticks
;    · 杀不掉"正在跑的线程"(0 号 = shell 自己):它还在用那条栈
; ============================================================================

SCHED_MAX         equ 6                 ; 最多几个线程(含 0 号 = shell 自己)
TCB_SIZE          equ 32                ; 每个 TCB 32 字节 → 下标 ×32 = shl 5,好算
TCB_ESP           equ 0                 ; 被切走时保存的 esp(指向它的现场)
TCB_CR3           equ 4                 ; 它的页目录(程序在跑时可能是程序自己的)
TCB_STATE         equ 8                 ; 见下面的 ST_*
TCB_TICKS         equ 12                ; 它一共拿到过几个 tick
TCB_STACK         equ 16                ; 栈的物理基址(死了要还给页池)
TCB_NAME          equ 20                ; 名字(给 ps 看的)
TCB_RUNS          equ 24                ; 被调度上去过几次

ST_EMPTY          equ 0                 ; 空槽
ST_ALIVE          equ 1                 ; 活着
ST_DEAD           equ 2                 ; (留着)已经死掉的

SCHED_STACK_PAGES equ 2                 ; 每个线程 8 KiB 栈,从物理页池拿
SLICE_TICKS       equ 2                 ; 一次跑 2 个 tick(20 ms)就换人
SCHED_CS          equ 0x08              ; 内核代码段选择子(GDT 第 2 项)
EFLAGS_IF         equ 0x202             ; eflags:IF=1,新线程一上来就能被打断

; ---------------------------------------------------------------------------
;  sched_init:清空 TCB 表,把"现在这个上下文"登记成 0 号线程
;  注意 esp / cr3 先留 0:这个上下文就是 shell 自己,它第一次被切走的时候
;  sched_pick 才知道它的 esp 在哪 —— 不用我们猜。
; ---------------------------------------------------------------------------
sched_init:
    pushad
    mov edi, tcb_table
    mov ecx, SCHED_MAX * TCB_SIZE / 4
    xor eax, eax
    rep stosd

    mov edi, tcb_table
    mov dword [edi + TCB_STATE], ST_ALIVE
    mov dword [edi + TCB_NAME], nm_main
    mov dword [sched_cur], 0
    mov dword [sched_live], 1
    mov dword [sched_slice], SLICE_TICKS
    mov dword [sched_on], 0             ; 先在开机流程里跑完,shell 起来再开
    mov dword [sched_next_demo], 0
    popad
    ret

; ---------------------------------------------------------------------------
;  sched_enable:开关一拨,下一次 IRQ0 就开始轮转
;  (一句 mov 就是原子的,不用 cli/sti)
; ---------------------------------------------------------------------------
sched_enable:
    mov dword [sched_on], 1
    ret

; ---------------------------------------------------------------------------
;  sched_pick:由 irq0_stub 调用(此刻 pushad 已经把现场压在栈上了)
;    入:[sched_save_esp] = 当前 esp
;    出:eax = 接下来该 resume 的 esp(可能是同一个,那就是"不切")
;
;  这里**不能**自己换 esp:换栈那一下必须由调用方(irq0_stub)来做,
;  不然这个函数的 ret 会从别人的栈上弹返回地址。
; ---------------------------------------------------------------------------
sched_pick:
    push ebx
    push ecx
    push edx
    push esi
    push edi

    ; ---- 1) 把当前线程的现场存好,顺手记一个 tick ----
    mov eax, [sched_cur]
    shl eax, 5                          ; × TCB_SIZE
    mov ebx, tcb_table
    add ebx, eax
    mov ecx, [sched_save_esp]
    mov [ebx + TCB_ESP], ecx
    mov eax, cr3
    mov [ebx + TCB_CR3], eax
    inc dword [ebx + TCB_TICKS]
    inc dword [sched_ticks]

    ; ---- 2) 只有自己一个线程?不用切(省掉一次 cr3 折腾)----
    cmp dword [sched_live], 2
    jb .keep

    ; ---- 3) 时间片还没用完?继续跑 ----
    dec dword [sched_slice]
    jg .keep
    mov dword [sched_slice], SLICE_TICKS

    ; ---- 4) 从 cur+1 开始找下一个活着的(转一圈,最多 SCHED_MAX 次)----
    mov esi, [sched_cur]
    mov ecx, SCHED_MAX
.next_slot:
    inc esi
    cmp esi, SCHED_MAX
    jb .no_wrap
    xor esi, esi
.no_wrap:
    mov edx, esi
    shl edx, 5
    add edx, tcb_table
    cmp dword [edx + TCB_STATE], ST_ALIVE
    jne .try_next
    ; 找到人:换地址空间(每个线程自己的 cr3),再交出它的 esp
    mov [sched_cur], esi
    mov eax, [edx + TCB_CR3]
    mov cr3, eax
    inc dword [edx + TCB_RUNS]
    mov eax, [edx + TCB_ESP]
    jmp .out
.try_next:
    dec ecx
    jnz .next_slot

    ; 一圈下来只剩自己 → 当没切
.keep:
    mov eax, [sched_save_esp]
.out:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  sched_spawn:造一个新线程
;    入:eax = 入口地址(线程从这儿开始跑),ebx = 名字字符串
;    出:CF=0 时 eax = 线程号;CF=1 = 没槽 / 没内存
;
;  新线程的"现场"是搭出来的,不是压出来的 —— 按 irq0_stub 里那份格式,
;  从栈顶往下摆:
;     [eflags][cs][eip] [错误码][向量号] [eax..edi 八个]
;  esp 指向最低的 edi。这样第一次被调度上去时,stub 的 popad + iret
;  一条不差地把它送进入口函数。
; ---------------------------------------------------------------------------
sched_spawn:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp

    mov [spawn_entry], eax
    mov [spawn_name], ebx

    ; ---- 1) 找一个空槽 ----
    xor esi, esi
.find_slot:
    mov edx, esi
    shl edx, 5
    add edx, tcb_table
    cmp dword [edx + TCB_STATE], ST_EMPTY
    je .got_slot
    inc esi
    cmp esi, SCHED_MAX
    jb .find_slot
    stc                                 ; 槽满了
    jmp .out

.got_slot:
    mov [spawn_slot], esi
    mov [spawn_tcb], edx

    ; ---- 2) 要一段连续页当栈(栈得是连续内存,不然 push 就散了)----
    mov ecx, SCHED_STACK_PAGES
    call pmem_alloc_pages
    test eax, eax
    jz .nomem
    mov [spawn_stack], eax

    ; ---- 3) 在栈顶搭现场 ----
    mov edi, eax
    add edi, SCHED_STACK_PAGES * 4096    ; edi = 栈顶上沿(栈往下长)
    mov eax, [spawn_entry]
    mov [edi - 12], eax                  ; eip:iret 之后从这儿开始
    mov dword [edi - 8], SCHED_CS        ; cs
    mov dword [edi - 4], EFLAGS_IF       ; eflags
    mov dword [edi - 16], 0              ; 错误码(用不上)
    mov dword [edi - 20], IRQ0_VECTOR    ; 向量号(stub 会 add esp,8 丢掉)
    ; pushad 的八个:全 0,线程从干净的寄存器开始
    mov dword [edi - 24], 0              ; eax
    mov dword [edi - 28], 0              ; ecx
    mov dword [edi - 32], 0              ; edx
    mov dword [edi - 36], 0              ; ebx
    mov dword [edi - 40], 0              ; esp(占位,popad 会跳过)
    mov dword [edi - 44], 0              ; ebp
    mov dword [edi - 48], 0              ; esi
    mov dword [edi - 52], 0              ; edi ← esp 指这儿
    sub edi, 52

    ; ---- 4) 填 TCB ----
    mov edx, [spawn_tcb]
    mov [edx + TCB_ESP], edi
    mov eax, cr3
    mov [edx + TCB_CR3], eax             ; 和造它的那个线程共用地址空间
    mov dword [edx + TCB_STATE], ST_ALIVE
    mov dword [edx + TCB_TICKS], 0
    mov dword [edx + TCB_RUNS], 0
    mov eax, [spawn_stack]
    mov [edx + TCB_STACK], eax
    mov eax, [spawn_name]
    mov [edx + TCB_NAME], eax
    inc dword [sched_live]
    mov eax, [spawn_slot]                ; 返回线程号
    clc
    jmp .out

.nomem:
    stc
.out:
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  sched_kill:杀掉一个线程(把它的栈还给页池)
;    入:eax = 线程号   出:CF=0 成功,CF=1 = 号不对 / 空槽 / 想杀自己
;  为什么不能杀自己:0 号线程就是 shell,它还在用那条栈走路 —— 自己把自己
;  脚下的栈还给页池,下一条 push 就把自己埋了。
; ---------------------------------------------------------------------------
sched_kill:
    push ebx
    push ecx
    push edx

    cmp eax, SCHED_MAX
    jae .bad
    cmp eax, [sched_cur]
    je .bad
    mov ebx, eax
    shl ebx, 5
    add ebx, tcb_table
    cmp dword [ebx + TCB_STATE], ST_ALIVE
    jne .bad

    ; 还栈(杀的是别人,它此刻没在跑,放心还)
    mov eax, [ebx + TCB_STACK]
    test eax, eax
    jz .freed
    mov ecx, SCHED_STACK_PAGES
    call pmem_free_pages
.freed:
    mov dword [ebx + TCB_STATE], ST_EMPTY
    mov dword [ebx + TCB_STACK], 0
    mov dword [ebx + TCB_ESP], 0
    mov dword [ebx + TCB_CR3], 0
    mov dword [ebx + TCB_TICKS], 0
    mov dword [ebx + TCB_RUNS], 0
    mov dword [ebx + TCB_NAME], nm_free
    dec dword [sched_live]
    clc
    jmp .out

.bad:
    stc
.out:
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  sched_name:eax = 线程号 → esi = 名字指针,CF=1(越界)时 esi = 0
;  给 ps / kill 打印用
; ---------------------------------------------------------------------------
sched_name:
    xor esi, esi
    cmp eax, SCHED_MAX
    jae .bad
    mov esi, tcb_table
    shl eax, 5
    add esi, eax
    mov esi, [esi + TCB_NAME]
    clc
    ret
.bad:
    stc
    ret

; ---------------------------------------------------------------------------
;  thread_alpha / thread_beta:两个演示线程
;  每秒打一行自己的名字 + 数到几。它们互相抢 CPU 的痕迹就在屏幕上:
;  谁的名字在"对方数到一半"的时候插进来。等的时候用 pit_wait_ticks(hlt),
;  不烧 CPU —— 睡眠期间 CPU 完全是另一个线程的。
; ---------------------------------------------------------------------------
thread_alpha:
    mov dword [demo_a], 0
.loop:
    inc dword [demo_a]
    mov byte [term_color], COL_NORMAL    ; 打印前先把颜色摆正(另一个线程可能改了)
    mov esi, msg_t_alpha
    call term_print
    mov eax, [demo_a]
    call term_print_dec
    mov al, 10
    call term_putc
    mov ecx, 100                         ; 1 秒
    call pit_wait_ticks
    jmp .loop

thread_beta:
    mov dword [demo_b], 0
.loop:
    inc dword [demo_b]
    mov byte [term_color], COL_NORMAL
    mov esi, msg_t_beta
    call term_print
    mov eax, [demo_b]
    call term_print_dec
    mov al, 10
    call term_putc
    mov ecx, 100
    call pit_wait_ticks
    jmp .loop

; ---------------------------------------------------------------------------
;  数据
; ---------------------------------------------------------------------------
sched_on        dd 0                    ; 调度开关:0 = IRQ0 只数 tick
sched_cur       dd 0                    ; 当前线程号
sched_live      dd 0                    ; 活着的线程数
sched_ticks     dd 0                    ; 调度器一共数了多少 tick
sched_slice     dd SLICE_TICKS          ; 当前线程还剩几个 tick 的时间片
sched_save_esp  dd 0                    ; irq0_stub 交给 sched_pick 的 esp
sched_next_demo dd 0                    ; spawn 不带参数时下一个起谁(0=alpha 1=beta)

; sched_spawn 的临时变量(不用 ebp 帧,省得栈上再挪一遍)
spawn_entry     dd 0
spawn_name      dd 0
spawn_slot      dd 0
spawn_tcb       dd 0
spawn_stack     dd 0

demo_a          dd 0                    ; alpha 数到几
demo_b          dd 0                    ; beta 数到几

tcb_table       times SCHED_MAX * TCB_SIZE db 0

nm_main         db 'shell', 0
nm_free         db '(free)', 0
msg_t_alpha     db 'alpha ', 0
msg_t_beta      db 'beta ', 0

; 线程名字符串(n_alpha / n_beta 给 shell 解析 spawn 的参数用)
n_alpha         db 'alpha', 0
n_beta          db 'beta', 0
n_thread_alpha  db 'thread', 0          ; (留着:以后 spawn 自定义名字用)
