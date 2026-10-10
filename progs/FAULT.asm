; ============================================================================
;  FAULT.BIN —— 故意去碰内核的内存,看保护是不是真的在干活
;
;  跑在 ring 3 的程序,页表里只有自己那两块窗口(镜像 0x120000-0x19FFFF、
;  堆 0x1A0000-0x1EFFFF)带 U/S 位;内核的页(包括恒等映射的 0-16 MiB)是
;  "supervisor only"。这条 `mov ebx, [0x00100000]` 就是去摸内核的地盘 ——
;  期望结果:页错误 → 内核把程序干掉 → 回到 shell,内核自己一点事都没有。
;
;  如果屏幕上出现最后那行 'protection is broken',说明 ring 3 是假的。
; ============================================================================
[BITS 32]
[ORG 0x120000]

start:
        mov     eax, 0                      ; 0 = 打印字符串
        mov     esi, msg_head
        int     0x30

        mov     ebx, [0x00100000]           ; ← 这一条必须死:内核内存,没你的份

        mov     eax, 0
        mov     esi, msg_broken
        int     0x30

        ret                                 ; 正常程序不该走到这儿
; ============================================================================
msg_head   db 'FAULT.BIN: now reading kernel memory at 0x00100000 ...', 10, 0
msg_broken db 'FAULT.BIN: protection is broken - a ring 3 program read kernel memory!', 10, 0
