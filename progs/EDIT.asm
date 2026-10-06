; ============================================================================
;  EDIT.BIN — JoyOS 文本编辑器(用 int 0x30 写的"组件"之二)
;
;  用法:   run EDIT              编辑 NOTES.TXT
;          run EDIT MY.TXT       编辑指定文件(不存在就是新文件)
;          run EDIT NOTES.TXT    参数就是文件名(第 12 号功能取参数)
;
;  按键:
;          方向键 / Home / End / Delete / PgUp / PgDn     移动光标
;          字母数字符号 / 回车 / 退格                       编辑
;          Ctrl-S                                          存盘
;          Ctrl-F                                          查找(大小写不敏感,找不到绕回开头再找;
;                                                          提示里预填上次的词,回车 = 找下一个,
;                                                          退格删 / Ctrl-U 清空 / Esc 取消)
;          Ctrl-Q                                          退出(有改动会再问一次)
;
;  ── 文本怎么存 ──────────────────────────────────────────────────────────
;  一整块缓冲区(TEXT),里面就是一串普通字节,行与行之间用 '\n' 分隔 ——
;  和磁盘上的文本文件**一模一样**,所以读进来就能编辑、存回去就是文件本身。
;  光标用一个字节偏移(cursor)表示:插入 = 把后面那段往后挪一格,
;  删除 = 往前挪一格。8 KB 的文本这么干完全够用,而且逻辑一看就懂。
;
;  ── 屏幕怎么画 ──────────────────────────────────────────────────────────
;  全屏:第 0 行标题,最后一行状态/提示,中间是正文。
;  正文只画"看得见的那几行"(top 指向第一行),光标动完再保证它在可见范围内。
;  画一行用 int 0x30 的 13 号(在指定位置画 UTF-8 串,遇 '\n' 自动停、不滚屏)。
;
;  ★ 两个写全屏程序都会踩的坑(注释里都标了):
;    1. 入口必须是文件第一段代码 —— [ORG] 定的是第一个字节的地址,内核从那儿开始执行。
;       所以 api_* 那堆包装函数放在文件最后。
;    2. 终端是"覆盖写"不是"重画":一行新内容比旧的短时,旧字符会留在屏幕上,
;       必须自己用空格盖掉(见 fill_row)。
;
;  编译: nasm -f bin progs/EDIT.asm -o build/EDIT.BIN
; ============================================================================

[BITS 32]
[ORG 0x120000]

TEXT        equ 0x180000                ; 文本缓冲区(程序镜像在 0x120000,字库在 0x200000)
TEXT_MAX    equ 8192                    ; 8 KB:够写几千字
NAME        equ 0x17F000                ; 文件名(从程序参数抄过来)
NAME_MAX    equ 24
ROW_FIRST   equ 1                       ; 正文第一行
CURSOR_CHAR equ '_'                     ; 可见光标画什么字符(想换成 '|' 就改这一行)
CURSOR_ATTR equ 0x0A                    ; 光标颜色:亮绿(正文是 0x07 浅灰,一眼分得清)
FIND_MAX    equ 32                      ; 查找关键词最长几个字节(超了截断)

; ---------------------------------------------------------------------------
;  start:读参数 → 读文件 → 循环(取键 → 处理 → 重画)
; ---------------------------------------------------------------------------
start:
    call get_name
    call load_file
    call redraw
.main:
    call api_key                        ; eax = 键事件
    call handle_key
    call redraw
    cmp dword [quit_now], 0
    je .main
    ; ---- 收尾:擦干净屏幕,给 shell 留个干净的提示符 ----
    call api_clear
    mov bl, 0x0A
    call api_color
    mov esi, msg_bye
    call api_puts
    ret

; ---------------------------------------------------------------------------
;  get_name:参数(第 12 号功能)当文件名;没给就用 NOTES.TXT
; ---------------------------------------------------------------------------
get_name:
    mov eax, 12
    int 0x30                            ; → esi = 参数字符串
    cmp byte [esi], 0
    jne .have
    mov esi, def_name
.have:
    mov edi, NAME
    mov ecx, NAME_MAX - 1
