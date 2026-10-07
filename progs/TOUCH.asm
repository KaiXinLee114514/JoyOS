; ============================================================================
;  TOUCH.BIN — 按需分页的演示程序
;
;  它故意去碰几块"建地址空间时根本没给它"的内存:
;
;    1) 堆窗口(0x1A0000)里每 4 KiB 碰一页,一共 32 页 = 128 KiB。
;       每一页的第一次访问都会踩到 14 号页错误,内核从页池现拿一页、清零、
;       填进页表,再回来把那条指令重执行一遍 —— 程序完全感觉不到。
;       顺手检查:现给的页必须**是干净的**(全 0);写进去的标记回头读得到
;       (说明每页都真的归自己,没和别的页串)。
;
;    2) 镜像窗口里离文件很远的一页(0x184000)。文件只有几百字节,这一页在
;       `.bss` 的地盘上:内核给的同样是零页 —— 所以 `.bss` 天然是干净的。
;
;  跑完 shell 会打出这一趟到底补了几页(见 kernel/shell.asm 的 "demand paging:" 那一行)
;  编译: nasm -f bin progs/TOUCH.asm -o build/TOUCH.BIN
;  调用: shell 里  run TOUCH
;
;  注意 [ORG 0x120000] 必须和内核里的加载地址一致(见 kernel/shell.asm 的 PROG_ADDR)
; ============================================================================

[BITS 32]
[ORG 0x120000]

HEAP_START  equ 0x1A0000                ; 堆窗口起点(和 include/joyos.h 一致)
HEAP_PAGES  equ 32                      ; 碰 32 页 = 128 KiB
IMG_TAIL    equ 0x184000                ; 镜像窗口里"文件之外"的一页(.bss)

start:
    mov eax, 4
    mov ebx, 0x0E                       ; 亮黄
    int 0x30
    mov eax, 0
    mov esi, msg_head
    int 0x30

    ; ---- 1) 堆:每页先看看是不是 0,再写一个标记 ----
    mov edi, HEAP_START
    mov ecx, HEAP_PAGES
.loop_heap:
    cmp byte [edi], 0                   ; ← 第一次碰这页:就是这里触发页错误
    je .was_zero
    inc dword [cnt_dirty]               ; 不是 0 就是内核给了脏页(不对)
.was_zero:
    mov byte [edi], 0xA5
    add edi, 4096
    dec ecx
    jnz .loop_heap

    ; ---- 2) 回头再读一遍:每页都该是自己写进去的 0xA5 ----
    mov edi, HEAP_START
    mov ecx, HEAP_PAGES
.reread:
    cmp byte [edi], 0xA5
    je .read_ok
    inc dword [cnt_wrong]
.read_ok:
    add edi, 4096
    dec ecx
    jnz .reread

    ; ---- 3) 镜像窗口里文件之外的一页(.bss):也该是 0 ----
    cmp byte [IMG_TAIL], 0
    jne .bss_dirty
    mov byte [IMG_TAIL], 0x5A           ; 写上:证明这页现在归我
    mov dword [bss_state], 1
    jmp .report
.bss_dirty:
    mov dword [bss_state], 0

.report:
    mov eax, 0
    mov esi, msg_heap
    int 0x30
    mov ebx, HEAP_PAGES
    mov eax, 1                          ; 打印十进制
    int 0x30
    mov eax, 0
    mov esi, msg_pages
    int 0x30

    mov esi, msg_dirty
    int 0x30
    mov ebx, [cnt_dirty]
    mov eax, 1
    int 0x30

    mov eax, 0
    mov esi, msg_wrong
    int 0x30
    mov ebx, [cnt_wrong]
    mov eax, 1
    int 0x30

    mov eax, 0
    mov esi, msg_bss
    int 0x30
    cmp dword [bss_state], 0
    je .say_dirty
    mov esi, msg_clean
    jmp .say
.say_dirty:
    mov esi, msg_seg_dirty
.say:
    mov eax, 0
    int 0x30

    mov eax, 4
    mov ebx, 0x07                       ; 变回浅灰
    int 0x30
    mov eax, 0
    mov esi, msg_tail
    int 0x30
    ret                                 ; 返回 shell

msg_head   db 'touch test: asking for memory the kernel never handed me', 10, 0
msg_heap   db '  heap: touched ', 0
msg_pages  db ' pages (4 KiB each), wrote 0xA5 into every one of them', 10, 0
msg_dirty  db '  pages that were NOT zero before my write: ', 0
msg_wrong  db 10, '  pages that did not read back what I wrote: ', 0
msg_bss    db 10, '  page beyond the file (bss at 0x184000): ', 0
msg_clean  db 'was zero, as it should be', 0
msg_seg_dirty db 'was NOT zero (that would be a bug)', 0
msg_tail   db 10, 'done - pages appeared only where I actually went', 10, 0

cnt_dirty  dd 0                         ; 写之前不是 0 的页数(希望是 0)
cnt_wrong  dd 0                         ; 读回来不对劲的页数(希望是 0)
bss_state  dd 0                         ; .bss 那页是不是干净的
