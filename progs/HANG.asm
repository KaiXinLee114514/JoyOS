; ============================================================================
;  HANG.BIN:把这条 shell 占住的"死循环"程序(每秒打一行,约 8 秒后自己退出)
;
;  用途:演示"一个 shell 里程序卡住了,别的 shell 照样能干活"
;  —— 切过去用 Ctrl+Right,或者敲 shell 2;顺便演示"一次只让一个程序跑"
;  (在别的 shell 里再 run 会被拒)。
;
;  ★ 为什么是 8 秒而不是真的死循环:测试套件要在它跑完之后接着用这条 shell,
;  真死循环会把线程 0 永远占住(线程 0 = 第一条 shell,不可 kill),后面的用例
;  就没法跑了。真想看"永远回不来",把 HANG_ROUNDS 改大、或者把 `dec/ jnz`
;  两行删掉即可 —— 那时候只能 reboot。
;
;  编译:make all(progs/*.asm 自动汇编成 .BIN 塞进 FAT16 镜像)
; ============================================================================
[BITS 32]
[ORG 0x120000]                          ; 和 kernel/shell.asm 的 PROG_ADDR 一致

start:
    mov bl, 0x0C                        ; 亮红:一眼看出这是个"坏"程序
    mov eax, 4
    int 0x30
    mov esi, msg_head
    call print
    mov dword [counter], 0
    mov dword [rounds], HANG_ROUNDS
.loop:
    inc dword [counter]
    mov bl, 0x07
    mov eax, 4
    int 0x30
    mov esi, msg_tick
    call print
    mov eax, [counter]
    call print_dec
    mov esi, msg_tail
    call print
    ; ---- 睡大约 1 秒:hlt 一次 ≈ 一个 tick(10 ms)----
    mov ecx, 100
.wait:
    hlt
    loop .wait
    dec dword [rounds]                  ; 转够圈数就收工(见文件头的说明)
    jnz .loop
    mov bl, 0x0A                        ; 亮绿:回来了
    mov eax, 4
    int 0x30
    mov esi, msg_done
    call print
    ret                                 ; 直接 ret 就回 shell(api.asm 的约定)

; ---------------------------------------------------------------------------
;  print:esi = 以 0 结尾的字符串
; ---------------------------------------------------------------------------
print:
    mov eax, 0                          ; 功能 0 = 打印字符串
    int 0x30
    ret

; ---------------------------------------------------------------------------
;  print_dec:eax = 无符号数 → 打十进制
;  循环次数放内存里 —— int 0x30 回来时寄存器不保证还在,别指望 ecx
; ---------------------------------------------------------------------------
print_dec:
    mov ebx, 10
    mov dword [digits], 0
.divide:
    xor edx, edx
    div ebx
    push edx
    inc dword [digits]
    test eax, eax
    jnz .divide
.print:
    pop eax
    add eax, '0'
    mov ebx, eax                        ; 码位放 ebx
    mov eax, 3                          ; 功能 3 = 按码位打一个字符
    int 0x30
    dec dword [digits]
    jnz .print
    ret

counter dd 0
rounds  dd 0
digits  dd 0
HANG_ROUNDS equ 8                       ; 8 轮 ≈ 8 秒
msg_head db 'HANG.BIN: I am spinning for 8 seconds, this shell is stuck now.', 10, 0
msg_tick db 'still spinning... ', 0
msg_tail db '  (go to another shell with Ctrl+Right)', 10, 0
msg_done db 'HANG.BIN: done spinning, the shell is back.', 10, 0