.copy:
    lodsb
    test al, al
    jz .done
    cmp al, ' '                         ; 文件名到空格为止
    je .done
    mov [edi], al
    inc edi
    dec ecx
    jnz .copy
.done:
    mov byte [edi], 0
    ret

; ---------------------------------------------------------------------------
;  load_file:把文件读进 TEXT(第 7 号功能)。读不到就当新文件。
; ---------------------------------------------------------------------------
load_file:
    mov esi, NAME
    mov edi, TEXT
    mov ecx, TEXT_MAX - 1
    mov eax, 7
    int 0x30                            ; → eax = 字节数,-1 = 打不开(那就新建)
    cmp eax, -1
    je .empty
    mov [text_len], eax
    jmp .done
.empty:
    mov dword [text_len], 0
    mov dword [status], msg_new
.done:
    mov eax, [text_len]
    mov byte [TEXT + eax], 0            ; ★ 文本后面补个 0:不然画最后一行会画到垃圾
    mov dword [cursor], 0
    mov dword [top], 0
    mov dword [dirty], 0
    ret

; ---------------------------------------------------------------------------
;  save_file:把 TEXT 写回文件(第 8 号功能)
; ---------------------------------------------------------------------------
save_file:
    mov esi, NAME
    mov edi, TEXT
    mov ecx, [text_len]
    mov eax, 8
    int 0x30
    cmp eax, 0
    je .ok
    mov dword [status], msg_savefail
    ret
.ok:
    mov dword [dirty], 0
    mov dword [status], msg_saved
    ret

; ---------------------------------------------------------------------------
;  handle_key:eax = 键事件 → 改文本 / 存盘 / 退出
; ---------------------------------------------------------------------------
handle_key:
    cmp eax, 0x100
    jae .special                        ; 0x100 起是扩展键(方向键那一家)
    cmp al, 13                          ; 回车 = 插入换行
    je .enter
    cmp al, 8                           ; 退格
    je .backspace
    cmp al, 0x13                        ; Ctrl-S 存盘
    je .save
    cmp al, 0x06                        ; Ctrl-F 查找
    je .find
    cmp al, 0x11                        ; Ctrl-Q 退出(= 'q' - 'a' + 1 = 0x11,
    je .quit                            ;  ★ 不是 0x19 —— Ctrl-Q 和 Ctrl-Y 差一个字母)
    cmp al, 0x20
    jb .out                             ; 别的控制字符不管
    cmp al, 0x7E
    ja .out
    call insert_byte                    ; 普通字符:插进去
    jmp .dirty
.enter:
    mov al, 10
    call insert_byte
    jmp .dirty
.backspace:
    cmp dword [cursor], 0
    je .out
    dec dword [cursor]
    call skip_back
    call delete_at_cursor
    jmp .dirty
.save:
    call save_file
    ret
.find:
    call find_prompt                    ; 状态行上问关键词(上次的预先填好)
    cmp dword [find_go], 0
    je .out                             ; 取消 / 空关键词
    mov eax, [cursor]
    cmp dword [find_same], 0
    je .find_start
    inc eax                             ; 还是上次那个词 → 从下一个字节接着找
    cmp eax, [text_len]
    jbe .find_start
    xor eax, eax                        ; 光标已经在尾巴上 → 从头绕
.find_start:
    mov [find_start], eax
    call do_find
    ret
.quit:
    cmp dword [dirty], 0
    je .bye
    cmp dword [quit_again], 0
    jne .bye                            ; 第二次 Ctrl-Q:真退
    mov dword [quit_again], 1
    mov dword [status], msg_unsaved
    ret
.bye:
    mov dword [quit_now], 1
    ret
.dirty:
    mov dword [dirty], 1
    mov dword [status], 0               ; 一打字就把状态行恢复成提示
    mov dword [quit_again], 0
    ret
.out:
    ret

    ; ---- 扩展键:1 上 2 下 3 左 4 右 5 Home 6 End 7 Del 8 PgUp 9 PgDn ----
