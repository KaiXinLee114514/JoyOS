# 5 分钟上手:用纯 C 给 JoyOS 写个程序

**你不会碰到一行汇编。** `main()` 里想写什么写什么,`printf`、`argv`、文件读写都有。

## 0. 先准备(一次性)

```bash
sudo apt install gcc-multilib nasm qemu-system-x86 python3   # Debian/Ubuntu
git clone https://github.com/KaiXinLee114514/JoyOS.git && cd JoyOS
make            # 编出内核和镜像(第一次要一会儿)
```

## 1. 写个 C 文件

`sdk/examples/hello.c` 就是现成模板,复制一份改:

```c
#include <stdio.h>
#include <joyos.h>

int main(void)
{
    j_color(JOY_LCYAN);
    printf("hello from C!\n");
    j_color(JOY_GREY);
    printf("你给我的参数是:%s\n", j_arg());
    return 0;
}
```

## 2. 编 + 跑(两条命令)

```bash
bin/joyos-cc myprog.c -o MYPROG.BIN     # 纯 C → JoyOS 的平铺二进制
bin/joyos-run MYPROG.BIN                # 造镜像 + 开 QEMU
```

窗口里敲 `run MYPROG` —— 你的程序就在自己写的系统里跑了。
`bin/joyos-run myprog.c` 一步到位(它自己会先调 `joyos-cc`)。

## 3. 能用的东西

| 头文件 | 里面有什么 |
|---|---|
| `<joyos.h>` | 屏幕/键盘/文件/参数的包装:`j_print` `j_color` `j_clear` `j_goto` `j_key` `j_event` `j_read_file` `j_write_file` `j_screensize` `j_arg` `j_puts_at` `j_beep`,调色板 `JOY_RED` 这类,方向键码 `JOY_KEY_UP` 这类 |
| `<stdio.h>` | `printf` `puts` `putchar` `getchar`(迷你实现,支持 `%d %x %s %c %u`,**没有** `%f`) |
| `<string.h>` `<stdlib.h>` `<ctype.h>` | `memcpy` `strlen` `strcmp` `malloc` `free` `atoi` … |
| `<malloc.h>` | `malloc/free`(堆在 0x1A0000–0x1EFFFF) |

文件接口**支持路径**,而且相对"当前目录":`j_read_file("DOCS/NOTE.TXT", buf, sizeof buf)`。

## 4. 几个必须知道的边界(没权限模型,内核信任你)

* 程序加载在 **0x120000**,入口就是第一个字节(链接脚本已经管好了);
* 你的代码/数据、参数块、堆区随便用;**别去写** 0x10000–0x30000(内核)、0x100000/0x110000(内核缓冲)、0x200000(字库);
* **4 MiB 以上是内核的物理页池**(0x400000–0xFFFFFF,页表就是从这里发的),程序别去碰 ——
  被 `malloc` 出来的内存都在 0x1A0000–0x1EFFFF,不用你操心;
* `ret` 回 shell = 程序结束;别关中断(`cli`),不然系统会失去时钟;
* 程序写坏了别人的内存没人拦得住 —— 这是"胡闹 OS",不是 Linux。

## 5. 常见问题

| 现象 | 原因 |
|---|---|
| `file not found` | 文件名在系统里是 8.3 大写形式(`MYPROG.BIN`),`run myprog` 也行(会自动补 `.BIN`) |
| 编译报 `-m32` 相关错 | 没装 `gcc-multilib` |
| 屏幕上中文是 `?` | 你按 Alt 看的是 ASCII 区;中文能显示(得字库在盘上,`make hd` 的镜像里有) |
| 想跑扩展(比如 vi) | `make ext-img && make run-ext`,那是可选玩具,不在默认镜像里 |
| `run PLAY` 一点声音都没有 | QEMU 7+ 要给 PC 蜂鸣器接音频后端:`-machine pcspk-audiodev=snd0 -audiodev pa,id=snd0`(见下面第 8 节);VirtualBox 不仿真 PC 扬声器,那边听不见 |
| 音高对、节奏偏快/偏慢 | 音高是 PIT 硬件定的(准),**时值是忙等估的**:`kernel/speaker.asm` 里的 `SPKR_LOOPS_PER_MS`,换台机器/开 KVM 会差几倍,改那一个数就行 |

## 6. 别人怎么加"扩展"

源码丢进 `extensions/<名字>/`,Makefile 的 `EXT_BINS` 加一行,`make ext` 就编它。
规矩见 `extensions/README.md`:**扩展不许拖累主线**,挂了也不能影响 `make test`。

## 7. 用键盘打中文(Alt 码位输入)

键盘只认 ASCII?按住 **左 Alt**,在小键盘/主键盘上敲**十进制码位**,松开 Alt ——
那个字符就作为 UTF-8 打进当前程序(编辑器、`write`、shell 都吃):

| 想打 | 敲 |
|---|---|
| 中 | 按 Alt + `20013`,松开 |
| 好 | 按 Alt + `22909`,松开 |
| 😀 | 按 Alt + `128512`,松开(4 字节 UTF-8,能画出来就画) |

* 码位就是 Unicode 编号(十进制):`中` = U+4E2D = 20013;
* 松开 Alt 之前敲了别的键 = 取消那一次输入;
* Alt 期间的数字**不会**回显,松开就出字;
* 前提是字库在盘上(`make hd` 的镜像有,4 万个字形)—— 不然只能显示内置的 ASCII
  子集,中文会变成方块。

## 8. 让 JoyOS 唱歌:蜂鸣器 + 文本谱

内核多了 **14 号功能 `beep`**(C 里就是 `j_beep(freq_hz, ms)`),`progs/PLAY.C` 拿它当播放器:
谱子是 FAT 上的**纯文本**,不用重新编译任何东西,`run EDIT MYSONG.TXT` 改两行就能换一首。

