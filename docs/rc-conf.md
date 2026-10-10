# rc.conf:开机能读的服务 / 事件配置

JoyOS 的"服务管理器"就一个文件:**根目录的 `RC.CONF`**,语法是 BSD / OpenRC 那种
`key = value`(按用户要求,**不是** systemd 的 unit 段)。开机时内核读它一次,
告诉你配置生效了没有;想改就 `write RC.CONF ...` 再 `rc reload`,不用重做镜像。

它干两件事:

1. **按配置跑程序**(服务):`service_N` 指定磁盘上的程序,`rc start N` 手动跑,
   或者 `autostart="YES"` 让开机自己按顺序跑一遍;
2. **记事件账本**:开机、读配置、服务起停、程序跑完 / 崩了、线程被 kill、换 shell
   —— 每种都连 tick 一起记进 16 格环形缓冲,`rc log` 翻。

实现:一个文件 [`kernel/rc.asm`](../kernel/rc.asm)(约 700 行),配置里的服务借用
shell 的 `run` 那条路跑 —— 所以服务程序**也跑在 ring 3、也走按需分页**
(见 [../README.md](../README.md) 第 5 节)。

---

## 1. 语法(就三条)

```
# 一行一个 key=value;空行和 # 开头的行忽略
hostname="joyos"            # 值可以带双引号,# 后面是注释
BOOT_MSG=hi from rc.conf    # key 不分大小写;不带引号也行
```

* 一行一个 `key=value`,行尾的 `#` 之后是注释(`#` 前面得有空格);
* 值带双引号时,引号里的内容原样算(`"NO   # 注释"` 这种才会被吃进值里);
* key 比较**不分大小写**,`HOSTNAME` 和 `hostname` 一样。

上限(超了就忽略,不会崩):

| 东西 | 上限 |
| --- | --- |
| 配置文件大小 | 4 KiB(`RC_MAX`) |
| key 条数 | 32(`RC_KEYS`) |
| 服务个数 | 8(`RC_SVCS`,编号 1~8) |
| 事件账本 | 16 条(环形缓冲,满了盖最老的) |

## 2. 认得的 key

| key | 意思 |
| --- | --- |
| `hostname` | 主机名(`rc` 概要里显示;不影响命令提示符) |
| `boot_msg` | 开机打一行(`boot_msg: ...`)—— 配置生效的肉眼证明 |
| `autostart` | `YES` = 开机把"启用的服务"按编号顺序跑一遍;默认 `NO`(不然开机会卡在服务里) |
| `on_crash` | 程序崩了(ring 3 里被页错误干掉)之后干什么:`log` = 只记账(默认),`reboot` = 直接重启机器 |
| `service_N` | 第 N 号服务要跑的程序名(不带 `.BIN` 会自动补) |
| `service_N_enable` | `YES` / `yes` / `1` 都算"启用";只有启用的服务才会被 autostart 跑 |
| `service_N_args` | 传给服务的参数(走 `run` 的同一个参数通道) |

N 是 1~8。`service_N` 写了、`service_N_enable` 没写,`rc list` 会显示成 `disabled`
(手动 `rc start N` 照样能跑)。

## 3. `rc` 命令

```
rc            概要:读到哪个文件、几个 key、hostname、autostart / on_crash、几个服务
rc list       列出所有登记的服务(编号、程序、启用状态、参数)
rc get <key>  取一个 key 的值(不分大小写)
rc start <n>  把第 n 号服务当程序跑一遍(走 run 那条路)
rc log        事件账本(最近的 16 条,带 tick)
rc reload     重新从磁盘读 RC.CONF 并重新解析(改完文件立刻生效)
```

真实输出(`run` 一个都不需要,全是 shell 里敲的):