.special:
    sub eax, 0x100
    cmp eax, 1
    je .up
    cmp eax, 2
    je .down
    cmp eax, 3
    je .left
    cmp eax, 4
    je .right
    cmp eax, 5
    je .home
    cmp eax, 6
    je .end
    cmp eax, 7
    je .del
    cmp eax, 8
    je .pgup
    cmp eax, 9
    je .pgdn
    ret
.left:
    cmp dword [cursor], 0
    je .out
    dec dword [cursor]
    call skip_back                      ; 别停在 UTF-8 的半个字上
    ret
.right:
    mov eax, [cursor]
    cmp eax, [text_len]
    jae .out
    inc dword [cursor]
    call skip_forward
    ret
.up:
    mov eax, -1
    call move_line
    ret
.down:
    mov eax, 1
    call move_line
    ret
.home:
    mov eax, [cursor]
    call line_start
    mov [cursor], eax
    ret
.end:
    mov eax, [cursor]
    call line_end
    mov [cursor], eax
    ret
.del:
    mov eax, [cursor]
    cmp eax, [text_len]
    jae .out
    call delete_at_cursor
    mov dword [dirty], 1
    ret
.pgup:
    mov eax, -1
    call page_move
    ret
.pgdn:
    mov eax, 1
    call page_move
    ret

; ---------------------------------------------------------------------------
;  page_move:eax = -1 上翻一屏 / +1 下翻一屏(就是连按若干次上下)
; ---------------------------------------------------------------------------
page_move:
    pushad
    mov [mv_dir], eax
    mov ecx, [cr_full]
    sub ecx, 1
    jg .have
    mov ecx, 1
.have:
    mov [pg_steps], ecx
.loop:
    mov eax, [mv_dir]
    call move_line
    dec dword [pg_steps]
    jnz .loop
    popad
    ret

; ---------------------------------------------------------------------------
;  insert_byte:al 插到光标处(后面那段整体往后挪一格)
; ---------------------------------------------------------------------------
insert_byte:
    pushad
    mov [ins_byte], al
    mov eax, [text_len]
    cmp eax, TEXT_MAX - 1
    jae .full
    ; 从尾巴往前挪:buf[i+1] = buf[i](倒着搬,两段不会互相盖)
    mov ecx, eax
.shift:
    cmp ecx, [cursor]
    jbe .put
    mov al, [TEXT + ecx - 1]
    mov [TEXT + ecx], al
    dec ecx
    jmp .shift
.put:
    mov eax, [cursor]
    mov dl, [ins_byte]                  ; ★ 别写 al!eax 是地址,cursor 的低字节会被字符值顶掉
    mov [TEXT + eax], dl                ;   (踩过:光标在 15、字符是 'h'=104,结果写到了 TEXT+104,
    inc dword [text_len]                ;    原地留下一个 '\n' —— 表现是"打字打出来的全是空行")
    inc dword [cursor]
    jmp .done
.full:
    mov dword [status], msg_full
.done:
    mov eax, [text_len]
    mov byte [TEXT + eax], 0            ; 尾巴上的 0 跟着挪
    popad
    ret

; ---------------------------------------------------------------------------
;  delete_at_cursor:删掉光标处那个字节(后面那段往前挪一格)
; ---------------------------------------------------------------------------
delete_at_cursor:
    pushad
    mov ecx, [cursor]
    mov edx, [text_len]
.shift:
    inc ecx
    cmp ecx, edx
    jae .done
    mov al, [TEXT + ecx]
    mov [TEXT + ecx - 1], al
    jmp .shift
.done:
    dec dword [text_len]
    mov eax, [text_len]
    mov byte [TEXT + eax], 0
    popad
    ret

; ---------------------------------------------------------------------------
;  line_start:eax = 偏移 → 这一行开头(前一个 '\n' 之后的第一个字节)
; ---------------------------------------------------------------------------
line_start:
    push ebx
.loop:
    test eax, eax
    jz .done
    mov ebx, eax
    dec ebx
    cmp byte [TEXT + ebx], 10
    je .done
    dec eax
    jmp .loop
.done:
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  line_end:eax = 偏移 → 这一行结尾(下一个 '\n' 或文本末尾)
; ---------------------------------------------------------------------------
line_end:
    push ebx