> **播放器在,但默认不带示例谱 —— 谱要自己写。**
> 镜像根目录里没有现成的曲谱:照下面 8.2 的格式敲几行就有歌听。
> (PC 喇叭是方波、没有音量控制,全音量太吵,示例谱就撤了 —— 自己写能挑个安静点的曲子。)

### 8.1 先让它响

```bash
make hd          # 或者只做镜像:make -s build/joyos-hd.img
# ★ QEMU 7 以后,PC 蜂鸣器必须显式接一个音频后端,不然一点声音都没有:
# ★ 方波没有音量控制、全音量很刺耳 —— 用 out.stream-name 给这条流起个名,
#   好在宿主混音器里认出它、单独调小(见下面第一条),先调小再听:
qemu-system-i386 -machine pcspk-audiodev=snd0 -audiodev pa,id=snd0,out.stream-name=JoyOS \
    -drive file=build/joyos-hd.img,format=raw,if=ide,index=0 -boot c
```

窗口里敲(谱子得自己写,格式见 8.2):

```
> run PLAY MYSONG.TXT        ← 按谱播放
> run PLAY --list MYSONG.TXT ← 只解析、把谱子打到屏幕上(不出声,改谱时拿它对答案)
```

* **怎么让蜂鸣器别吵**:PC 喇叭是方波,**硬件没有音量控制**(`0x61` 那两位只有
  "响 / 不响"),所以音量只能在宿主侧调 —— 直接调低系统音量,或者在宿主混音器
  (`wpctl` / `pavucontrol`)里把 QEMU 那条流单独调小(上面用 `out.stream-name=JoyOS`
  给它起了个认得出的名字,不然一堆 `qemu-system-i386` 分不清谁是谁);
* ★ **`-audiodev` 里没有 `out.volume=` 这个参数**:网上能搜到这种写法,但 QEMU 会直接
  拒绝启动(`Parameter 'out.volume' is unexpected`,本机 QEMU 10.0.11 实测;上游 QAPI
  的 `AudiodevPerDirectionOptions` 里只有 frequency / channels / voices / format /
  buffer-length / mixing-engine)。别拿它当音量旋钮 —— 宿主混音器才是;
* **一点声都不想出**:把后端换成 `-audiodev wav,id=snd0,path=/tmp/joy.wav`(只录不响,
  还能拿录音核对音准),或者 `-audiodev none,id=snd0`(什么都不接);
* `-audiodev pa,id=snd0` 是 PipeWire/PulseAudio 宿主上的写法(老 QEMU 的 `pa` 后端同名);
  没声音先看 QEMU 有没有报 audio 的错,或者先试 `-audiodev none,id=snd0`(至少不报错);
* **VirtualBox 不仿真 PC 扬声器**,在那边是听不见的(记在 [known-issues.md](known-issues.md));
* 声音是宿主音频后端发出来的 —— 虚拟机里没有真喇叭,响的是你的声卡。

### 8.2 谱子格式(一共就三样东西)

```
# 一个词的第一个字符是 # → 从这里到行尾都是注释
tempo 140          # 每分钟多少拍(默认 120);四分音符 = 60000/tempo 毫秒
A4  8              # 音名 + 时值:1 全音符 / 2 二分 / 4 四分 / 8 八分 / 16 十六分
C#5 8              # 升号写 #(注意:音名里的 # 不是注释,只有"词首"的 # 才是)
R   4              # R = 休止(不出声,只等这么久)
```

* **音名** = 字母 `C D E F G A B`(大小写都认)+ 可选 `#` + 八度数字(1~9)。
  播放器里只有 C4~B4 一个八度的频率表,别的八度靠 ×2 / ÷2 搬(十二平均律里
  高八度正好是两倍频),所以 `C4`~`B5` 当然行,再宽两个八度也能写;
* 一行可以放多个音:`A4 4 C5 8 D5 16` 等价于三行(音名 时值 音名 时值 …);
* `tempo` 可以中途改,写在哪儿就影响它后面的音;
* 时值不只是 2 的幂:`3` 也能写(三连音那意思),但 `1/2/4/8/16` 最好读;
* 写错了会告诉你**第几行**、错在哪(音名不认识、时值没写、超出蜂鸣器范围…)。

### 8.3 音准对照表(写死在播放器里,十二平均律 A4 = 440 Hz)

| 音 | C4 | C#4 | D4 | D#4 | E4 | F4 | F#4 | G4 | G#4 | A4 | A#4 | B4 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Hz | 262 | 277 | 294 | 311 | 330 | 349 | 370 | 392 | 415 | 440 | 466 | 494 |

高一个八度就把表里的数 ×2(C5 = 524),低一个八度 ÷2(C3 = 131)。
表是四舍五入到整数 Hz 的:蜂鸣器只有方波,差零点几赫兹没人听得出来。

### 8.4 写自己的歌

1. `run EDIT MYSONG.TXT` → 按上面的格式敲几行 → `Ctrl-S` 存盘、`Ctrl-Q` 退出(`Ctrl-F` 找词)
   (或者在自己电脑上写好,用 `python3 tools/mkfat.py build/joyos-hd.img 6144 8 MYSONG.TXT=my.txt` 塞进镜像);
2. `run PLAY --list MYSONG.TXT` 对着屏幕检查音名/频率(打错了这里就会报行号);
3. `run PLAY MYSONG.TXT` 听。想换 tempo 就改 `tempo` 那一行,不用动别的。

**播放器在,但默认不带示例谱 —— 谱要自己写**:镜像根目录里没有 `.TXT` 曲谱,
上面第 1 步就是起点(以前带过两首示例,PC 喇叭方波全音量太吵,已经撤了)。
