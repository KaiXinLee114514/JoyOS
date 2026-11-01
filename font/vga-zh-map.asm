; ============================================================
;  汉字 → VGA 字模号 映射表   **自动生成,别手改**
;  生成: python3 tools/unifont2bin.py --hex ... --vga-font ... --vga-map 本文件
;  每个汉字占两个相连的字符码(左半边 = 表里的号,右半边 = 号+1)
; ============================================================
vga_zh_count equ 55

vga_zh_map:
    dd 0x000080E1        ; 胡
    db 0x80
    dd 0x000095F9        ; 闹
    db 0x82
    dd 0x00004F60        ; 你
    db 0x84
    dd 0x0000597D        ; 好
    db 0x86
    dd 0x00004E16        ; 世
    db 0x88
    dd 0x0000754C        ; 界
    db 0x8A
    dd 0x00008FD9        ; 这
    db 0x8C
    dd 0x0000662F        ; 是
    db 0x8E
    dd 0x00007684        ; 的
    db 0x90
    dd 0x00004E2D        ; 中
    db 0x92
    dd 0x00006587        ; 文
    db 0x94
    dd 0x0000663E        ; 显
    db 0x96
    dd 0x0000793A        ; 示
    db 0x98
    dd 0x000070B9        ; 点
    db 0x9A
    dd 0x00009635        ; 阵
    db 0x9C
    dd 0x00006765        ; 来
    db 0x9E
    dd 0x000081EA        ; 自
    db 0xA0
    dd 0x00005B57        ; 字
    db 0xA2
    dd 0x00005E93        ; 库
    db 0xA4
    dd 0x0000672C        ; 本
    db 0xA6
    dd 0x00006A21        ; 模
    db 0xA8
    dd 0x00005F0F        ; 式
    db 0xAA
    dd 0x00004E0B        ; 下
    db 0xAC
    dd 0x00007528        ; 用
    db 0xAE
    dd 0x00004E24        ; 两
    db 0xB0
    dd 0x00004E2A        ; 个
    db 0xB2
    dd 0x0000683C        ; 格
    db 0xB4
    dd 0x000062FC        ; 拼
    db 0xB6
    dd 0x00006210        ; 成
    db 0xB8
    dd 0x00004E00        ; 一
    db 0xBA
    dd 0x00005171        ; 共
    db 0xBC
    dd 0x0000585E        ; 塞
    db 0xBE
    dd 0x00008FDB        ; 进
    db 0xC0
    dd 0x00005C4F        ; 屏
    db 0xC2
    dd 0x000090FD        ; 都
    db 0xC4
    dd 0x000051FA        ; 出
    db 0xC6
    dd 0x00009EC4        ; 黄
    db 0xC8
    dd 0x00004EBA        ; 人
    db 0xCA
    dd 0x00005DF2        ; 已
    db 0xCC
    dd 0x00004E58        ; 乘
    db 0xCE
    dd 0x000053BB        ; 去
    db 0xD0
    dd 0x0000FF0C        ; ，
    db 0xD2
    dd 0x00006B64        ; 此
    db 0xD4
    dd 0x00005730        ; 地
    db 0xD6
    dd 0x00003002        ; 。
    db 0xD8
    dd 0x00004E0D        ; 不
    db 0xDA
    dd 0x0000767D        ; 白
    db 0xDC
    dd 0x00005343        ; 千
    db 0xDE
    dd 0x00006C49        ; 汉
    db 0xE0
    dd 0x000065E5        ; 日
    db 0xE2
    dd 0x00005173        ; 关
    db 0xE4
    dd 0x00004E0A        ; 上
    db 0xE6
    dd 0x00004F7F        ; 使
    db 0xE8
    dd 0x0000FF1A        ; ：
    db 0xEA
    dd 0x0000FF01        ; ！
    db 0xEC