.loop:
    mov ebx, [text_len]
    cmp eax, ebx
    jae .done
    cmp byte [TEXT + eax], 10
    je .done
    inc eax
    jmp .loop
.done:
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  next_line / prev_line:eax = 偏移 → 下一行 / 上一行的开头
; ---------------------------------------------------------------------------
next_line:
    push ebx
    call line_end
    mov ebx, [text_len]
    cmp eax, ebx
    jae .done                           ; 已经是最后一行
    inc eax                             ; 跳过 '\n'
.done:
    pop ebx
    ret

prev_line:
    push ebx
    call line_start
    test eax, eax
    jz .done                            ; 已经是第一行
    dec eax                             ; 退到上一行结尾的 '\n'
    call line_start
.done:
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  move_line:eax = -1 上移 / +1 下移,尽量停在"同一列"
; ---------------------------------------------------------------------------
move_line:
    pushad
    mov [mv_dir], eax
    mov eax, [cursor]
    call line_start
    mov ebx, [cursor]
    sub ebx, eax                        ; ebx = 光标在这一行里的列(字节)
    mov [mv_col], ebx

    mov eax, [cursor]
    cmp dword [mv_dir], 0
    jg .down
    call prev_line
    jmp .have
.down:
    call next_line
.have:
    mov [mv_lstart], eax
    call line_end                       ; eax = 这一行结尾
    mov ebx, [mv_lstart]
    sub eax, ebx                        ; eax = 这一行有多长
    mov ecx, [mv_col]
    cmp ecx, eax
    jbe .use
    mov ecx, eax                        ; 目标行短:停在行尾
.use:
    add ecx, ebx
    mov [cursor], ecx
    popad
    call ensure_visible
    ret

; ---------------------------------------------------------------------------
;  skip_back / skip_forward:别把光标停在 UTF-8 的"延续字节"上
;  (中文一个字符 3 字节,停在中间会把整行画乱)
; ---------------------------------------------------------------------------
skip_back:
    push eax
.loop:
    mov eax, [cursor]
    test eax, eax
    jz .done
    mov al, [TEXT + eax]
    and al, 0xC0
    cmp al, 0x80                        ; 10xxxxxx = 延续字节
    jne .done
    dec dword [cursor]
    jmp .loop
.done:
    pop eax
    ret

skip_forward:
    push eax
.loop:
    mov eax, [cursor]
    cmp eax, [text_len]
    jae .done
    mov al, [TEXT + eax]
    and al, 0xC0
    cmp al, 0x80
    jne .done
    inc dword [cursor]
    jmp .loop
.done:
    pop eax
    ret

; ---------------------------------------------------------------------------
;  line_index:eax = 偏移 → eax = 这是第几行(从 0 数)
; ---------------------------------------------------------------------------
line_index:
    push ebx
    push ecx
    mov ecx, eax
    xor eax, eax
    xor ebx, ebx
.loop:
    cmp ebx, ecx
    jae .done
    cmp byte [TEXT + ebx], 10
    jne .next
    inc eax
.next:
    inc ebx
    jmp .loop
.done:
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  ensure_visible:让光标那一行落在正文区里(不然视图跟着滚)
; ---------------------------------------------------------------------------
ensure_visible:
    pushad
    mov eax, [cursor]
    call line_index
    mov [cv_line], eax                  ; 光标在第几行
    mov eax, [top]
    call line_index
    mov [cv_top], eax                   ; 视图第一行是第几行
    mov ebx, [cr_full]

    mov eax, [cv_line]
    cmp eax, [cv_top]
    jae .below
    ; 光标跑到视图上面了 → 视图改成从光标这行开始
    mov eax, [cursor]
    call line_start
    mov [top], eax
    jmp .done

.below:
    mov ecx, [cv_line]
    sub ecx, [cv_top]                   ; 光标在视图里第几行(0 起)
    cmp ecx, ebx
    jb .done                            ; 还在可见范围内
    sub ecx, ebx
    inc ecx                             ; 要往下挪几行
    mov eax, [top]
.roll:
    push ecx
    call next_line
    pop ecx
    dec ecx
    jnz .roll
    mov [top], eax
