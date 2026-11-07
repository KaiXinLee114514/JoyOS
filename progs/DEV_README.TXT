# KKernel /DEV

这个目录里都是"虚拟设备" —— 磁盘上只摆着空的占位文件,
真正的读写在内存里现做,由内核的设备层接手(见 kernel/dev.asm)。

  DEV/NULL     读:永远 0 字节          写:丢弃
  DEV/ZERO     读:要多少给多少 0        写:丢弃
  DEV/RANDOM   读:伪随机字节            写:不支持
  DEV/RTC      读:YYYY-MM-DD HH:MM:SS   写:不支持
  DEV/CON      读:不支持                写:当文本打到屏幕上
  DEV/DEVICES  读:列出所有设备名        写:不支持

用法举例(在 shell 里):
  cat DEV/RTC
  cat DEV/DEVICES
  write DEV/CON hello, console!
  write DEV/NULL 这不占地方