```
> rc
rc.conf  : RC.CONF
  keys     : 9  services : 2 (0)
  hostname  : joyos
  autostart: NO
  on_crash : log
rc list / rc get KEY / rc start N / rc log / rc reload
> rc list
services in RC.CONF:
[1] HELLO.BIN disabled  args: hi-from-rc-conf
[2] UTF8.BIN disabled
rc start N 就能跑;enabled 只影响开机 autostart
> rc start 1
running HELLO.BIN
address space: CR3 = 0x00406000  (own page directory + demand paging)
Hello from HELLO.BIN - I was loaded from the FAT16 disk!
...
program returned to the shell
address space destroyed: 6 page(s) back to the pool
demand paging: 1 page(s) faulted in (image 1 + heap 0), first page 0x0040B000
> rc log
event log (tick = 100 Hz PIT 心跳):
  t=2  boot  arg=0x00000000
  t=2  rc.conf  arg=0x00000000
  t=2134  service start  arg=0x00000001
  t=2159  program exit  arg=0x00000001
  t=2159  service ok  arg=0x00000001
```

开机那两行长这样(第一行是 `RC.CONF` 读到了什么,第二行是 `boot_msg`):

```
rc.conf: RC.CONF, 9 keys, hostname joyos, services 2 (0)
boot_msg: hello from rc.conf (this line came off the disk)
```

`autostart="YES"` 且 `service_1_enable="YES"` 时,开机在 shell 起来之前就会多一行
`rc.conf: autostart=YES, starting enabled services...`,然后服务程序自己跑完:

```
event log (tick = 100 Hz PIT 心跳):
  t=2  boot  arg=0x00000000
  t=2  rc.conf  arg=0x00000000
  t=6  service start  arg=0x00000001     ← 开机 60 ms 就把 HELLO 跑起来了
  t=11  program exit  arg=0x00000001
  t=11  service ok  arg=0x00000001
```

## 4. 事件账本:哪些事会被记

| 事件名 | 什么时候记 | 附带数(arg) |
| --- | --- | --- |
| `boot` | 内核起来时 | 0 |
| `rc.conf` | 读完 / 重读配置 | 0 |
| `service start` | 服务要开始了 | 服务编号 |
| `service ok` | 服务正常跑完 | 服务编号 |
| `service failed` | 服务被杀(崩了 / 被 kill) | 服务编号 |
| `program exit` | 任何程序正常回 shell(`run` 也算) | 这次补了多少个缺页 |
| `program crash` | 程序在 ring 3 里被异常干掉 | 出错时的 EIP |
| `thread killed` | `kill <id>` 杀掉一条线程 | 线程号 |
| `shell switch` | Ctrl+←/→ 或 `shell n` 换焦点 | 新的 shell 号 |

事件是 `evt_log` 记的:16 格环形缓冲,每格存「事件号 + tick + 附带数」。
tick 是 100 Hz 的 PIT 心跳,所以两个事件差多少 tick = 差多少 10 ms。

## 5. 服务是怎么"跑"的

`rc start N` 不是另起一套机制,它**临时把 `[cmd_arg]` 换成拼好的 `程序名 参数`
然后调 shell 的 `cmd_run`** —— 和你在命令行敲 `run HELLO.BIN hi` 完全同一条路:

* 建一套自己的页目录 + 按需分页(碰哪页补哪页);
* `iret` 到 **CPL=3**,内核的内存它碰不到;
* 跑完回 shell,地址空间收摊,页都还给物理页池。

一次仍然**只能跑一个程序**(`run` 那条守卫:别人在跑就拒绝,提示 Ctrl+←/→ 或 kill),
所以"服务"目前是**顺序**跑的,不并发 —— 这正是想把 `space_*` 挂到线程之后要改的事
(见 README 第 11 节)。

## 6. 现在没有的东西(边界)

* **没有依赖关系**:没有 `after=` / `requires=`,只有一个按编号跑的顺序;
* **没有 stop**:服务是"跑一遍就走"的程序,不是常驻进程,没有 `rc stop`;
* **没有重启/重试**:服务崩了只记账(`on_crash="log"`)或者整机重启(`"reboot"`);
* **没有环境变量 / 用户 / 权限**:玩具 OS,没有用户概念,大家都是 ring 3;
* **配置文件只有根目录的 `RC.CONF`**:不支持 `/etc/` 之类的路径(更没有多份配置叠加);
* `hostname` 现在只显示,不改变命令提示符。

细节和踩过的坑看 [../README.md](../README.md) 第 6.22 ~ 6.24 节
(读配置的缓冲区压在 FAT 扇区缓冲里、`push`/`pop` 配不平导致 `EIP=0x00000007`、
小工具函数偷改寄存器和 `strip_name` 把第一个空格改 0)。
