; ============================================================================
;  JoyOS — ELF32 可执行文件装载器(给 TCC 编出来的程序用)
;
;  内核原来的 run 只认"平铺 BIN"(链接地址 0x120000,文件内容就是内存镜像)。
;  TCC 只能产出 ELF,所以这里把它"展开"成平铺镜像放回暂存区:
;
;    1. shell 已经把整个 ELF 文件读进 PROG_ADDR(0x120000) 暂存;
;    2. 本模块扫 program header(PT_LOAD):
;         p_filesz 字节从文件拷到 p_vaddr;
;         p_memsz-p_filesz 字节清零(.bss);
;    3. 返回展开后的 flat 大小(给 space_set_image)和入口 e_entry。
;
;  为什么先搬一份到页池临时区:ELF 的段目标地址 vaddr 也从 0x120000 起,
;  源文件同样在 0x120000 —— 原地展开会自己盖自己。所以先把文件 memcpy 到
;  页池临时区,再往 PROG_ADDR 铺。页池空(内存太小)或格式不对就返回 0,
;  由 shell 报错,不会把内核带崩。
;
;  elf_load:
;    输入: esi = 暂存区地址(ELF 文件), eax = 文件字节数
;    输出: eax = 展开后的镜像字节数(0 = 失败), edx = 程序入口(失败时 0)
;    其余寄存器不保证
; ============================================================================

[BITS 32]

SPACE_IMG_VA    equ 0x120000
SPACE_IMG_PAGES equ 0x60                    ; 和 paging.asm 保持一致

global elf_load

section .text
elf_load:
    pushad
    mov [elf_src], esi
    mov [elf_len], eax

    ; ---- 基本格式检查:魔数、32 位、小端 ----
    cmp dword [esi], 0x464C457F             ; "\x7fELF"
    jne .bad
    cmp byte [esi + 4], 1                   ; EI_CLASS = ELFCLASS32
    jne .bad
    cmp byte [esi + 5], 1                   ; EI_DATA = little endian
    jne .bad

    mov eax, [esi + 24]                     ; e_entry
    mov [elf_entry], eax
    mov eax, [esi + 28]                     ; e_phoff
    mov [elf_phoff], eax
    movzx eax, word [esi + 42]              ; e_phentsize
    test eax, eax
    jz .bad
    mov [elf_phentsize], eax
    movzx eax, word [esi + 44]              ; e_phnum
    test eax, eax
    jz .bad
    mov [elf_phnum], eax

    ; ---- 第一遍:算镜像总大小(所有 PT_LOAD 的 p_vaddr+p_memsz 最大值) ----
    xor ebx, ebx                            ; ebx = 最高末端(绝对地址)
    mov ecx, [elf_phnum]
    mov edi, [elf_src]
    add edi, [elf_phoff]
.ph_scan:
    cmp dword [edi], 1                      ; PT_LOAD
    jne .ph_scan_next
    mov eax, [edi + 8]                      ; p_vaddr
    add eax, [edi + 20]                     ; + p_memsz
    cmp eax, ebx
    jbe .ph_scan_next
    mov ebx, eax
.ph_scan_next:
    add edi, [elf_phentsize]
    dec ecx
    jnz .ph_scan

    cmp ebx, SPACE_IMG_VA
    jbe .bad                                ; 空镜像
    mov eax, ebx
    sub eax, SPACE_IMG_VA
    mov [elf_flat_size], eax
    cmp eax, (SPACE_IMG_PAGES - 1) * 4096   ; 最后一页留给 ring 3 弹床
    ja .bad

    ; 入口必须落在镜像范围内
    mov eax, [elf_entry]
    cmp eax, SPACE_IMG_VA
    jb .bad
    mov edx, SPACE_IMG_VA
    add edx, [elf_flat_size]
    cmp eax, edx
    jae .bad

    ; ---- 把 ELF 文件搬一份到页池临时区(源和目标重叠) ----
    mov eax, [elf_len]
    add eax, 4095
    shr eax, 12
    test eax, eax
    jz .bad
    mov [elf_tmp_pages], eax
    mov ecx, eax
    call pmem_alloc_pages
    test eax, eax
    jz .bad
    mov [elf_tmp], eax
    mov edi, eax
    mov esi, [elf_src]
    mov ecx, [elf_len]
    rep movsb

    ; ---- 展开区先整体清零(段内容随后覆盖) ----
    mov edi, SPACE_IMG_VA
    mov ecx, [elf_flat_size]
    xor eax, eax
    rep stosb

    ; ---- 第二遍:逐个 PT_LOAD 拷贝段 + 清 .bss ----
    ; 注意:上面 zeros 已经从头铺平了 0x120000 展开区,原来的 ELF 文件头/程序头
    ; 都被覆盖了;第二遍要读程序头,只能读搬进临时区的那份副本。
    mov ebp, [elf_phnum]
    mov eax, [elf_tmp]
    add eax, [elf_phoff]
    mov [elf_ph], eax
.ph_copy:
    mov edi, [elf_ph]
    cmp dword [edi], 1
    jne .ph_copy_next
    ; 源 = tmp + p_offset
    mov esi, [elf_tmp]
    add esi, [edi + 4]
    ; 目标 = p_vaddr
    mov edi, [edi + 8]
    ; 拷贝 p_filesz 字节
    mov ebx, [elf_ph]
    mov ecx, [ebx + 16]
    rep movsb
    ; 清 (p_memsz - p_filesz) 的 .bss
    mov ebx, [elf_ph]
    mov ecx, [ebx + 20]
    sub ecx, [ebx + 16]
    jbe .ph_copy_next
    xor eax, eax
    rep stosb
.ph_copy_next:
    mov eax, [elf_phentsize]
    add [elf_ph], eax
    dec ebp
    jnz .ph_copy

    ; ---- 归还临时页,返回结果 ----
    mov eax, [elf_tmp]
    mov ecx, [elf_tmp_pages]
    call pmem_free_pages
    mov eax, [elf_flat_size]
    mov [elf_out_size], eax
    mov eax, [elf_entry]
    mov [elf_out_entry], eax
    popad
    mov eax, [elf_out_size]
    mov edx, [elf_out_entry]
    ret

.bad:
    popad
    xor eax, eax
    xor edx, edx
    ret

; ---------------------------------------------------------------------------
;  模块内变量(平铺内核镜像,直接放在代码段后面,随内核一起加载)
; ---------------------------------------------------------------------------
elf_src         dd 0
elf_len         dd 0
elf_entry       dd 0
elf_phoff       dd 0
elf_phnum       dd 0
elf_phentsize   dd 0
elf_flat_size   dd 0
elf_tmp         dd 0
elf_tmp_pages   dd 0
elf_ph          dd 0
elf_out_size    dd 0
elf_out_entry   dd 0