.done:
    popad
    ret

; ---------------------------------------------------------------------------
;  查找(Ctrl-F)——
;  这里用"最笨但一看就懂"的做法:关键词就存在 find_buf 里(最长 FIND_MAX 字节),
;  从头到尾一个字节一个字节地对,大小写不敏感(字母都先转成大写再比)。
;  不做正则、不跳词、不关心边界 —— 教科书上的朴素匹配,8 KB 文本扫一遍不要 1 毫秒。
; ---------------------------------------------------------------------------

; ---------------------------------------------------------------------------
;  find_prompt:状态行显示 'find: ',让用户敲关键词
;              → [find_go]   = 1 有词可查 / 0 = 取消(空词或 Esc)
;              → [find_same] = 1 和上次的关键词一样(那就找下一个)
;  上次的词预先填在提示里:直接回车 = 沿用旧词找下一个。
; ---------------------------------------------------------------------------
find_prompt:
    pushad
    mov dword [find_go], 0
    mov dword [find_same], 0
    mov esi, find_buf                   ; 上次的词先摆出来
    mov edi, find_edit
    call str_copy
    mov edi, find_edit
    call str_len
    mov [find_len], eax
.loop:
    call draw_findline
    call api_key                        ; eax = 键事件
    cmp eax, 0x100
    jae .loop                           ; 方向键那一家在提示里不认
    cmp al, 13                          ; 回车 = 就用这个词
    je .enter
    cmp al, 27                          ; ESC = 取消(第 10 号把 ESC 当 27 送上来)
    je .done
    cmp al, 8                           ; 退格
    je .back
    cmp al, 0x15                        ; Ctrl-U:把预填的旧词清掉重打
    je .clear
    cmp al, 0x20
    jb .loop                            ; 别的控制键(Ctrl-S/Ctrl-Q…)不抢
    cmp al, 0x7E
    ja .loop
    mov ecx, [find_len]
    cmp ecx, FIND_MAX
    jae .loop                           ; 到上限了:多敲的字符丢掉(截断)
    mov edi, find_edit
    add edi, ecx
    mov [edi], al
    inc edi
    mov byte [edi], 0
    inc dword [find_len]
    jmp .loop
.back:
    cmp dword [find_len], 0
    je .loop
    dec dword [find_len]
    mov ecx, [find_len]
    mov byte [find_edit + ecx], 0
    jmp .loop
.clear:
    mov dword [find_len], 0
    mov byte [find_edit], 0
    jmp .loop
.enter:
    cmp dword [find_len], 0
    je .done                            ; 空关键词 = 取消
    mov esi, find_edit
    mov edi, find_buf
    call str_eq                         ; 和上次是同一个词吗?
    mov [find_same], eax
    mov esi, find_edit                  ; 记住这次的关键词,下次好预填
    mov edi, find_buf
    call str_copy
    mov dword [find_go], 1
.done:
    mov dword [status], 0               ; 提示行交回 redraw 去画
    popad
    ret

; ---------------------------------------------------------------------------
;  draw_findline:状态行画 'find: ' + 已输入的关键词 + 一个光标
; ---------------------------------------------------------------------------
draw_findline:
    pushad
    mov edi, row_buf
    mov esi, msg_find
    call str_copy
    mov esi, find_edit
    call str_copy
    call fill_row
    mov bl, 0x0B                        ; 亮青(和状态行的亮黄分开)
    call api_color
    mov esi, row_buf
    mov ebx, [cr_rows]
    dec ebx                             ; 最后一行
    xor ecx, ecx
    mov edx, [cr_width]
    call api_put_at

    mov edi, msg_find                   ; 关键词从第几格开始:'find: ' 的长度
    call str_len
    add eax, [find_len]
    mov [find_col], eax
    mov bl, CURSOR_ATTR
    call api_color
    mov esi, cursor_str
    mov ebx, [cr_rows]
    dec ebx
    mov ecx, [find_col]
    mov edx, [cr_width]
    call api_put_at

    mov ebx, [cr_rows]                  ; 硬件光标也跟过去
    dec ebx
    mov ecx, [find_col]
    mov eax, 9
    int 0x30
    popad
    ret

