# 扩展(extensions/)

**这里放"可选玩具",不进默认构建、不进默认镜像。**

为什么:`third_party/` 里的东西一旦并进主线,它的一点点不合口味(比如某次 `:q` 不灵)
就会拖住整个 `make test`。所以规矩定成:核心(自己写的)负责"开机就能用",
扩展负责"想看的时候编一下"。

## 现有的扩展

| 目录 | 是什么 | 怎么玩 |
|---|---|---|
| `vi/` | STEVIE 3.68(公版 vi 克隆,vim 的前身)+ 我们写的 `joyos.c` 后端 | `make ext` → `make run-ext` |

## 命令

```bash
make ext        # 构建所有扩展($(BUILD)/ext 下的 .BIN)
make ext-img    # 做一张"默认镜像 + 扩展"的镜像
make run-ext    # 构建并在 QEMU 里启动那张镜像
```

## 加一个新扩展

1. 源码放 `extensions/<名字>/`(放 `main()` 的 .c 就行,别的都不用管);
2. Makefile 里 `EXT_BINS` 加一行;
3. 如果你希望它出现在默认镜像里……那它就不是扩展,应该放 `progs/` 或 `third_party/` :-)

## 约定

* 扩展**只许用公开 API**(`int 0x30` / 以后的 `joyos.h`),不碰内核地址;
* 扩展不参与 `make test` 的默认断言 —— 想测就单独写一个 target;
* 扩展挂了,主线不该跟着挂。
