; ============================================================================
;  RING3.BIN —— 证明"程序真的跑在 ring 3"
;
;  这个程序只干一件事:把 CPU 现在给它的特权级、段选择子、栈指针打印出来。
;  跑在 ring 0 的话 CS 会是 0x0008(内核代码段),CPL = 0;
;  跑在 ring 3 的话 CS 是 0x001b(用户代码段)、CPL = 3、SS = 0x0023。
;
;  还能顺手证明"程序是被内核用 iret 丢进用户态的":[esp] 里那个返回地址
;  是内核替我们压进去的**弹床页**(0x19F000),程序结尾的 `ret` 就跳去那儿,
;  弹床里三条指令喊一声 int 0x30 功能号 15(退出)—— 所以程序什么都不用管。
; ============================================================================
[BITS 32]
[ORG 0x120000]

start:
        mov     eax, 0                      ; 0 = 打印字符串
        mov     esi, msg_head
        int     0x30

        ; ---- CS(代码段选择子)----
        mov     eax, 0
        mov     esi, msg_cs
        int     0x30
        mov     eax, 2                      ; 2 = 以十六进制打印 ebx
        xor     ebx, ebx
        mov     bx, cs
        int     0x30

        ; ---- CPL = CS 的最低两位 ----
        mov     eax, 0
        mov     esi, msg_cpl
        int     0x30
        xor     ebx, ebx
        mov     bx, cs
        and     ebx, 3
        mov     eax, 1                      ; 1 = 打印十进制
        int     0x30

        ; ---- SS(栈段选择子)----
        mov     eax, 0
        mov     esi, msg_ss
        int     0x30
        mov     eax, 2
        xor     ebx, ebx
        mov     bx, ss
        int     0x30

        ; ---- ESP:内核给的用户栈 ----
        mov     eax, 0
        mov     esi, msg_esp
        int     0x30
        mov     eax, 2
        mov     ebx, esp
        int     0x30

        ; ---- [esp]:内核压进来的返回地址 = 弹床页 ----
        mov     eax, 0
        mov     esi, msg_ret
        int     0x30
        mov     eax, 2
        mov     ebx, [esp]
        int     0x30

        mov     eax, 0
        mov     esi, msg_tail
        int     0x30

        ret                                 ; → 弹床 → int 0x30 功能号 15 → 回 shell
; ============================================================================
msg_head db 'RING3.BIN: asking the CPU where I am running', 10, 0
msg_cs   db '  CS  = ', 0
msg_cpl  db '  (CPL = ', 0
msg_ss   db '), SS = ', 0
msg_esp  db '  ESP = ', 0
msg_ret  db ', [ESP] = ', 0
msg_tail db 10, 'if CS is 0x001b and CPL is 3, this program is not the kernel any more.', 10, 0