; ---------------------------------------------------------------------------
;  do_find:从 [find_start] 往后找 find_buf,找不到就**绕回开头再找一轮**
;          (两轮扫完才算 not found)。找到 → 光标跳过去、那一行滚到可见区。
; ---------------------------------------------------------------------------
do_find:
    pushad
    mov eax, [find_start]
    mov ecx, [text_len]
    call find_scan
    cmp eax, -1
    jne .hit
    xor eax, eax                        ; 绕回开头:再扫一遍 [0, find_start)
    mov ecx, [find_start]
    call find_scan
    cmp eax, -1
    jne .hit
    mov dword [status], msg_notfound    ; 两轮都没有 → 人话提示
    popad
    ret
.hit:
    mov [cursor], eax
    call ensure_visible                 ; 匹配那一行要在屏幕上(光标才看得见)
    mov dword [status], 0
    popad
    ret

; ---------------------------------------------------------------------------
;  find_scan:eax = 起始偏移,ecx = 扫到哪儿为止(不含)→ eax = 匹配偏移,-1 = 没有
;            大小写不敏感:字母两边都先转大写再比
; ---------------------------------------------------------------------------
find_scan:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov edi, eax                        ; edi = 现在对到哪个字节
    mov esi, ecx                        ; esi = 扫到哪儿为止
.next_pos:
    mov ecx, [find_len]
    test ecx, ecx
    jz .miss                            ; 空词:永远不匹配
    lea eax, [edi + ecx]
    cmp eax, esi
    ja .miss                            ; 剩下的地方已经放不下整个词
    xor edx, edx
.cmp:
    mov al, [TEXT + edi + edx]
    mov bl, [find_buf + edx]
    call up_al
    call up_bl
    cmp al, bl
    jne .no
    inc edx
    cmp edx, ecx
    jb .cmp
    mov eax, edi                        ; 命中
    jmp .out
.no:
    inc edi
    jmp .next_pos
.miss:
    mov eax, -1
.out:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  up_al / up_bl:al / bl 里的小写字母转成大写(查找不分大小写就靠这两下)
; ---------------------------------------------------------------------------
up_al:
    cmp al, 'a'
    jb .done
    cmp al, 'z'
    ja .done
    sub al, 0x20
.done:
    ret

up_bl:
    cmp bl, 'a'
    jb .done
    cmp bl, 'z'
    ja .done
    sub bl, 0x20
.done:
    ret

; ---------------------------------------------------------------------------
;  str_len:edi = 串 → eax = 长度(不算结尾的 0)
; ---------------------------------------------------------------------------
str_len:
    push edi
    xor eax, eax
.loop:
    cmp byte [edi], 0
    je .done
    inc edi
    inc eax
    jmp .loop
.done:
    pop edi
    ret

; ---------------------------------------------------------------------------
;  str_eq:esi / edi 两个 0 结尾的串 → eax = 1 一模一样 / 0 不一样
; ---------------------------------------------------------------------------
str_eq:
    push ebx
    push esi
    push edi
.loop:
    mov al, [esi]
    mov bl, [edi]
    cmp al, bl
    jne .diff
    test al, al
    jz .same
    inc esi
    inc edi
    jmp .loop
.diff:
    xor eax, eax
    jmp .out
.same:
    mov eax, 1
.out:
    pop edi
    pop esi
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  redraw:整屏重画(标题 / 正文 / 状态行 / 光标)
; ---------------------------------------------------------------------------
redraw:
    pushad
    call api_size                       ; → eax = 列数,ebx = 行数
    mov [cr_cols], eax
    mov [cr_rows], ebx
    mov ecx, eax
    dec ecx
    mov [cr_width], ecx                 ; 每行最多画这么多格(最后一格留着)
    mov ecx, ebx
    sub ecx, 2                          ; 去掉标题行和状态行
    jg .few
    mov ecx, 1
.few:
    mov [cr_full], ecx
    call ensure_visible                 ; ★ 光标那一行必须在正文区里(打字打到屏幕底、
                                        ;   回车换行、PgDn 之后都靠它把视图滚上来)

    call api_clear

    ; ---- 标题行:编辑器名 + 文件名 + [modified] ----
    mov edi, row_buf
    mov esi, msg_title
    call str_copy
    mov esi, NAME
    call str_copy
    cmp dword [dirty], 0
    je .no_mark
    mov esi, msg_mod
    call str_copy
.no_mark:
    call fill_row
    mov bl, 0x0C                        ; 亮红
    call api_color
    mov esi, row_buf
    xor ebx, ebx                        ; 第 0 行
    xor ecx, ecx
    mov edx, [cr_cols]
    call api_put_at

    ; ---- 正文:从 top 开始一行一行画 ----
    mov bl, 0x07                        ; 浅灰
    call api_color
    mov eax, [top]
    mov [draw_off], eax
    mov dword [draw_row], ROW_FIRST
.lines:
    mov eax, [draw_row]
    mov ecx, [cr_full]
    add ecx, ROW_FIRST
    cmp eax, ecx
    jae .status                         ; 正文区画满了
    mov esi, TEXT
    add esi, [draw_off]
    mov ebx, [draw_row]
    xor ecx, ecx
    mov edx, [cr_width]
    mov eax, 13
    int 0x30
    mov eax, [draw_off]
    call next_line
    mov [draw_off], eax
    mov eax, [text_len]
    cmp [draw_off], eax
    ja .status                          ; 文本到头了
    inc dword [draw_row]
    jmp .lines

    ; ---- 状态行:有话说就说,没话说给提示 ----
.status:
    mov edi, row_buf
    mov esi, [status]
    test esi, esi
    jnz .have_status
    mov esi, msg_help
.have_status:
    call str_copy
    call fill_row
    mov bl, 0x0E                        ; 亮黄
    call api_color
    mov esi, row_buf
    mov ebx, [cr_rows]
    dec ebx                             ; 最后一行
    xor ecx, ecx
    mov edx, [cr_cols]
    call api_put_at

    ; ---- 光标:放到真正的位置上 ----
    mov eax, [cursor]
    call line_index
    mov ecx, eax
    mov eax, [top]
    call line_index
    sub ecx, eax                        ; 光标相对视图第几行
    add ecx, ROW_FIRST
    mov [cur_row], ecx

    mov eax, [cursor]
    call cell_column                    ; → eax = 第几个字符格
    mov [cur_col], eax

    ; ---- 可见光标:在光标那一格画一个亮色的 CURSOR_CHAR ----
    ;  屏幕是"整屏重画"的:每敲一个键都 api_clear 再从头画一遍,所以光标离开旧
    ;  位置时,那个格子会被正文本身(或空格)重新盖回去 —— 恢复是白送的,不用记账。
    ;  但**越界不能画**:光标行不在正文区、或者那一格被长行挤到屏幕外就不画,
    ;  不然会画到标题/状态行上,或者顶到最后一格触发滚屏,把界面弄花。
    mov eax, [cur_row]
    cmp eax, ROW_FIRST
    jb .no_cursor
    mov ecx, [cr_full]
    add ecx, ROW_FIRST
    cmp eax, ecx
    jae .no_cursor
    mov eax, [cur_col]
    cmp eax, [cr_width]
    jae .no_cursor                      ; 这一格在屏幕外(行太长),画了也是花屏
    mov bl, CURSOR_ATTR
    call api_color
    mov esi, cursor_str
    mov ebx, [cur_row]
    mov ecx, [cur_col]
    mov edx, [cr_width]                 ; 第 13 号的"最多几格"是**绝对列号**
    call api_put_at
.no_cursor:

    mov ebx, [cur_row]                  ; 硬件光标也摆过去(第 9 号:超界会自己夹住)
    mov ecx, [cur_col]
    mov eax, 9
    int 0x30

    popad
    ret

; ---------------------------------------------------------------------------
;  cell_column:eax = 偏移 → 这一行里的第几个字符格(ASCII 一格,宽字两格)
; ---------------------------------------------------------------------------
cell_column:
    push ebx
    push ecx
    push edx
    mov edx, eax                        ; 目标偏移
    call line_start
    xor ecx, ecx                        ; ecx = 格数
.loop:
    cmp eax, edx
    jae .done
    mov bl, [TEXT + eax]
    inc eax
    cmp bl, 0x80
    jb .one
    and bl, 0xC0
    cmp bl, 0x80
    je .loop                            ; 延续字节:不占新格子
    add ecx, 2                          ; 多字节字符按两格算(汉字 16 像素宽)
    jmp .loop
.one:
    inc ecx
    jmp .loop
.done:
    mov eax, ecx
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------------
;  fill_row:edi = 现在的结尾 → 把 row_buf 补满空格
;  (终端只覆盖写:新内容比旧的短时,旧字符会留在屏幕上 —— 必须自己盖掉)
; ---------------------------------------------------------------------------
fill_row:
    push eax
    push ecx
    mov eax, edi
    sub eax, row_buf
    mov ecx, [cr_width]
    sub ecx, eax
    jle .done
.fill:
    mov byte [edi], ' '
    inc edi
    dec ecx
    jnz .fill
.done:
    mov byte [edi], 0
    pop ecx
    pop eax
    ret

; ---------------------------------------------------------------------------
;  str_copy:esi → edi(edi 前进)
; ---------------------------------------------------------------------------
str_copy:
    push eax
.loop:
    mov al, [esi]
    test al, al
    jz .done
    mov [edi], al
    inc esi
    inc edi
    jmp .loop
.done:
    pop eax
    ret

; ---------------------------------------------------------------------------
;  int 0x30 的包装 —— 见文件头坑 1:它们必须在入口之后(入口 = 第一个字节)
; ---------------------------------------------------------------------------
api_clear:
    mov eax, 6
    int 0x30
    ret
api_puts:
    mov eax, 0
    int 0x30
    ret
api_color:
    mov eax, 4
    int 0x30
    ret
api_key:
    mov eax, 10
    int 0x30
    ret
api_size:
    mov eax, 11
    int 0x30
    ret
api_put_at:
    mov eax, 13
    int 0x30
    ret

; ---------------------------------------------------------------------------
;  数据
; ---------------------------------------------------------------------------
def_name     db 'NOTES.TXT', 0
msg_title    db 'JoyOS editor  ---  ', 0
msg_mod      db '   [modified]', 0
msg_help     db 'Ctrl-S save  Ctrl-Q quit  Ctrl-F find  arrows/Home/End/Del  PgUp/PgDn', 0
msg_new      db 'new file (Ctrl-S saves it)', 0
msg_saved    db 'saved to disk', 0
msg_savefail db 'SAVE FAILED (disk full or no FAT16?)', 0
msg_unsaved  db 'unsaved changes!  press Ctrl-Q again to quit anyway', 0
msg_full     db 'file is full (8 KB max)', 0
msg_find     db 'find: ', 0
msg_notfound db 'not found (searched to the end, then wrapped around)', 0
msg_bye      db 'editor closed.', 10, 0
cursor_str   db CURSOR_CHAR, 0          ; 可见光标画的那个字符(13 号接口要 0 结尾串)

text_len    dd 0
cursor      dd 0
top         dd 0
dirty       dd 0
quit_now    dd 0
quit_again  dd 0
status      dd 0
cr_cols     dd 80
cr_rows     dd 25
cr_width    dd 79
cr_full     dd 23
draw_off    dd 0
draw_row    dd 0
cur_row     dd 0
cur_col     dd 0
ins_byte    db 0
mv_dir      dd 0
mv_col      dd 0
mv_lstart   dd 0
pg_steps    dd 0
cv_line     dd 0
cv_top      dd 0
find_buf    times FIND_MAX + 1 db 0     ; 上次用的关键词(回车直接沿用 → 找下一个)
find_edit   times FIND_MAX + 1 db 0     ; 正在提示行里敲的关键词
find_len    dd 0
find_col    dd 0
find_go     dd 0                        ; 1 = 有词可查 / 0 = 取消
find_same   dd 0                        ; 1 = 和上次同一个词(从光标下一个字节接着找)
find_start  dd 0                        ; 这一轮从哪个偏移开始找
row_buf     times 256 db 0
