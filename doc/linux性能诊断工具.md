# Linux性能诊断工具使用手册

> 版本：1.0
> 适用场景：Linux服务器性能问题排查、系统瓶颈定位、日常运维监控
> 内容依据：各工具官方man手册与官方文档（内核文档docs.kernel.org、sysstat官方文档、工具官方仓库），编写时已交叉核对

---

## 1. 手册概述

### 1.1 编写目的

本手册基于"Linux性能诊断工具速查表"整理扩展，针对速查表中列出的32项工具，逐项给出：

- 功能定位与诊断价值
- 所属软件包与安装方式（RHEL/CentOS系与Debian/Ubuntu系双列）
- 命令语法与常用参数说明
- 真实输出示例与关键字段解读
- 典型实战示例
- 使用注意事项与权限要求

手册按**应用层→内核层→驱动层/网络接口→硬件层（CPU/内存）→I/O层（磁盘/交换）**五层结构组织，与速查表分层保持一致。

### 1.2 性能诊断方法论

#### 1.2.1 USE方法

排查任何性能问题，先对每一类资源依次检查三项指标：

| 指标 | 含义 | 判断标准 |
| --- | --- | --- |
| 使用率（Utilization） | 资源忙于工作的时间比例 | 持续超过80%需要关注 |
| 饱和度（Saturation） | 资源排队等待的程度 | 排队长度持续大于0需要关注 |
| 错误（Errors） | 资源出错计数 | 任何非0错误都需要关注 |

对应常用工具：

- CPU：`mpstat`（使用率）、`vmstat`的r列（饱和度）、`dmesg`/`turbostat`（错误与降频）
- 内存：`free`/`vmstat`（使用率）、`vmstat`的si/so列（饱和度，即swap活动）
- 磁盘：`iostat -dx`的%util（使用率）、aqu-sz/await（饱和度）、`ethtool -S`与`dmesg`（错误）
- 网络：`ss`/`sar -n DEV`（使用率）、`ss`的Recv-Q/Send-Q（饱和度）、`ethtool -S`/`netstat -s`（错误）

#### 1.2.2 自顶向下排查法

从应用层开始，逐层向下定位：

1. **应用层**：进程是否异常？用`ps`、`top`、`pidstat`确认问题进程
2. **系统调用层**：进程在做什么？用`strace`、`ltrace`、`perf trace`观察
3. **内核层**：内核在哪里耗CPU？用`perf`、`ftrace`、eBPF工具观察
4. **资源层**：CPU/内存/磁盘/网络哪类资源是瓶颈？用`mpstat`、`vmstat`、`iostat`、`ss`确认
5. **硬件层**：是否存在硬件错误或降频？用`dmesg`、`ethtool -S`、`turbostat`、`rdmsr`确认

排查原则：**先定量后定性**——先用监控类工具（top/vmstat/iostat/sar）确认瓶颈方向，再用跟踪类工具（strace/perf/blktrace/tcpdump）深入根因。

### 1.3 工具分层架构

| 层级 | 观察对象 | 核心工具 |
| --- | --- | --- |
| 应用层 | 进程、系统调用、文件句柄、连接 | strace、lsof、ltrace、sysdig、ss/netstat、pcstat |
| 内核层 | 内核函数、事件采样、探针 | perf、ftrace、eBPF、pidstat、SystemTap、LTTng |
| 驱动层/网络接口 | 网卡、网络包、链路 | tcpdump、iptraf、ethtool、lldptool、snmpget |
| 硬件层（CPU/内存） | CPU、内存、NUMA、电源状态 | top/htop、ps、mpstat、vmstat、free、slabtop、numastat、sar、dstat、turbostat、rdmsr |
| I/O层（磁盘/交换） | 块设备、进程I/O、交换分区 | iostat、iotop、blktrace、swapon |

### 1.4 通用准备工作

#### 权限要求

- 大部分跟踪类工具（strace、perf、tcpdump、blktrace、iotop、sysdig、bpftrace）需要**root权限**或对应capability（CAP_SYS_PTRACE、CAP_NET_RAW、CAP_BPF等）
- 普通监控类工具（top、ps、free、vmstat、ss）任何用户可运行，但查看他人进程详情需要root
- 内核跟踪类工具（ftrace、eBPF）需要挂载tracefs/bpf文件系统，内核编译时开启对应选项

#### 安装基础工具集

```bash
# RHEL/CentOS系
dnf install -y sysstat procps-ng iproute net-tools lsof strace ltrace \
    perf kernel-tools tcpdump ethtool blktrace iotop numactl \
    bcc-tools bpftrace trace-cmd

# Debian/Ubuntu系
apt install -y sysstat procps iproute2 net-tools lsof strace ltrace \
    linux-tools-common linux-tools-$(uname -r) tcpdump ethtool blktrace \
    iotop numactl bpfcc-tools bpftrace trace-cmd
```

#### 内核可调参数（跟踪类工具相关）

```bash
# 允许非root用户使用perf（-1为最大放开，生产环境慎用）
sysctl -w kernel.perf_event_paranoid=-1

# 允许非root用户使用ftrace
sysctl -w kernel.kptr_restrict=0

# 查看当前值
sysctl kernel.perf_event_paranoid
```

---

## 2. 工具速查总表

### 2.1 应用层

| 工具 | 用途 | 典型命令 | 所属软件包 | 适用场景 |
| --- | --- | --- | --- | --- |
| strace | 跟踪系统调用 | `strace -p <pid>` | strace | 调试程序行为、定位系统调用异常 |
| lsof | 查看打开的文件 | `lsof -p <pid>` | lsof | 检查文件句柄泄漏、资源占用 |
| ltrace | 跟踪库函数调用 | `ltrace ./app` | ltrace | 分析动态链接库调用 |
| sysdig | 捕获系统事件 | `sysdig -pc -w trace.scap` | sysdig | 全面系统行为分析 |
| ss / netstat | 查看网络连接 | `ss -tulnp` | iproute2 / net-tools | 网络端口监听、连接状态排查 |
| pcstat | 页面缓存命中率 | `pcstat /path/to/file` | pcstat（开源工具，需单独安装） | 文件缓存性能分析 |

### 2.2 内核层

| 工具 | 用途 | 典型命令 | 所属软件包 | 适用场景 |
| --- | --- | --- | --- | --- |
| perf | CPU/内核事件采样 | `perf top` / `perf record` | linux-tools-* / kernel-tools | 性能热点分析、函数调用统计 |
| ftrace | 内核函数跟踪 | `echo function > /sys/kernel/tracing/current_tracer` | 内核内置（tracefs） | 内核路径追踪 |
| eBPF（bcc/bpftrace） | 高级内核事件分析 | `execsnoop`（bcc工具集） | bcc-tools / bpftrace | 低开销动态追踪 |
| pidstat | 进程资源统计 | `pidstat -u -p <pid>` | sysstat | CPU、内存、I/O使用分析 |
| stap（SystemTap） | 内核探针脚本 | `stap -v script.stp` | systemtap | 自定义内核事件分析 |
| lttng | 低开销追踪框架 | `lttng list` / `lttng start` | lttng-tools | 多线程、系统调用分析 |

### 2.3 驱动层/网络接口

| 工具 | 用途 | 典型命令 | 所属软件包 | 适用场景 |
| --- | --- | --- | --- | --- |
| tcpdump | 抓取网络包 | `tcpdump -i eth0 port 80` | tcpdump | 网络故障、数据包分析 |
| iptraf | 实时网络流量监控 | `iptraf` / `iptraf-ng` | iptraf-ng | 网络带宽监控 |
| ethtool | 网卡状态与配置 | `ethtool eth0` | ethtool | 网卡速率、错误统计 |
| lldptool | 网络拓扑发现 | `lldptool -t -i eth0` | lldpad / open-lldp | 数据中心链路排查 |
| snmpget | 获取设备状态 | `snmpget -v2c -c public <host> <OID>` | net-snmp-utils | 网络设备监控 |

### 2.4 硬件层（CPU/内存）

| 工具 | 用途 | 典型命令 | 所属软件包 | 适用场景 |
| --- | --- | --- | --- | --- |
| top / htop | 实时资源监控 | `top` / `htop` | procps-ng / htop | 快速查看系统负载 |
| ps | 查看进程状态 | `ps aux` | procps-ng | 进程资源占用分析 |
| mpstat | 多核CPU使用率 | `mpstat -P ALL 1` | sysstat | CPU核心负载分析 |
| vmstat | 内存与进程统计 | `vmstat 1` | procps-ng | 内存、上下文切换分析 |
| free | 内存使用情况 | `free -m` | procps-ng | 内存分布快速查看 |
| slabtop | 内核缓存统计 | `slabtop` | procps-ng | 内核对象分配分析 |
| numastat | NUMA内存分布 | `numastat` | numactl | 多CPU架构内存优化 |
| sar | 历史资源统计 | `sar -u 1 3` | sysstat | 长时间性能趋势分析 |
| dstat | 多资源实时统计 | `dstat -cdngy` | dstat / dool | 综合性能监控 |
| turbostat | CPU节能状态 | `turbostat` | linux-cpupower / kernel-tools | CPU睿频与节能分析 |
| rdmsr | 读取CPU寄存器 | `rdmsr 0x10` | msr-tools | 深度硬件调试 |

### 2.5 I/O层（磁盘/交换）

| 工具 | 用途 | 典型命令 | 所属软件包 | 适用场景 |
| --- | --- | --- | --- | --- |
| iostat | 磁盘I/O统计 | `iostat -dx 1` | sysstat | 磁盘性能瓶颈分析 |
| iotop | 实时I/O使用 | `iotop` | iotop | 哪个进程在读写磁盘 |
| blktrace | 块设备I/O跟踪 | `blktrace -d /dev/sda` | blktrace | 深度磁盘行为分析 |
| swapon | 查看交换空间 | `swapon -s` | util-linux | Swap使用情况分析 |

---

## 3. 应用层工具详解

### 3.1 strace——系统调用跟踪

#### 功能说明

strace通过ptrace系统调用附加到目标进程，拦截并记录进程与内核之间的每一次系统调用（system call）和信号（signal），是定位"程序到底卡在哪里、报什么错、开了哪些文件、连了哪些端口"的首选工具。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y strace` |
| Debian/Ubuntu | `apt install -y strace` |

#### 常用参数

| 参数 | 说明 |
| --- | --- |
| `-p <pid>` | 附加到指定进程 |
| `-f` | 跟踪进程及其创建的所有子进程/线程 |
| `-o <file>` | 输出写入文件而不是终端 |
| `-t` / `-tt` / `-ttt` | 每行加时间戳（时:分:秒 / 微秒 / 微秒时间戳） |
| `-T` | 显示每个系统调用的耗时（秒，带小数） |
| `-r` | 显示相邻系统调用的相对时间差 |
| `-c` | 统计模式：汇总每类系统调用的次数、错误数和耗时 |
| `-e trace=<set>` | 只跟踪指定系统调用，如`-e trace=file`（文件类）、`-e trace=network`（网络类）、`-e trace=openat,read,write`（指定调用） |
| `-e signal=` | 跟踪指定信号，如`-e signal=SIGSEGV` |
| `-e status=successful\|failed` | 只显示成功/失败的系统调用 |
| `-s <n>` | 字符串最大显示长度（默认32，常用`-s 200`） |
| `-y` / `-yy` | 显示文件描述符对应的路径（`-yy`连带socket/管道详情） |
| `-k` | 显示每个系统调用的用户态调用栈 |

#### 输出解读

```
$ strace -tt -T -p 1234
10:23:45.123456 openat(AT_FDCWD, "/etc/hosts", O_RDONLY|O_CLOEXEC) = 3 <0.000021>
10:23:45.123500 read(3, "127.0.0.1 localhost\n", 4096) = 20 <0.000008>
10:23:45.123520 connect(5, {sa_family=AF_INET, sin_port=htons(3306), sin_addr=inet_addr("10.0.0.15")}, 16) = -1 ECONNREFUSED (Connection refused) <0.000312>
```

字段说明：

- `10:23:45.123456`：系统调用发生时刻（`-tt`修饰）
- `openat(...)`：系统调用名与参数；`= 3`为返回值（文件描述符3）
- `= -1 ECONNREFUSED`：调用失败及错误码，这是定位问题的关键信号
- `<0.000312>`：该调用耗时312微秒（`-T`修饰），耗时长的调用即为卡顿点

#### 实战示例

```bash
# 统计进程系统调用耗时排行（快速定位是哪种操作慢）
strace -c -p 1234

# 观察进程卡住不返回时，最后一个未完成的系统调用
strace -tt -T -p 1234

# 跟踪程序启动过程，找出加载了哪些配置文件
strace -f -e trace=file -o app.log ./app

# 只显示失败的系统调用
strace -e status=failed -p 1234
```

#### 注意事项

- ptrace机制会显著降低目标进程速度（高并发进程可能慢数十倍），**生产环境严禁长时间附加**，建议短时采样
- 附加失败提示`Operation not permitted`时：检查是否root、目标进程是否有特殊capability、容器内是否加了SYS_PTRACE
- 内核参数`kernel.yama.ptrace_scope`控制是否允许非root附加，默认1表示只允许附加自己的子进程
- 与ltrace不能同时附加同一进程

---

### 3.2 lsof——打开文件与句柄排查

#### 功能说明

lsof（list open files）列出进程打开的所有文件描述符，包括普通文件、目录、块设备、字符设备、socket、管道等。在Linux中"一切皆文件"，因此lsof可用于：文件句柄泄漏排查、端口占用定位、误删文件空间未释放排查、进程与文件关联关系分析。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y lsof` |
| Debian/Ubuntu | `apt install -y lsof` |

#### 常用参数

| 参数 | 说明 |
| --- | --- |
| `-p <pid>` | 列出指定进程打开的文件 |
| `-i` | 列出网络连接相关文件，可组合：`-i :80`（80端口）、`-i @10.0.0.1`（指定主机）、`-i TCP`、`-i UDP` |
| `-u <user>` | 按用户过滤 |
| `-c <comm>` | 按进程名过滤（支持通配，如`-c java`） |
| `-d <fd>` | 按文件描述符过滤，如`-d 1,2`或`-d cwd` |
| `+d <dir>` / `+D <dir>` | 查看目录下文件被谁打开（`+D`递归） |
| `-t` | 精简输出（只输出PID），便于与其他命令组合 |
| `-n` | 不解析主机名（加速） |
| `-P` | 不解析端口号为服务名（加速） |
| `-r <秒>` | 重复模式，每隔指定秒刷新一次 |

#### 输出解读

```
$ lsof -p 1234
COMMAND  PID  USER   FD      TYPE   DEVICE   SIZE/OFF   NODE NAME
java    1234  user  cwd       DIR    253,0       4096      2 /
java    1234  user  rtd       DIR    253,0       4096      2 /
java    1234  user  txt       REG    253,0      87104 123456 /usr/lib/jvm/java-11/bin/java
java    1234  user  mem       REG    253,0    5337344 123457 /usr/lib64/libc-2.28.so
java    1234  user    3r      REG    253,0       1024 234567 /data/app/config/app.properties
java    1234  user   10u     IPv4   12345        0t0    TCP *:8080 (LISTEN)
java    1234  user   25u     IPv4   12348        0t0    TCP 10.0.0.10:22->10.0.0.20:52814 (ESTABLISHED)
java    1234  user  500w      REG    253,0 2147483648  99001 /data/log/app.log (deleted)
```

关键字段：

- `FD`：文件描述符；数字后带`r`读、`w`写、`u`读写；`cwd`当前目录、`txt`程序代码、`mem`内存映射、`rtd`根目录
- `TYPE`：REG普通文件、DIR目录、IPv4/IPv6网络、CHR字符设备
- `NAME`：文件名或连接四元组；`(LISTEN)`监听、`(ESTABLISHED)`已建立连接
- `(deleted)`：文件已被删除但句柄未关闭，**磁盘空间不释放的典型元凶**

#### 实战示例

```bash
# 端口占用定位（谁占用了8080端口）
lsof -i :8080

# 句柄泄漏排查：统计进程句柄总数
lsof -p 1234 | wc -l
ls /proc/1234/fd | wc -l          # 等价快速统计

# 已删除文件占用磁盘排查（空间满但du找不到大文件）
lsof | grep deleted | sort -k7 -rn | head

# 查看某目录下文件被哪些进程打开
lsof +D /data/app

# 批量kill占用某端口的进程
kill -9 $(lsof -t -i :8080)
```

#### 注意事项

- 普通用户只能查看自己进程的完整信息，查看他人进程需要root
- lsof扫描全系统代价较高（大型服务器上`lsof`裸命令可能耗时数秒到数十秒），优先用`-p`、`-i`、`-u`收窄范围
- 现代内核上`/proc/<pid>/fd`与`/proc/<pid>/fdinfo`是更轻量的替代手段
- 进程句柄上限由`ulimit -n`控制，泄漏时先确认上限值再排查

---

### 3.3 ltrace——库函数调用跟踪

#### 功能说明

ltrace与strace类似，但跟踪层次不同：strace跟踪**系统调用**（内核接口），ltrace跟踪**动态库函数调用**（用户态库接口，如malloc、strcpy、pthread_create）。它通过在PLT（Procedure Linkage Table）处下断点来捕获库函数调用。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y ltrace` |
| Debian/Ubuntu | `apt install -y ltrace` |

#### 常用参数

| 参数 | 说明 |
| --- | --- |
| `./app` | 直接跟踪程序从启动开始的库调用 |
| `-p <pid>` | 附加到运行中的进程 |
| `-c` | 统计模式：汇总库函数调用次数与耗时 |
| `-e <expr>` | 只跟踪匹配的库函数，如`-e malloc+free` |
| `-l <pattern>` | 只跟踪指定共享库中的函数，如`-l libc.so.6` |
| `-f` | 跟踪子进程 |
| `-o <file>` | 输出到文件 |
| `-t` / `-tt` | 显示时间戳 |
| `-S` | 同时显示系统调用（等价strace+ltrace） |

#### 输出解读

```
$ ltrace -tt ./app
10:25:01.123456 malloc(4096)                                                = 0x55f2c1a2b010
10:25:01.123890 memset(0x55f2c1a2b010, '\0', 4096)                          = 0x55f2c1a2b010
10:25:01.124001 fopen("/data/config.ini", "r")                              = 0x55f2c1a2c020
10:25:01.124550 pthread_create(0x7ffe1234, NULL, 0x55f2c0f8a120, 0x55f2c1a2d000) = 0
```

- 每行格式为：时间戳 + 库函数调用及其参数 + `=` 返回值
- `= 0`表示成功（pthread_create返回0），`= NULL`表示失败（如fopen失败）
- `-c`统计模式下可快速发现高频malloc/free（潜在内存碎片）或高频字符串操作（潜在热点）

#### 实战示例

```bash
# 统计模式下查看malloc/free调用次数（判断内存分配模式）
ltrace -c -e malloc+free -p 1234

# 观察程序打开配置文件的库调用序列
ltrace -e fopen+fclose ./app

# 跟踪glibc函数调用（排查线程创建失败等问题）
ltrace -l libc.so.6 -f ./app 2>&1 | grep pthread
```

#### 注意事项

- ltrace**只对动态链接的程序有效**，静态编译程序或Go等直接发系统调用的语言（不经过libc库函数层）不适合ltrace，应改用strace
- 同样基于ptrace，性能开销大，生产环境短时使用
- 部分环境下ltrace对多线程支持不完善，输出可能不完整
- 附加失败原因与strace相同（ptrace权限）

---

### 3.4 sysdig——系统级事件捕获与分析

#### 功能说明

sysdig是一个功能强大的系统级捕获工具，可捕获系统调用、进程事件、文件I/O、网络I/O、容器事件等，支持强大的过滤表达式，并能将捕获数据保存为文件（.scap）离线分析。它是strace、tcpdump、lsof、netstat等工具能力的统一体，对容器环境尤其友好。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `curl -s https://s3.amazonaws.com/download.draios.com/stable/install-sysdig \| bash` |
| Debian/Ubuntu | `curl -s https://s3.amazonaws.com/download.draios.com/stable/install-sysdig \| bash` |
--注：不支持某些国产数据库
（官方脚本会自动添加软件源并安装；具体命令以sysdig官网安装说明为准。）

#### 常用参数

| 参数 | 说明 |
| --- | --- |
| 无参数 | 实时输出所有事件（输出量极大，务必加过滤器） |
| `-w <file.scap>` | 写入捕获文件 |
| `-r <file.scap>` | 读取捕获文件分析 |
| `-p <format>` | 输出格式，如`-p%evt.time,%proc.name,%evt.type`；`-p c`彩色格式、`-p container`容器格式 |
| `-c <chisel>` | 运行chisel脚本（内置分析脚本），如`-c topfiles_bytes`、`-c topprocs_cpu` |
| `-l <chisel>` | 列出全部可用chisel |
| `-pc` | 容器感知模式（简化容器输出） |
| `-n <num>` | 捕获指定数量事件后退出 |
| `-A` | ASCII显示数据缓冲区（可看HTTP明文） |

#### 过滤器语法（核心能力）

```
# 语法：[field operator value] [and|or] ...
proc.name = nginx
fd.type = ipv4 and evt.type = connect
evt.type in (open,openat,unlink)
container.name != host
proc.pid = 1234
fd.port = 80
```

常用字段：`proc.name`进程名、`proc.pid`进程号、`evt.type`事件类型、`evt.dir`（`>`进入、`<`退出）、`fd.name`文件或连接名、`fd.type`（file/ipv4/ipv6）、`container.name`容器名、`user.name`用户名。

#### 输出解读

```
$ sysdig -pc -n 5
1 10:30:01.123456789 java (1234:4) > openat
2 10:30:01.123500123 java (1234:4) < openat fd=45(/data/log/app.log)
3 10:30:01.124000456 java (1234:4) > connect
4 10:30:01.124300789 java (1234:4) < connect res=0 tuple=10.0.0.10:33442->10.0.0.15:3306
```

- 行首数字为事件序号
- `>`表示进入事件（调用），`<`表示退出事件（返回）
- `(1234:4)`中1234为PID，4为线程TID
- `fd=45(/data/log/app.log)`说明文件描述符对应的文件
- `res=0 tuple=...`显示连接结果与四元组

#### 实战示例

```bash
# 捕获3分钟系统事件到文件（低开销，适合生产）
sysdig -w trace.scap

# 离线分析：看耗时最长的文件读写TOP列表
sysdig -r trace.scap -c topfiles_bytes

# 离线分析：CPU占用最高的进程
sysdig -r trace.scap -c topprocs_cpu

# 实时查看慢于10ms的磁盘I/O
sysdig -c fileslower 10

# 查看某个容器的所有网络连接
sysdig -pc container.name=webapp and evt.type=connect

# 查看进程删除文件的动作（排查误删）
sysdig evt.type=unlinkat and proc.name!=rm
```

#### 注意事项

- sysdig通过内核模块（sysdig-probe）或eBPF探针工作；新内核若无法编译模块，可设置`SYSDIG_FORCE_BUILD_PROBE`或使用eBPF探针
- 需要root权限
- 实时输出量巨大，永远要带过滤器或`-n`限制
- 捕获文件（.scap）可能迅速增大，长时间捕获注意磁盘空间（可配合`-M`每N秒切割文件）

---

### 3.5 ss / netstat——网络连接状态查看

#### 功能说明

ss（socket statistics）来自iproute2工具集，用于查看socket统计信息，输出速度远快于已被逐步淘汰的netstat（net-tools）。两者都能查看监听端口、连接状态、协议统计，ss还直接读取内核数据结构，连接数大时优势明显。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `ss`随iproute预装；`yum install -y net-tools`（如需netstat） |
| Debian/Ubuntu | `ss`随iproute2预装；`apt install -y net-tools`（如需netstat） |

#### 常用参数（ss）

| 参数 | 说明 |
| --- | --- |
| `-t` / `-u` / `-w` / `-x` | TCP / UDP / RAW / Unix socket |
| `-l` | 只显示监听（LISTEN）状态的连接 |
| `-n` | 数字形式显示端口和地址（不解析服务名/主机名） |
| `-p` | 显示占用socket的进程（需root） |
| `-a` | 显示全部（含监听与非监听） |
| `-s` | 打印协议统计摘要（总连接数、各状态数量） |
| `-i` | 显示TCP内部信息：RTT、拥塞窗口cwnd、重传等 |
| `-o` | 显示定时器信息（keepalive、timewait等） |
| `-e` | 显示socket详细信息（inode、uid等） |
| `-m` | 显示socket内存使用 |
| `-4` / `-6` | 只显示IPv4 / IPv6 |

#### 输出解读

```
$ ss -tulnp
Netid  State   Recv-Q  Send-Q   Local Address:Port     Peer Address:Port   Process
udp    UNCONN  0       0              0.0.0.0:123           0.0.0.0:*       users:(("chronyd",pid=890,fd=1))
tcp    LISTEN  0       128            0.0.0.0:22            0.0.0.0:*       users:(("sshd",pid=123,fd=3))
tcp    LISTEN  0       100               [::]:3306             [::]:*       users:(("mysqld",pid=4567,fd=24))
tcp    ESTAB   0       0         10.0.0.10:22         10.0.0.20:52814     users:(("sshd",pid=6789,fd=4))
```

关键字段与诊断要点：

- `State`：LISTEN监听、ESTAB已建立、TIME-WAIT、CLOSE-WAIT、SYN-SENT等
- `Recv-Q`：接收队列中未被应用读取的字节数。**ESTAB连接中Recv-Q长期非0，说明应用处理不过来**
- `Send-Q`：已发送未确认的字节数；对LISTEN套接字则表示listen backlog上限
- **大量CLOSE-WAIT**：应用收到FIN后未调用close（代码缺陷或线程堵塞）
- **大量TIME-WAIT**：本机主动关闭连接过多，可调`net.ipv4.tcp_tw_reuse`等参数缓解
- `ss -s`输出各协议socket总数：
  ```
  Total: 512
  TCP:   87 (estab 12, closed 55, orphaned 0, timewait 48)
  ```

#### 实战示例

```bash
# 谁在监听8080端口
ss -tlnp | grep :8080

# 按连接状态统计（快速发现异常状态堆积）
ss -tan | awk '{print $1}' | sort | uniq -c | sort -rn

# 查看TCP连接的RTT、重传、拥塞窗口
ss -tin state established

# 查看内核协议统计（重传、丢包错误）
ss -s
netstat -s        # netstat对应能力

# 模拟旧netstat习惯的用法（ss不显示进程名时用-p）
ss -tanp | grep ESTAB
```

#### 注意事项

- 查询进程信息（`-p`）需要root权限，否则Process列为空
- 海量连接场景（如数万connection）netstat可能耗时数十秒甚至卡住，务必用ss
- `ss -i`中的`retrans`、`rtt`、`cwnd`是网络质量诊断的核心指标：重传多说明链路质量差，cwnd被压小说明存在拥塞
- 部分容器镜像精简后无ss/netstat，需手工安装iproute2

---

### 3.6 pcstat——页面缓存命中率分析

#### 功能说明

pcstat是第三方开源工具（GitHub：tobert/pcstat，作者Amy Tobey），基于fincore系统调用（或mincore）统计指定文件有多少页面驻留在Linux的page cache中，输出缓存比例。数据库、中间件等I/O密集型应用的"数据是否被操作系统缓存"这一问题，用pcstat一查便知。

#### 安装

该工具不包含在发行版标准仓库中，需通过Go安装或下载预编译包（需要目标机可访问网络或提前准备二进制）：

```bash
# 方式一：Go直接安装（Go 1.13+支持代理）
go install github.com/tobert/pcstat@latest

# 方式二：从GitHub Releases下载对应架构的二进制文件后放入PATH
# https://github.com/tobert/pcstat
#dnf install -y go
#ls -l ~/go/bin/pcstat  安装位置
```

#### 常用参数

| 参数 | 说明 |
| --- | --- |
| `<file1> <file2> ...` | 分析一个或多个文件 |
| `-json` | JSON格式输出（便于脚本处理） |
| `-terse` | 紧凑文本格式输出 |
| `-nohdr` | 不输出表头 |
| `-histo` | 输出缓存页面的直方图信息 |
| `-pid <pid>` | 分析指定进程的匿名内存（部分版本支持） |

#### 输出解读

```
$ pcstat /data/mysql/ibdata1
+----------------+----------------+------------+---------+---------+
| Name           | Size           | Pages      | Cached  | Percent |
|----------------+----------------+------------+---------+---------|
| /data/mysql/ibdata1 | 536870912  | 131072     | 130816  | 099.805 |
+----------------+----------------+------------+---------+---------+
```

- `Size`：文件总大小（字节）
- `Pages`：文件总页数（按4KB页计算）
- `Cached`：当前驻留page cache的页数
- `Percent`：缓存比例，**接近100%表示该文件基本被操作系统缓存**；明显低于100%时物理读会增多，I/O延迟上升

#### 实战示例

```bash
# 检查数据库数据文件的缓存率
pcstat /data/mysql/ibdata1 /data/mysql/ib_logfile0

# 检查Elasticsearch索引段的缓存情况
pcstat /data/es/nodes/0/indices/*/0/index/*.cfs

# JSON输出供脚本告警
pcstat -json /data/mysql/ibdata1
```

#### 注意事项

- 结果反映的是**执行时刻的page cache快照**，页面会随访问模式、内存压力动态变化
- 分析大文件本身有一定开销（需mmap并mmincore），超大规模文件建议先抽样
- 需要能读取目标文件（root或文件属主）
- 缓存的调优方向：增大`vm.min_free_kbytes`保留、调整`vm.vfs_cache_pressure`，或从应用侧改用直接I/O（O_DIRECT）避免缓存争抢
- 同类替代工具：Brendan Gregg的`cachestat`（perf-tools）、社区fork`pgcacher`（性能优于pcstat）

---

## 4. 内核层工具详解

### 4.1 perf——性能事件采样分析

#### 功能说明

perf是Linux内核自带的性能分析工具（源码位于内核tools/perf目录），基于perf_events子系统，可对CPU周期、指令数、缓存命中、分支预测、调度事件、系统调用等进行采样和统计，是CPU性能热点分析的行业标准工具，也是生成火焰图的默认数据源。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y perf kernel-tools` |
| Debian/Ubuntu | `apt install -y linux-tools-common linux-tools-$(uname -r)` |

内核符号解析（显示内核函数名而非地址）需要安装带调试符号的包：

```bash
# RHEL/CentOS
yum install -y kernel-debuginfo kernel-debuginfo-common-$(uname -m)

# Debian/Ubuntu
apt install -y linux-image-$(uname -r)-dbgsym    # 需启用ddebs源
```

#### 常用子命令

| 子命令 | 说明 |
| --- | --- |
| `perf stat` | 统计总览：周期数、指令数、IPC、cache-miss、上下文切换等 |
| `perf top` | 实时热点排行（类似top，但针对函数） |
| `perf record` | 采样记录到perf.data文件 |
| `perf report` | 交互式分析perf.data |
| `perf trace` | 类似strace的系统调用跟踪（开销更低） |
| `perf sched` | 调度器行为分析（延迟、迁移、唤醒） |
| `perf annotate` | 汇编指令级热点注释 |
| `perf probe` | 动态添加内核探针 |
| `perf script` | 将perf.data导出为文本（火焰图数据源） |

#### 关键参数（perf record/top）

| 参数 | 说明 |
| --- | --- |
| `-F <freq>` | 采样频率（Hz），生产环境推荐99（接近但避开1000Hz定时器干扰） |
| `-a` | 全系统所有CPU采样 |
| `-g` | 采集调用栈（call graph，火焰图必需） |
| `-p <pid>` | 只采样指定进程 |
| `-e <event>` | 指定事件，如`-e cycles`、`-e cache-misses`、`-e sched:sched_switch` |
| `--call-graph dwarf` | 用DWARF信息展开调用栈（对某些缺帧指针的程序更准） |
| `-C <cpu>` | 只采样指定CPU |

#### 输出解读

`perf top`输出：

```
Samples: 92K of event 'cycles', 4000 Hz, Event count (approx.): 52345678900
Overhead  Shared Object              Symbol
  12.35%  [kernel]                   [k] copy_user_enhanced_fast_string
   8.21%  [kernel]                   [k] __schedule
   5.44%  libjvm.so                   [.] SpinPause
   3.12%  [kernel]                   [k] native_queued_spin_lock_slowpath
```

- `[k]`表示内核符号，`[.]`表示用户态符号；`[unknown]`说明缺调试符号
- `Overhead`为函数占用采样比例，靠前的即热点函数
- `copy_user_*`靠前通常意味着大量内存拷贝（I/O密集或memcpy多）
- `SpinPause`/`native_queued_spin_lock_slowpath`靠前通常意味着**锁竞争**

`perf stat`输出：

```
$ perf stat -p 1234 -- sleep 5
 Performance counter stats for process id '1234':
        12,345.67 msec task-clock                #    4.012 CPUs utilized
              2345      context-switches          #  189.9 /sec
               123      cpu-migrations            #    9.9 /sec
         1,234,567,890      instructions          #    0.85  insn per cycle
         1,452,345,678      cycles
           123,456,789      cache-misses          #   12.34% of all cache refs
```

- **IPC（insn per cycle）**：低于1.0说明CPU流水线停滞多（内存等待或分支误预测）；持续低于0.5需深度分析
- **cache-misses占比**：超过10%说明缓存局部性差

#### 实战示例

```bash
# 采样30秒全系统热点，生成火焰图
perf record -F 99 -a -g -- sleep 30
perf script > out.perf
# 使用FlameGraph工具链生成SVG
stackcollapse-perf.pl out.perf > out.folded
flamegraph.pl out.folded > flamegraph.svg

# 实时查看热点（按E切换到带子函数的视角）
perf top -g

# 分析进程CPU消耗构成
perf stat -d -p 1234 -- sleep 10

# 分析进程被调度延迟情况
perf sched latency -p 1234

# 内核函数调用统计（不需要调试符号也能统计次数）
perf probe --add tcp_sendmsg
perf stat -e probe:tcp_sendmsg -a -- sleep 5
```

#### 注意事项

- 默认参数`kernel.perf_event_paranoid=2`时，普通用户只能测量自己进程且拿不到内核级数据；生产环境建议保持默认，用root执行或临时调整为1
- 采样有开销，高频全系统采样（如-F 999 -a -g）会明显影响繁忙服务器，生产常用99Hz
- 火焰图需要`-g`栈展开；Java进程需与`perf-map-agent`配合才能得到Java方法名，或用async-profiler等专门工具
- 容器内使用需加`--cap-add SYS_ADMIN`或`--pid=host`并挂载debugfs
- perf.data文件可能较大，长时间采样注意磁盘空间（`perf record`默认写当前目录）

---

### 4.2 ftrace——内核函数跟踪框架

#### 功能说明

ftrace是Linux内核内置的追踪框架（2008年合入内核2.6.27），通过tracefs文件系统提供控制接口，能跟踪内核函数调用、调用图、函数耗时、最大延迟、事件（tracepoint）等，几乎零依赖（无需安装额外软件），是内核路径分析的基石。trace-cmd与KernelShark是其常用前端。

#### 接口位置

| 路径 | 说明 |
| --- | --- |
| `/sys/kernel/tracing` | tracefs挂载点（现代内核推荐），内核4.1+ |
| `/sys/kernel/debug/tracing` | debugfs下的兼容挂载点（旧内核路径） |

两个路径通常指向同一套数据，可用其一。检查挂载：

```bash
mount | grep -E 'tracefs|debugfs'
# 如未挂载
mount -t tracefs nodev /sys/kernel/tracing
```

#### 关键控制文件

| 文件 | 说明 |
| --- | --- |
| `available_tracers` | 可用跟踪器列表（function、function_graph、nop等） |
| `current_tracer` | 当前启用跟踪器，写`nop`关闭 |
| `tracing_on` | 总开关（1开0关），关闭开销低但不复位跟踪器 |
| `trace` | 读取完整缓冲内容（静态快照） |
| `trace_pipe` | 流式读取（消费型，阻塞等待新数据） |
| `set_ftrace_filter` | 只跟踪指定函数（支持通配） |
| `set_graph_function` | function_graph模式下指定根函数（只跟踪其调用树） |
| `set_ftrace_pid` | 只跟踪指定PID的函数调用 |
| `tracing_thresh` | function_graph耗时阈值（微秒），只记录超阈值调用 |
| `events/` | tracepoint事件目录（如sched、syscalls、block） |
| `options/funcgraph-abstime`等 | 输出格式选项 |

#### 输出解读

function_graph跟踪`vfs_read`示例：

```bash
cd /sys/kernel/tracing
echo nop > current_tracer          # 先复位
echo function_graph > current_tracer
echo vfs_read > set_graph_function  # 只跟踪vfs_read调用树
echo 1 > tracing_on
cat trace_pipe                      # 实时观察
echo 0 > tracing_on
echo nop > current_tracer           # 记得复位
```

```
# tracer: function_graph
#
 2)               |  vfs_read() {
 2)               |    rw_verify_area() {
 2)   0.181 us   |      security_file_permission();
 2)   0.983 us   |    }
 2)               |    ext4_file_read_iter() {
 2)   1.245 us   |      generic_file_read_iter();
 2)   2.517 us   |    }
 2)   5.336 us   |  }
```

- 左侧括号缩进表示调用层级，函数后`{}`表示其子树
- `x.xxx us`为该函数（含子树）耗时，**耗时长的分支即排查重点**
- `#`开头为跟踪文件头注释

function跟踪器（带调用者）：

```bash
echo function > current_tracer
echo 1 > /sys/kernel/tracing/tracing_on
cat /sys/kernel/tracing/trace | head -20
# 输出格式： 3)   1.234 us |  kfree [<ffffffff81234567>] from vfs_read+0x20/0x100
```

#### 实战示例

```bash
# 统计某个内核函数5秒内被调用的次数（用function_profile_enabled）
cd /sys/kernel/tracing
echo 1 > function_profile_enabled
sleep 5
echo 0 > function_profile_enabled
cat trace_stat/function0 | head   # 每个CPU的输出

# 只跟踪PID 1234且耗时超过100微秒的内核调用树
echo 1234 > set_ftrace_pid
echo function_graph > current_tracer
echo 100 > tracing_thresh
cat trace_pipe

# 跟踪块I/O事件（tracepoint方式）
cd /sys/kernel/tracing
echo 1 > events/block/enable
cat trace_pipe

# 用trace-cmd前端替代手工操作文件
trace-cmd record -p function_graph -l vfs_read -T sleep 5
trace-cmd report
```

#### 注意事项

- function跟踪器对系统有数倍到十几倍性能影响（编译进内核的mcount桩），**function_graph更重**，生产环境使用时尽量用`set_graph_function`/`set_ftrace_filter`/`tracing_thresh`收窄范围，用完立即`echo nop > current_tracer`
- 缓冲区大小由`buffer_size_kb`控制，默认1.4MB左右，高频事件下可能丢失数据（trace文件头会提示`X events dropped`）
- 与perf工具同源（perf也复用ftrace事件），但不能同时占用同一tracepoint的两种消费者模式
- 内核编译需开启CONFIG_FUNCTION_TRACER等选项（主流发行版默认开启）

---

### 4.3 eBPF（bcc / bpftrace）——可编程内核追踪

#### 功能说明

eBPF（extended Berkeley Packet Filter）允许在安全沙箱中向内核动态加载小程序（BPF程序），挂接到系统调用、内核函数、tracepoint、网络栈等任意位置做过滤、统计和监控，开销低、无需重新编译内核、无需ptrace附加进程，是当前Linux动态追踪的主流方案。

常用工具链两套：

- **bcc**：Python/C工具集，内置大量开箱即用脚本（/usr/share/bcc/tools/）
- **bpftrace**：类awk的单行脚本语言，适合快速定制查询

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y bcc-tools bpftrace` |
| Debian/Ubuntu | `apt install -y bpfcc-tools bpftrace` |

注意：Ubuntu的bcc命令带`-bpfcc`后缀（如`execsnoop-bpfcc`），RHEL系直接是`execsnoop`。

#### bcc常用工具

| 工具 | 功能 | 用法 |
| --- | --- | --- |
| execsnoop | 跟踪新进程执行（含短命进程） | `execsnoop` |
| opensnoop | 跟踪open系统调用 | `opensnoop` |
| biolatency | 块I/O延迟直方图 | `biolatency` |
| biosnoop | 每个块I/O的详情（含进程） | `biosnoop` |
| runqlat | 调度器运行队列延迟直方图 | `runqlat` |
| profile | 定时CPU采样（类似perf） | `profile -F 99 10` |
| tcplife | TCP连接生命周期记录 | `tcplife` |
| tcpconnlat | TCP连接建立延迟 | `tcpconnlat` |
| ext4slower | 跟踪慢于阈值的ext4操作 | `ext4slower 10` |
| funccount | 统计内核函数调用次数 | `funccount 'vfs_*'` |
| trace | 自由跟踪内核函数 | `trace 'do_sys_open "%s", arg2'` |

#### bpftrace单行示例

```bash
# 跟踪open系统调用（追溯访问的文件）
bpftrace -e 'tracepoint:syscalls:sys_enter_openat { printf("%s %s\n", comm, str(args->filename)); }'

# 统计各进程的系统调用次数
bpftrace -e 'tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }'

# 按进程统计块I/O大小分布
bpftrace -e 'tracepoint:block:block_rq_issue { @[comm] = hist(args->bytes); }'

# 统计read系统调用耗时直方图
bpftrace -e 'kprobe:vfs_read { @start[tid] = nsecs; }
             kretprobe:vfs_read /@start[tid]/ { @us[comm] = hist((nsecs-@start[tid])/1000); delete(@start[tid]); }'

# 查看5秒调度延迟分布
bpftrace -e 'tracepoint:sched:sched_wakeup { @[comm] = hist(nsecs - args->timestamp); }'
```

#### 输出解读

execsnoop输出：

```
PCOMM            PID    PPID   RET ARGS
bash             82345  82340    0 /bin/bash -c /opt/app/check.sh
check.sh         82346  82345    0 /usr/bin/curl -s http://127.0.0.1:8080/health
```

biolatency输出（直方图）：

```
     usecs               : count     distribution
         0 -> 1          : 0        |                                        |
         2 -> 3          : 12       |**                                      |
        16 -> 31         : 542      |****************************************|
        32 -> 63         : 187      |*************                           |
       512 -> 1023       : 3        |                                        |
```

p99超过50ms说明I/O尾延迟明显，需结合biosnoop定位具体进程与设备。

#### 实战示例

```bash
# 排查"谁在频繁创建进程"（如crond脚本风暴）
execsnoop

# 排查磁盘延迟来源于哪个进程
biosnoop -Q          # -Q显示排队时间

# 排查CPU被哪些进程消耗（按栈聚合热点）
profile -F 99 -a 30

# 排查TCP连接问题（连接谁、活了多久、传了多少字节）
tcplife

# 生产常用组合：runqlat确认调度延迟
runqlat 10 1         # 10秒采样1次
```

#### 注意事项

- 需要root权限（或CAP_BPF+CAP_PERFMON，内核5.8+）
- 内核版本要求：bcc基础工具4.1+，bpftrace 4.9+，较新工具需要5.4+/5.8+
- 部分工具依赖内核配置（CONFIG_BPF_EVENTS、CONFIG_DEBUG_INFO_BTF等），主流发行版内核（RHEL8+、Ubuntu 20.04+）均满足
- 名称差异：RHEL系`execsnoop` vs Ubuntu`execsnoop-bpfcc`；两者功能相同
- 与SystemTap相比开销更低、更安全，建议新环境优先选eBPF方案

---

### 4.4 pidstat——进程级资源统计

#### 功能说明

pidstat是sysstat工具集的成员，以**指定间隔持续输出指定进程的CPU、内存、I/O、上下文切换**统计，是"确认问题进程"的核心工具，也是perf/热点分析前的第一步。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y sysstat` |
| Debian/Ubuntu | `apt install -y sysstat` |

#### 常用参数

| 参数 | 说明 |
| --- | --- |
| `-u` | CPU使用统计（默认选项） |
| `-r` | 内存统计（缺页、VSZ、RSS、%MEM） |
| `-d` | I/O统计（读写速率、iodelay） |
| `-w` | 上下文切换统计（自愿/非自愿） |
| `-t` | 显示线程级统计 |
| `-p <pid>` | 指定进程（可多个，或`ALL`） |
| `-C <name>` | 按命令名过滤（支持正则） |
| `-l` | 显示完整命令行 |
| `-h` | 水平输出（一行一条，便于解析） |
| `<间隔> <次数>` | 如`1 5`表示每秒1次共5次 |

#### 输出解读

CPU统计（`pidstat -u -p 1234 1 3`）：

```
Linux 5.4.0 (host01)    10/14/2026     _x86_64_    (8 CPU)

10:30:01 AM   UID       PID    %usr %system  %guest   %wait    %CPU   CPU  Command
10:30:02 AM  1000      1234   45.20    4.80    0.00    0.50   50.00     2  java
10:30:03 AM  1000      1234   46.10    5.10    0.00    0.20   51.20     2  java
Average:     1000      1234   45.65    4.95    0.00    0.35   50.60     -  java
```

- `%usr`/`%system`：用户态/内核态CPU占比；**%system高说明系统调用、锁、中断处理多**
- `%wait`：等待CPU运行的时间占比（间接反映CPU争抢），非0且上升说明CPU竞争激烈
- `%CPU`超过100%表示多核并行（线程数多的进程），上限为线程数
- **第一行是自进程启动以来的平均值，应忽略**，看后续区间值

内存统计（`pidstat -r -p 1234 1`）：

```
UID    PID  minflt/s  majflt/s     VSZ     RSS   %MEM  Command
1000  1234    512.00      0.00  5218044  2097152  13.00  java
```

- `minflt/s`：次要缺页（页在内存中调页表映射），**持续很高说明内存分配/回收频繁**
- `majflt/s`：主要缺页（需读磁盘），非0且高说明内存不足或page cache被挤出
- `VSZ`虚拟地址空间、`RSS`实际物理内存占用

I/O统计（`pidstat -d -p 1234 1`）：

```
UID    PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command
1000  1234      0.00   2048.00      0.00      12  java
```

- `kB_rd/s`/`kB_wr/s`：每秒读/写磁盘速率
- `iodelay`：进程因I/O被阻塞的**时钟节拍数**（受I/O延迟影响），数值高说明该进程大量时间在等磁盘

上下文切换（`pidstat -w -p 1234 1`）：

```
UID    PID   cswch/s nvcswch/s  Command
1000  1234   312.00      4.00  java
```

- `cswch/s`：自愿切换（等待资源而主动让出CPU，如等I/O、等锁）
- `nvcswch/s`：非自愿切换（时间片耗尽被抢占），**高说明CPU竞争激烈**

#### 实战示例

```bash
# 找出当前占CPU最高的进程（每秒刷新）
pidstat -u 1 | sort -k8 -rn | head

# 查看进程所有线程的CPU使用（定位热点线程）
pidstat -u -t -p 1234 1

# 确认进程是否有I/O瓶颈
pidstat -d 1 5

# 排查CPU密集Java进程的线程级争抢
pidstat -w -t -p 1234 1 5
```

#### 注意事项

- 无`-p`时默认只显示活跃进程（当次间隔内有消耗的进程）
- 长时间数据可用sar归档数据追溯（见6.8节sar说明）
- `%wait`字段需要sysstat 11.5.6+内核4.7+，旧版本无此列

---

### 4.5 SystemTap（stap）——内核探针脚本

#### 功能说明

SystemTap通过脚本语言定义探针（probe），在内核函数、系统调用、tracepoint等位置插桩执行自定义逻辑，用于深度内核行为分析和问题定位。相比eBPF，它在老内核（RHEL6/7时代）上更成熟，语法灵活、可编程性强，但需要内核调试信息，部署较重。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y systemtap systemtap-runtime kernel-devel kernel-debuginfo` |
| Debian/Ubuntu | `apt install -y systemtap linux-headers-$(uname -r)` |

验证环境可用性：

```bash
stap-prep                 # 自动安装所缺依赖（部分版本可用）
stap -v -e 'probe begin { printf("hello\n") exit() }'
```

#### 脚本基础结构

```c
# 观察点定义：probe <类型>.<位置> [条件] { 处理函数 }
probe begin {
    printf("trace started\n")
}

probe syscall.open {
    printf("%s(%d) open %s\n", execname(), pid(), filename)
}

probe kernel.function("do_sys_open") {
    printf("do_sys_open called by %s\n", execname())
}

probe end {
    printf("trace ended\n")
}
```

常用探针点类型：

| 类型 | 说明 | 示例 |
| --- | --- | --- |
| `begin` / `end` | 脚本开始/结束 | `probe begin {}` |
| `syscall.*` | 系统调用 | `probe syscall.read` |
| `kernel.function("func")` | 内核函数入口 | `probe kernel.function("tcp_sendmsg")` |
| `kernel.function("func").return` | 内核函数返回 | 配合`$return`取返回值 |
| `kernel.trace("tp")` | 内核tracepoint | `probe kernel.trace("sched_switch")` |
| `timer.*` | 定时触发 | `probe timer.s(5) {}` |
| `process.*` | 用户态进程探针 | `probe process("/usr/bin/nginx").function("main")` |

#### 常用命令参数

| 参数 | 说明 |
| --- | --- |
| `stap script.stp` | 运行脚本（编译+加载，首次编译较慢） |
| `stap -e '...'` | 命令行直接写脚本 |
| `-v` | 详细模式（显示编译过程） |
| `-g` | guru模式（允许更危险的操作） |
| `-p1`~`-p5` | 分阶段执行（1解析、2生成、4编译、5运行），便于调试 |
| `-L` | 列出探针及可用变量（`stap -L 'syscall.open'`） |
| `-o <file>` | 输出到文件 |
| `-x <pid>` | 附加到指定进程 |

#### 输出与实战示例

```bash
# 统计5秒内按进程分类的open调用次数
stap -e '
global opens
probe syscall.open { opens[execname()]++ }
probe timer.s(5) {
    foreach (p in opens-) printf("%-20s %d\n", p, opens[p])
    exit()
}'

# 跟踪超过10ms的read调用
stap -e '
probe syscall.read.return {
    if ($return > 0) {
        # 用局部变量记录的时间差作判断（需配合入口探针）
    }
}'
# 更规范写法：
stap -e '
global start
probe syscall.read { start[tid()] = gettimeofday_us() }
probe syscall.read.return /start[tid()]/ {
    delta = gettimeofday_us() - start[tid()]
    if (delta > 10000) printf("%s read took %d us\n", execname(), delta)
    delete start[tid()]
}'

# 分析调度延迟
stap -e '
probe scheduler.wakeup { printf("%s woken\n", task_execname(task)) }
'
```

#### 注意事项

- 需要**内核调试信息包**（kernel-debuginfo/linux-image-dbgsym），体积可达数百MB，未安装时脚本编译报`missing unwind/symbol data`错误
- 每个脚本都要编译为内核模块再加载，**首次执行有编译开销（数秒到数十秒）**，建议预编译缓存（`stap -p4`）
- 生产稳定性风险高于eBPF（脚本缺陷可能导致内核崩溃），测试环境验证后再上生产
- 新内核（5.x+）与eBPF并存，官方推荐新项目逐步迁移到eBPF/bcc
- 需要root权限

---

### 4.6 LTTng——低开销多线程追踪框架

#### 功能说明

LTTng（Linux Trace Toolkit: next generation）是面向生产环境设计的低开销追踪框架，能同时采集内核事件（sched、irq、block、syscall等）与用户态应用事件（符合lttng-ust的应用或已插桩的应用），适合跟踪多线程应用、长时间采集和事后离线分析，输出是CTF（Common Trace Format）格式，可用babeltrace、Trace Compass可视化。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y lttng-tools lttng-ust lttng-modules-dkms` |
| Debian/Ubuntu | `apt install -y lttng-tools lttng-modules-dkms liblttng-ust-dev` |

#### 常用命令流程

LTTng采用会话（session）模型，典型流程为：创建会话→配置通道与事件→启动→复现问题→停止→分析。

| 命令 | 说明 |
| --- | --- |
| `lttng create <name> -o <dir>` | 创建会话（默认输出~/lttng-traces/） |
| `lttng list -k` / `lttng list -u` | 列出可用内核/用户态事件 |
| `lttng enable-event -k <事件>` | 启用内核事件，如`sched_switch`；`-k -a`启用全部 |
| `lttng enable-channel -k <名> --num-subbuf N --subbuf-size S` | 创建通道并调整缓冲（减小写入压力） |
| `lttng start` / `lttng stop` | 启动/停止记录 |
| `lttng view` | 用babeltrace查看当前会话数据 |
| `lttng destroy` | 销毁会话释放资源 |

#### 实战示例

```bash
# 1. 创建会话
lttng create perf_session -o /data/trace

# 2. 确认可用内核事件
lttng list -k | head -30

# 3. 启用调度与块I/O事件
lttng enable-event -k sched_switch,sched_wakeup
lttng enable-event -k block_rq_issue,block_rq_complete

# 4. 启动追踪，复现问题
lttng start
# ... 复现操作 ...
lttng stop

# 5. 查看原始事件流
lttng view | head -50

# 6. 销毁会话
lttng destroy
```

输出（babeltrace格式）：

```
[10:32:01.123456789] (+0.000001234) host01 sched_switch: { cpu_id = 3 }, { prev_comm = "java", prev_tid = 1234, prev_prio = 120, prev_state = 0, next_comm = "kworker/3:1", next_tid = 567, next_prio = 120 }
```

- 行首时间戳与增量；`cpu_id`显示事件所在CPU
- `prev_state=0`表示java是被抢占的（非自愿切换），配合sched_wakeup可计算**唤醒到运行的调度延迟**

#### 分析工具

- `babeltrace <trace-dir>`：文本转换
- `babeltrace2`：新版转换器
- `Trace Compass`（Eclipse）：图形化分析，可生成调度延迟、中断分布等视图

#### 注意事项

- 内核模块由DKMS管理（lttng-modules-dkms），内核升级后会自动重编
- 默认通道为per-CPU内存缓冲（内存模式），会话结束时落盘；若需实时落盘用`lttng enable-channel -k --output mmap_file`（性能稍差）
- 用户态事件需要应用链接liblttng-ust并在代码中打点（tracepoint），未插桩的应用无法直接采集用户态事件
- 多线程高并发场景下，LTTng的每个事件头部开销约数十到数百纳秒，仍建议先用默认事件集验证开销后再放开
- 需要root权限（内核事件）；`lttng`普通用户需要加入`tracing`组

---

## 5. 驱动层/网络接口工具详解

### 5.1 tcpdump——网络数据包抓取

#### 功能说明

tcpdump是事实标准的命令行抓包工具，基于libpcap，支持BPF过滤表达式在内核层过滤，适用于网络故障排查（重传、乱序、丢包）、协议分析、应用问题定位（如HTTP请求异常）、安全取证。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y tcpdump` |
| Debian/Ubuntu | `apt install -y tcpdump` |

#### 常用参数

| 参数 | 说明 |
| --- | --- |
| `-i <接口>` | 指定网卡（`-i any`监听全部接口） |
| `-nn` | 不解析主机名和端口名（加速、避免DNS干扰） |
| `-c <n>` | 抓满n个包后退出 |
| `-w <file.pcap>` | 写入文件（后续用Wireshark/tshark分析） |
| `-r <file.pcap>` | 读取pcap文件 |
| `-s <len>` | 每包截取长度，`-s 0`表示完整包 |
| `-A` | 以ASCII显示包内容（看HTTP文本） |
| `-X` | 十六进制+ASCII显示 |
| `-e` | 显示链路层头（MAC地址） |
| `-v` / `-vv` / `-vvv` | 详细程度递增（TTL、校验和、协议细节） |
| `-l` | 行缓冲（配合管道实时处理） |
| `-D` | 列出可用网卡 |
| `-Z <user>` | 抓包后降权到指定用户（root抓、非root写） |

#### 过滤表达式

| 表达式 | 说明 |
| --- | --- |
| `host 10.0.0.1` | 主机过滤 |
| `src 10.0.0.1` / `dst 10.0.0.1` | 方向过滤 |
| `port 80` / `portrange 8000-9000` | 端口/端口段 |
| `net 192.168.1.0/24` | 网段 |
| `tcp` / `udp` / `icmp` / `arp` | 协议 |
| `tcp[tcpflags] & (tcp-syn\|tcp-fin) != 0` | TCP标志位过滤 |
| `greater 100` / `less 100` | 包长度 |
| `and` / `or` / `not` | 逻辑组合 |

#### 输出解读

```bash
$ tcpdump -i eth0 -nn port 3306 -c 2
10:23:45.123456 IP 10.0.0.10.54321 > 10.0.0.15.3306: Flags [S], seq 1234567890, win 64240, options [mss 1460,sackOK,TS val 1234567 ecr 0,nop,wscale 7], length 0
10:23:45.124001 IP 10.0.0.15.3306 > 10.0.0.10.54321: Flags [S.], seq 987654321, ack 1234567891, win 28960, options [mss 1460,sackOK,TS val 2233445 ecr 1234567,nop,wscale 7], length 0
```

字段说明：

- `Flags`：`[S]`SYN、`[S.]`SYN+ACK、`[.]`ACK、`[P.]`PSH+ACK、`[F.]`FIN+ACK、`[R]`RST
- `seq`/`ack`：序列号/确认号
- `win`：接收窗口大小，**持续为0或极小说明对端/本端应用读取慢（窗口阻塞）**
- `length 0`：纯控制报文（无载荷）
- `options [mss 1460,sackOK,...]`：TCP选项，排查MTU问题时关注MSS

#### 实战示例

```bash
# 抓取与数据库的通信并保存（重传排查）
tcpdump -i eth0 -nn -w /tmp/db.pcap host 10.0.0.15 and port 3306

# 查看HTTP请求内容（明文场景）
tcpdump -i eth0 -nn -s 0 -A 'tcp port 80 and tcp[((tcp[12:1] & 0xf0) >> 2):4] = 0x47455420'

# 统计SYN包（判断是否有连接风暴或半连接攻击）
tcpdump -i eth0 -nn 'tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack == 0' -c 100

# 抓ICMP（ping是否通）
tcpdump -i eth0 -nn icmp

# 配合tshark解析重传率
tshark -r /tmp/db.pcap -q -z io,stat,0,"COUNT(tcp.analysis.retransmission) tcp.analysis.retransmission"
```

#### 注意事项

- 需要root或`CAP_NET_RAW`；部分发行版可把用户加入`pcap`组
- `-i any`在部分场景抓到的包带VLAN头或无链路层头（liunx cooked模式），分析细节时优先指定具体接口
- 高流量场景抓包开销大，务必用过滤表达式收窄，`-s`限制截取长度
- 网卡TSO/GSO开启时本机发出的包校验和可能显示错误（`-vv`下bad checksum），这是抓包工具的已知现象，不代表链路错误
- 生产环境抓包文件可能快速膨胀，用`-c`、`-G/-W`切割（如`-G 600 -W 6`每10分钟一个文件保留6个），并及时转移分析

---

### 5.2 iptraf——实时网络流量监控

#### 功能说明

iptraf（新版为iptraf-ng）是交互式网络流量监控工具，提供IP流量监控、接口统计、端口流量明细等视图，用于快速观察网络带宽走向、发现异常流量。其现代替代工具为iftop、nload、nethogs，但iptraf-ng在无额外安装环境的场景仍有价值。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y iptraf-ng` |
| Debian/Ubuntu | `apt install -y iptraf-ng` |

#### 使用方式

```bash
# 交互式菜单（需要root）
iptraf-ng

# 直接进入IP流量监控（指定接口）
iptraf-ng -i eth0

# 查看接口统计
iptraf-ng -s eth0

# 使用指定接口列表
iptraf-ng -d eth0
```

交互式菜单主要功能：

| 菜单项 | 说明 |
| --- | --- |
| IP traffic monitor | 按连接实时显示双向流量（TCP/UDP） |
| General interface statistics | 各接口总吞吐与包速率 |
| Detailed interface statistics | 接口协议分布（TCP/UDP/ICMP等包数与字节） |
| Statistical breakdowns | 按包大小/端口分类统计 |
| LAN station monitor | 二层MAC流量统计 |

#### 输出解读

IP流量监控视图关键列：

```
Proto/Port      Pkts     Byte  Pkts     Byte  |  Flags
                In       In    Out      Out   |
TCP/3306        1234   2.1M     987    1.2M   |  -A-- 
```

- `In`/`Out`方向在顶部显示本机IP与对端IP（上下两组对应双向）
- `Pkts/Byte In`与`Out`分别为收发包数与字节数
- `Flags`：TCP状态标记，`A`ACK、`S`SYN、`P`PSH、`R`RST、`F`FIN

#### 实战示例

```bash
# 快速确认是哪个连接在占带宽
iptraf-ng -i eth0
# 进入后选择对应接口，观察In/Out字节数增长最快的行

# 观察接口是否有大量错误/丢弃包（对比ifconfig/ip -s link）
iptraf-ng -s eth0
```

#### 注意事项

- 需要root权限；运行在终端（非图形）环境
- iptraf-ng的交互界面依靠全屏字符终端，SSH会话需保证TERM设置正确（建议xterm或linux）
- 旧版iptraf对系统时间设置敏感，已停维护，建议统一使用iptraf-ng
- 若仅需按连接看带宽，`iftop -i eth0`更直观；若需按进程看带宽，用`nethogs eth0`
- 流量抓取基于原始socket，繁忙网卡上对系统有轻微额外负载

---

### 5.3 ethtool——网卡状态与驱动配置

#### 功能说明

ethtool用于查询和配置网卡的物理层参数（速率、双工、自协商）、驱动信息、硬件统计、offload特性、中断合并、环形缓冲区等，是网络性能调优与网卡故障排查的标准工具。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y ethtool` |
| Debian/Ubuntu | `apt install -y ethtool` |

#### 常用参数

| 参数 | 说明 |
| --- | --- |
| `ethtool eth0` | 基础信息：速率、双工、链路状态、自协商 |
| `-i` | 驱动名、驱动版本、固件版本 |
| `-S` | 硬件统计（rx_errors、rx_dropped、tx_errors、tx_dropped等，字段随驱动而异） |
| `-g` / `-G` | 查看/设置ring buffer大小（收发描述符数量） |
| `-k` / `-K` | 查看/设置offload特性（tso、gso、gro、rx/tx-checksumming） |
| `-l` / `-L` | 查看/设置队列数（多队列RSS） |
| `-a` / `-A` | 查看/设置pause帧（流控） |
| `-c` / `-C` | 查看/设置中断合并参数 |
| `-m` | 光模块信息（DDM） |
| `-t` | 网卡自检（部分驱动支持） |
| `--show-priv-flags` | 驱动私有开关（如某些网卡的LLDP代理开关） |

#### 输出解读

```bash
$ ethtool eth0
Settings for eth0:
        Supported ports: [ TP ]
        Supported link modes:   1000baseT/Full
        Supports auto-negotiation: Yes
        Advertised link modes:  1000baseT/Full
        Speed: 1000Mb/s
        Duplex: Full
        Port: Twisted Pair
        Auto-negotiation: on
        Link detected: yes
```

- `Speed`：协商速率。**若显示100Mb/s而交换机是千兆，检查网线（五类线质量）或双工协商**
- `Duplex: Half`：半双工是罕见但致命的性能问题（大量冲突），必须排查
- `Link detected: no`：物理链路断开

```bash
$ ethtool -S eth0 | grep -E 'error|drop|miss'
     rx_errors: 0
     rx_dropped: 1256
     tx_errors: 0
     tx_dropped: 0
     rx_missed_errors: 32
```

- `rx_dropped`增长：驱动/内核丢弃（多为ring buffer不足或软中断处理不及时）
- `rx_missed_errors`：硬件FIFO溢出（网卡收包快于驱动取走），应增大ring buffer
- `tx_dropped`：发送队列满

#### 实战示例

```bash
# 排查"网慢"：先确认协商速率与双工
ethtool eth0 | grep -E 'Speed|Duplex|Link'

# 排查丢包：查看硬件统计增长
ethtool -S eth0 | grep -iE 'err|drop|miss'
watch -n 1 'ethtool -S eth0 | grep -iE "err|drop"'

# 增大ring buffer缓解收包丢弃（先看当前值）
ethtool -g eth0
ethtool -G eth0 rx 4096 tx 4096

# 查看多队列是否生效（CPU多核场景）
ethtool -l eth0
```

#### 注意事项

- `-S`统计字段名因驱动不同差异较大，用`grep -i`过滤关键指标
- ring buffer调大占用更多内核内存，极端值可能导致驱动初始化失败，按需小步调整
- 调整中断合并（`-C`）在低延迟场景可减少延迟抖动，但提高CPU占用，需权衡
- bond/bridge/vlan等虚拟接口多数参数只读或不可用，需对物理成员口操作
- 服务器网卡建议固件与驱动保持厂商推荐版本，`ethtool -i`可查版本

---

### 5.4 lldptool——链路层拓扑发现

#### 功能说明

lldptool是LLDP（Link Layer Discovery Protocol，IEEE 802.1AB链路层发现协议）客户端工具，配合lldpad守护进程向直连交换机发送/接收LLDP报文中，从而获取"本机网卡接在交换机的哪个端口、对端设备名、管理地址、VLAN"等物理拓扑信息，是数据中心链路接线排查的利器。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y lldpad` |
| Debian/Ubuntu | `apt install -y lldpad` |

#### 使用前提

```bash
# 启动lldpad守护进程
systemctl enable --now lldpad

# 在指定网卡上开启LLDP发送/接收（默认可能关闭）
lldptool set-lldp -i eth0 adminStatus=rxtx
```

#### 常用命令

| 命令 | 说明 |
| --- | --- |
| `lldptool -t -i eth0` | 显示网卡当前LLDP配置与邻居TLV信息（最常用，`-t`即show） |
| `lldptool -T -i eth0` | 显示LLDP统计 |
| `lldptool -i eth0 -g nb -V sys-name` | 查询邻居系统名（get） |
| `lldptool -i eth0 -g nb -V port-desc` | 查询邻居端口描述 |
| `lldptool -i eth0 -g nb -V mgmt-addr` | 查询邻居管理地址 |
| `lldptool -i eth0 -V port-id` | 查询本机端口ID |
| `lldptool set-lldp -i eth0 adminStatus=rxtx` | 设置该网卡收發LLDP |

#### 输出解读

```bash
$ lldptool -t -i eth0
Chassis ID TLV
        MAC: 00:1a:2b:3c:4d:5e
Port ID TLV
        Ifname: GigabitEthernet1/0/24
Time to Live TLV
        120
System Name TLV
        core-sw-01
System Description TLV
        Cisco IOS Software, Catalyst 2960
Management Address TLV
        IPv4: 10.0.0.254
Port VLAN ID TLV
        VLAN: 100
```

- `Chassis ID`：对端交换机MAC
- `Port ID`：本机网线接在交换机的**具体端口名**（如GigabitEthernet1/0/24）
- `System Name`：交换机主机名；`Management Address`：交换机管理地址
- `Port VLAN ID`：接入VLAN号，排查VLAN配置错误

#### 实战示例

```bash
# 确认服务器网线到底插在交换机的哪个口
lldptool -t -i eth0 | grep -A2 'Port ID'

# 批量收集所有网卡的邻居交换机信息
for i in $(ls /sys/class/net | grep -E '^eth|^en'); do
  echo "== $i =="; lldptool -t -i $i | grep -A2 -E 'Port ID|System Name'
done

# 确认接入VLAN是否正确
lldptool -t -i eth0 | grep -A2 'Port VLAN'
```

#### 注意事项

- 前提是对端交换机**开启了LLDP**且允许发送（部分交换机默认关闭或只收不发）
- lldpad服务未运行时lldptool报连接错误
- 各厂商对TLV支持程度不同，部分字段可能缺失
- 采集的是二层直连邻居信息，跨越三层或经过非LLDP设备时不可见
- `-g nb`表示netlink邻居信息查询组，参数名与TLV类型对应关系可用`lldptool help`查看

---

### 5.5 snmpget——SNMP设备状态查询

#### 功能说明

snmpget来自net-snmp工具集，通过SNMP协议向交换机、路由器、存储、UPS等网络设备查询指定OID（对象标识符）的值，是服务器侧核查网络设备指标、与网管系统联调的标准工具。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y net-snmp-utils` |
| Debian/Ubuntu | `apt install -y snmp` |

#### 常用参数

| 参数 | 说明 |
| --- | --- |
| `-v 1\|2c\|3` | SNMP版本（2c最常用） |
| `-c <community>` | 团体名（相当于密码，v1/v2c） |
| `<host>` | 目标设备IP或域名 |
| `<OID>` | 对象标识符，可用数字（.1.3.6.1...）或MIB符号名（需加载MIB文件） |
| `-t <秒>` | 超时时间 |
| `-r <次>` | 重试次数 |
| `-On` / `-Oqv` | 输出格式：数字OID / 简值 |
| `-u` / `-l` / `-a` / `-A` | v3认证参数：用户名/安全级别/认证算法/认证密码 |

#### 常用OID示例

| OID | 含义 |
| --- | --- |
| `.1.3.6.1.2.1.1.1.0` | sysDescr设备描述 |
| `.1.3.6.1.2.1.1.3.0` | sysUpTime运行时长（单位：TimeTicks，1/100秒） |
| `.1.3.6.1.2.1.1.5.0` | sysName设备名 |
| `.1.3.6.1.2.1.2.2.1.10.<ifIndex>` | ifInOctets接口入字节计数 |
| `.1.3.6.1.2.1.2.2.1.16.<ifIndex>` | ifOutOctets接口出字节计数 |

#### 输出解读

```bash
$ snmpget -v2c -c public 10.0.0.254 .1.3.6.1.2.1.1.3.0
SNMPv2-MIB::sysUpTime.0 = Timeticks: (123456789) 14 days, 6:56:07.89
```

- 返回OID、类型与值；`sysUpTime`可用于确认设备是否重启过（对比历史）
- 批量遍历用`snmpwalk`（如`snmpwalk -v2c -c public 10.0.0.254 .1.3.6.1.2.1.2.2.1.10`列出所有接口入流量）

#### 实战示例

```bash
# 查询交换机运行时长与名称
snmpget -v2c -c public 10.0.0.254 .1.3.6.1.2.1.1.3.0 .1.3.6.1.2.1.1.5.0

# 查询接口1的入/出流量计数字节
snmpget -v2c -c public 10.0.0.254 .1.3.6.1.2.1.2.2.1.10.1 .1.3.6.1.2.1.2.2.1.16.1

# 遍历全部接口流量（配合ifIndex对应表）
snmpwalk -v2c -c public 10.0.0.254 .1.3.6.1.2.1.2.2.1.10

# 测试目标设备SNMP可达性
snmpget -v2c -c public -t 2 -r 1 10.0.0.254 .1.3.6.1.2.1.1.1.0
```

#### 注意事项

- v2c明文传输团体名，生产建议用v3（认证+加密）；团体名泄露等于设备信息泄露
- 目标设备需启用SNMP服务并配置访问控制（ACL限制source IP）
- OID需要设备MIB支持；厂商私有指标需加载对应MIB文件（`-m`参数或`MIBDIRS`环境变量）
- 计数器类OID（ifInOctets等）是累计值，计算速率需两次采样相减除以间隔
- 与Zabbix/Prometheus（snmp_exporter）集成时，本工具可作为联调验证手段

---

## 6. 硬件层（CPU/内存）工具详解

### 6.1 top / htop——实时资源监控

#### 功能说明

top是procps-ng自带的实时系统监视器，按周期刷新显示系统总体状态（负载、CPU、内存、交换）与进程列表排序，是登录服务器后的第一眼工具。htop是其功能增强版，提供彩色界面、鼠标操作、树形视图与更便捷的排序过滤。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `top`随procps-ng预装；`yum install -y htop`（需epel） |
| Debian/Ubuntu | `top`随procps预装；`apt install -y htop` |

#### top交互快捷键

| 按键 | 功能 |
| --- | --- |
| `P` | 按CPU使用率排序（默认） |
| `M` | 按内存使用率排序 |
| `T` | 按运行时间排序 |
| `1` | 展开/收起每个CPU核心的明细 |
| `H` | 显示线程 |
| `c` | 显示完整命令行（再按还原） |
| `u` | 按用户过滤 |
| `k` | 发送信号（默认kill，输入PID） |
| `r` | renice调整优先级 |
| `W` | 保存当前配置（写~/.toprc） |
| `q` | 退出 |
| `-b -n 1` | 批处理模式输出一次快照（脚本用：`top -b -n 1`） |
| `-p <pid>` | 只监视指定PID |

#### 输出解读

```
top - 10:23:45 up 32 days,  4:12,  3 users,  load average: 0.52, 0.48, 0.45
Tasks: 245 total,   1 running, 244 sleeping,   0 stopped,   0 zombie
%Cpu(s):  5.2 us,  1.1 sy,  0.0 ni, 92.9 id,  0.7 wa,  0.0 hi,  0.1 si,  0.0 st
MiB Mem :  15882.3 total,   1256.2 free,   8213.5 used,   6412.6 buff/cache
MiB Swap:   8192.0 total,   8100.5 free,     91.5 used.   6281.7 avail Mem

    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   1234 app       20   0 5218044   2.0g  40216 S  12.3  13.0  3012:45 java
   5678 mysql     20   0 3123456 800.2m  16384 S   8.7   5.0   980:12  mysqld
```

头部字段要点：

- `load average`：1/5/15分钟平均负载。**负载包含可运行（R）与不可中断（D，多数为等I/O）状态的进程**；负载高于CPU核数且CPU利用率低时，瓶颈通常在磁盘I/O
- `%Cpu(s)`：`us`用户态、`sy`内核态、`wa`等I/O、`hi`硬中断、`si`软中断、`st`被虚拟化层偷走（云主机超卖指标）。`wa`持续超过30%说明磁盘瓶颈；`st`高说明宿主机争抢
- `buff/cache`：内核缓冲与页缓存，可回收；`avail Mem`才是可用内存
- 进程区：`RES`常驻物理内存、`SHR`共享内存、`S`状态（R/S/D/T/Z）、`TIME+`累计CPU时间、`%CPU`为单核百分比（可超100%）

#### 实战示例

```bash
# 批处理快照并取CPU TOP5
top -b -n 1 | head -20

# 监视特定进程群
top -p 1234,5678

# 展开每核看单核是否有热核
top   # 进入后按1

# htop中：F5树形视图、F6排序、F3搜索、F4过滤、F9直接kill
```

#### 注意事项

- top的`%CPU`是自上次刷新以来的增量计算，按`d`可调整刷新间隔
- 头部的内存used已扣除buff/cache（现代procps-ng），与`free`的口径一致
- D状态进程多时top中表现为slowly-changing负载，需配合`ps -eo state,wchan,cmd | grep ' D'`定位
- htop的颜色可配置，生产环境建议保持默认，避免误判

---

### 6.2 ps——进程状态快照

#### 功能说明

ps（process status）输出某一时刻的进程快照，支持高度自定义的输出字段与排序，是脚本化排查的基石。与top的动态监控互补：ps适合"取一次全景数据"。

#### 安装

随procps-ng预装（RHEL/CentOS与Debian/Ubuntu均默认包含）。

#### 常用用法

| 命令 | 说明 |
| --- | --- |
| `ps aux` | BSD风格：所有进程详细列表 |
| `ps -ef` | System V风格：全格式含PPID |
| `ps -eo pid,ppid,user,stat,%cpu,%mem,rss,etime,cmd --sort=-%cpu` | 自定义字段+按CPU排序 |
| `ps -eLf` | 显示线程（LWP列） |
| `ps -o lstart= -p <pid>` | 进程启动时间 |
| `ps --ppid <pid>` | 查看子进程 |
| `ps --forest` | 树形显示父子关系 |
| `ps -eo pid,stat,wchan:32,cmd` | 查看进程等待的内核函数（wchan） |

常用输出字段：

| 字段 | 含义 |
| --- | --- |
| `%cpu` | CPU使用率（自进程启动以来的平均，与top口径不同） |
| `%mem` | 内存使用率 |
| `rss` | 常驻物理内存（KB） |
| `vsz` | 虚拟内存大小（KB） |
| `etime` | 已运行时长（格式dd-hh:mm:ss） |
| `stat` | 进程状态码 |
| `wchan` | 进程当前在内核中的等待点 |

#### STAT状态码解读

| 字符 | 含义 |
| --- | --- |
| R | Running，运行或可运行 |
| S | Sleeping，可中断睡眠（正常等待） |
| D | Uninterruptible sleep，不可中断睡眠（等I/O，**卡死元凶标志**） |
| T | Stopped，暂停（Ctrl+Z或调试） |
| Z | Zombie，僵尸（父进程未回收） |
| `<` / `N` | 高优先级 / 低优先级 |
| `l` / `s` / `+` | 多线程 / 会话领导 / 前台进程组 |

#### 实战示例

```bash
# 按CPU排序取TOP10
ps -eo pid,user,%cpu,%mem,rss,etime,stat,cmd --sort=-%cpu | head -11

# 揪出D状态（等I/O卡住）的进程
ps -eo pid,stat,wchan:32,cmd | awk '$2 ~ /D/'

# 查看僵尸进程及其父进程
ps -eo pid,ppid,stat,cmd | awk '$3 ~ /Z/'

# 统计某Java进程的线程数
ps -o nlwp= -p 1234

# 查看子进程树
ps --forest -o pid,stat,etime,cmd -g $(ps -o sid= -p 1234)
```

#### 注意事项

- `ps aux`与`ps -ef`的%CPU均为**生命周期均值**，突发型进程会显得偏低，用top/pidstat看瞬时值
- 僵尸进程自身不占资源，但大量僵尸说明父进程回收逻辑有问题
- LONG格式`-ef`截断命令行时用`--cols`加宽或`-w`（如`ps -efww`）

---

### 6.3 mpstat——多核CPU使用率分析

#### 功能说明

mpstat来自sysstat包，输出每个CPU核心的利用率分解（用户态、内核态、I/O等待、中断、虚拟化窃取等），用于判断"是整体CPU忙还是某个核心忙""忙在哪一类消耗上"。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y sysstat` |
| Debian/Ubuntu | `apt install -y sysstat` |

#### 常用参数

| 参数 | 说明 |
| --- | --- |
| `-P ALL` | 显示所有CPU核心（不加则只有平均值） |
| `-P 0,1` | 显示指定核心 |
| `<间隔> <次数>` | 如`1 5` |
| `-I <SUM\|CPU\|ALL>` | 各类中断统计（`-I SUM`中断总数、`-I CPU`每核中断） |
| `-u` | CPU利用率（默认） |
| `-o JSON` | JSON格式输出 |

#### 输出解读

```bash
$ mpstat -P ALL 1 2
Linux 5.4.0 (host01)   10/14/2026   _x86_64_    (8 CPU)

10:30:01 AM  CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
10:30:02 AM  all    5.05    0.00    1.01    0.50    0.00    0.25    0.00    0.00    0.00   93.19
10:30:02 AM    0    4.00    0.00    2.00    1.00    0.00    0.00    0.00    0.00    0.00   93.00
10:30:02 AM    1   32.00    0.00    3.00    0.00    0.00    1.00    0.00    0.00    0.00   64.00
```

- **第一行`all`前后的平均值不要看**（自启动以来的平均），只分析各采样行
- `%iowait`：CPU空闲且有未完成磁盘I/O的时间占比，**高说明磁盘慢**（注意：该指标反映I/O的同时也依赖CPU空闲，判断磁盘瓶颈应主要看iostat）
- `%irq`/`%soft`：硬/软中断消耗，网络小包风暴常表现为某核`%soft`高
- `%steal`：虚拟机被宿主机抢走的时间，**云主机性能抖动首先看这个值**
- `%guest`：CPU花在运行虚拟机上的时间
- 某单核%usr接近100%而其他核空闲：应用未利用多核（单线程瓶颈）

#### 实战示例

```bash
# 全核每秒刷新，观察是否有单核热点
mpstat -P ALL 1

# 查看每核中断分布（排查网卡中断集中在某核）
mpstat -P ALL -I SUM 1

# 一键查看I/O等待最重的核心
mpstat -P ALL 1 5 | awk '$6 > 20 {print}'
```

#### 注意事项

- 核心号与逻辑CPU编号对应，可通过`lscpu`查看拓扑（socket/core/thread）
- `%iowait`的统计口径在社区有讨论：它表示"CPU空闲时存在未完成I/O"，**不等于CPU被I/O阻塞的时间**，磁盘瓶颈必须结合iostat的await/%util判断
- 虚拟机中`%steal`持续高于5%说明宿主机资源争抢严重，需与云平台侧核查

---

### 6.4 vmstat——内存、进程与CPU综合统计

#### 功能说明

vmstat（virtual memory statistics）周期性输出进程队列、内存、swap、块I/O、中断、上下文切换与CPU的横向指标，是"一屏看全系统"的传感器，尤其擅长发现**内存压力（swap活动）与CPU饱和度（运行队列）**。

#### 安装

随procps-ng预装。

#### 常用参数

| 参数 | 说明 |
| --- | --- |
| `<间隔> <次数>` | 如`vmstat 1 10` |
| `-s` | 内存统计明细（自启动累计） |
| `-d` | 磁盘统计 |
| `-p <分区>` | 分区统计 |
| `-m` | slab统计（替代slabtop的快速视图） |
| `-w` | 宽输出（列宽舒适） |
| `-t` | 附加时间戳 |

#### 输出解读

```
procs -----------memory---------- ---swap-- -----io---- -system-- -------cpu-------
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
 1  0  93696 1285608 196608 6375424    0    0    12    45  312  582  5  1 93  1  0
 3  2  93696 620592  81920 5222400  320  512  2048  1536 1520 4830 45  8 42  5  0
```

逐列含义与判断标准：

| 列 | 含义 | 判断标准 |
| --- | --- | --- |
| r | 运行队列长度（可运行进程数） | 持续大于CPU核数说明CPU饱和（超过4倍核数严重） |
| b | 阻塞进程数（不可中断睡眠） | 持续大于0说明大量进程在等I/O |
| swpd | 已用swap（KB） | 非0不一定有问题，配合si/so看 |
| free | 空闲物理内存（KB） | 用-wh看更准，free低不等于内存不足 |
| buff/cache | 内核缓冲/页缓存 | 可回收部分 |
| si/so | swap换入/换出（KB/s） | **持续非0说明物理内存不足**，性能急剧下降 |
| bi/bo | 块设备每秒读/写块数 | 结合iostat看具体设备 |
| in | 每秒中断数 | 异常高结合mpstat -I排查 |
| cs | 每秒上下文切换数 | 异常高结合pidstat -w排查 |
| us/sy | 用户态/内核态CPU% | sy高说明系统调用/锁/中断重 |
| id | 空闲 | - |
| wa | 等I/O | 高说明磁盘慢 |
| st | 被虚拟化偷走 | 云主机超卖指标 |
| gu | 虚拟机内部运行的 CPU 时间 | 虚拟机负载指标 |
#### 实战示例

```bash
# 判断CPU是否饱和（连续观察r列）
vmstat -w 1 10

# 判断内存是否紧张（观察si/so列）
vmstat 1 | awk 'NR>2 && ($7>0 || $8>0) {print "swap active!", $0}'

# 内存详情
vmstat -s

# 每秒中断与上下文切换基线
vmstat -w 1 5 | awk '{print $12, $13}'
```

#### 注意事项

- **第一行数据是自系统启动以来的平均值**，必须从第二行起分析
- `r`列包含正在运行与等待运行的进程；Linux下`r`不含D状态（D计入b列）
- swpd非0且si/so为0时，说明是历史换出残留，当前无活动压力，无需紧张
- `-d`子命令的磁盘统计粒度不如iostat，生产排查磁盘优先用iostat -dx

---

### 6.5 free——内存使用快速查看

#### 功能说明

free显示系统物理内存与交换分区的使用概况，输出极简，是"内存够不够"的第一判断工具。关键在于正确理解`available`列。

#### 安装

随procps-ng预装。

#### 常用参数

| 参数 | 说明 |
| --- | --- |
| `-m` / `-g` / `-h` | 以MB / GB / 人类可读单位显示 |
| `-w` | 分离buffers与cache两列 |
| `-t` | 增加合计行（mem+swap） |
| `-s <秒>` | 持续刷新 |
| `-c <次>` | 配合-s指定刷新次数 |

#### 输出解读

```bash
$ free -m
              total        used        free      shared  buff/cache   available
Mem:          15882        8213        1256         305        6412        6281
Swap:          8192          91        8100
```

- `total`：物理内存总量（不含部分硬件保留）
- `used`：已用（= total - free - buff/cache）
- `free`：完全空闲的内存
- `shared`：tmpfs等共享内存占用
- `buff/cache`：内核缓冲区与页缓存，**其中大部分可被应用回收使用**
- `available`：**评估"应用还能拿到多少内存"的权威指标**——估算值，为free加上可回收的buff/cache部分（源于内核/proc/meminfo的MemAvailable，内核3.14+）
- `Swap used`：已用交换分区；持续增长且伴随vmstat的si/so活动说明内存不足

#### 实战示例

```bash
# 快速检查内存与swap（-h带单位，一眼可读）
free -h

# 持续观察（每2秒，共5次）
free -h -s 2 -c 5

# 内存"看似很高used"时的确认（看available是否充足）
free -w
```

#### 注意事项

- **`free`列低不代表内存不足**——被页缓存占用是正常且有益的（加速文件访问）；应看`available`
- `available`估算已考虑不可回收部分，但极端场景（如大量不可回收的dentry）会低估实际压力，配合`/proc/meminfo`的`MemAvailable`与slabtop复核
- 容器环境看到的是cgroup限额还是宿主机内存取决于是否挂载了对应lxcfs，注意口径
- 大页（HugePages）内存不计入常规统计，用`grep Huge /proc/meminfo`专门查看

---

### 6.6 slabtop——内核slab缓存统计

#### 功能说明

slabtop实时显示内核slab分配器（用于管理内核对象内存）的缓存明细：每个slab缓存的对象数、大小与占用内存。用于排查"free显示内存被吃掉但找不到应用进程"这一类**内核内存占用**问题（典型如dentry、inode暴涨）。

#### 安装

随procps-ng预装。

#### 常用参数

| 参数 | 说明 |
| --- | --- |
| `slabtop` | 交互式实时显示（默认每3秒刷新） |
| `-s <排序>` | 排序方式：`c`缓存大小、`a`活跃对象、`l`slab数、`u`使用率、`o`对象数、`n`名称 |
| `-o` | 一次性输出（非交互，脚本用） |
| `-d <秒>` | 刷新间隔 |
| `-n` | 只显示一次（等价-o） |

#### 输出解读

```bash
$ slabtop -o -s c
 Active / Total Objects (% used)    : 3456789 / 3501234 (98.7%)
 Active / Total Slabs (% used)      : 108765 / 108765 (100.0%)
 Active / Total Caches (% used)     : 118 / 182 (64.8%)
 Active / Total Size (% used)       : 1567890.12K / 1598765.34K (98.1%)
 Minimum / Average / Maximum Object : 0.02K / 0.35K / 16.00K

  OBJS ACTIVE  USE OBJ SIZE  SLABS OBJ/SLAB CACHE SIZE NAME
2457600 2457600 100%    0.19K  61440       40    491520K dentry
524288  524288 100%    1.02K  16384       32    524288K ext4_inode_cache
262144  262144 100%    0.58K  16384       16    262144K radix_tree_node
131072  131072  99%     0.06K   2048       64      8192K kmalloc-64
```

- `OBJS`对象总数、`CACHE SIZE`该缓存占用内存（合计即内核slab总量）
- `dentry`：目录项缓存，目录遍历/大量文件场景会暴涨（如海量小文件目录反复扫描）
- `inode_cache`/`ext4_inode_cache`：文件inode缓存，与访问过的文件数相关
- `kmalloc-*`：通用内核分配（驱动、网络栈等），泄漏时持续增长
- `radix_tree_node`/`xarray_node`：页缓存索引结构

#### 实战示例

```bash
# 一次性输出并按缓存大小排序（适合记录基线）
slabtop -o -s c | head -30

# 观察某内核模块是否有泄漏（连续采样对比总量）
slabtop -o | grep -E 'Active / Total Size'
sleep 300
slabtop -o | grep -E 'Active / Total Size'

# 直接读原始数据（不含排序展示）
head -5 /proc/slabinfo
grep -i 'task_struct\|filp' /proc/slabinfo
```

#### 注意事项

- slab内存属于内核开销，`free`中体现为used的一部分（不是buff/cache），应用侧看不到
- dentry/inode缓存大不一定是问题——内核会自动按内存压力回收（shrink），但如果**持续增长不回收**需排查是否设置过大阈值（`vm.vfs_cache_pressure`）
- 释放缓存可临时`echo 2 > /proc/sys/vm/drop_caches`（**生产慎用**，会短暂降低性能）
- 排查驱动泄漏用`kmemleak`（需内核支持CONFIG_DEBUG_KMEMLEAK）或对比模块加载/卸载前后slab增量

---

### 6.7 numastat——NUMA内存分布统计

#### 功能说明

numastat显示NUMA（Non-Uniform Memory Access）架构下各内存节点的分配命中与内存分布情况。多路服务器中，跨节点内存访问延迟明显高于本地访问（约1.5~2倍），numastat用于发现跨节点分配过多、内存分布不均等问题。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y numactl` |
| Debian/Ubuntu | `apt install -y numactl` |

#### 常用参数

| 参数 | 说明 |
| --- | --- |
| `numastat` | 默认：各节点命中/miss统计（单位：页） |
| `-m` | 各节点内存使用量（MB） |
| `-c` | 紧凑格式（所有节点一行） |
| `-p <pid>` | 指定进程的每节点内存分布 |
| `-n` | 只显示节点号（不显示名称） |
| `--sort <列>` | 按列排序：`-s`相关（部分版本支持） |

相关工具：

```bash
numactl --hardware     # 查看NUMA节点拓扑、各节点CPU与内存
numactl --show         # 当前进程策略
lscpu | grep NUMA
```

#### 输出解读

默认视图：

```
                           node0           node1
numa_hit              4823456789      4123456789
numa_miss                 123456          234567
numa_foreign              234567          123456
interleave_hit            123456          654321
local_node            4823123456      4123234567
other_node                234567          345678
```

- `numa_hit`：**在本节点成功分配**的次数（越大越好）
- `numa_miss`：本地分配失败被其它节点接管的次数（**跨节点访问的标志**）
- `other_node`：本节点为其它节点进程提供的内存次数
- `local_node`：本节点进程在本节点分配成功次数
- 判断：`numa_miss + other_node`相对`numa_hit`比例低（<1%）为健康；miss占比高说明内存局部性差

按进程视图（`numastat -p <pid>` 或 `-m`）：

```
$ numastat -m
                 node0           node1           Total
MemTotal        128000.00       128000.00       256000.00
MemFree           8000.00         6000.00        14000.00
MemUsed         120000.00       122000.00       242000.00
```

#### 实战示例

```bash
# 查看系统NUMA拓扑与节点内存余量
numactl --hardware

# 查看数据库进程的内存是否跨节点分布
numastat -p $(pidof mysqld)

# 内存分布均衡性检查（各节点MemUsed差异应小于5%）
numastat -m

# 绑定内存策略运行应用（numactl方式,需应用支持）
numactl --cpunodebind=0 --membind=0 ./app
```

#### 注意事项

- `numa_hit`等计数自系统启动累计，且**跨内核版本统计口径略有差异**（如`numa_foreign`在新内核中弱化），应重点关注比值趋势而非绝对数
- 内存零拷贝的透明大页迁移会使miss统计存在噪声
- 修复方向：BIOS开启Node Interleaving（不推荐，牺牲局部性）或应用侧用numactl绑核绑内存、数据库开启相应NUMA参数
- 单路服务器（单节点）numastat无实际意义

---

### 6.8 sar——历史资源统计与趋势分析

#### 功能说明

sar（System Activity Reporter）来自sysstat包，既能实时采样，也能读取**历史归档数据**（默认每10分钟采集一次），用于"事后复盘"：昨天下午3点CPU/内存/磁盘到底发生了什么。这是其他实时工具无法替代的能力。

#### 安装与启用

| 发行版 | 安装命令 | 启用历史采集 |
| --- | --- | --- |
| RHEL/CentOS | `yum install -y sysstat` | `systemctl enable --now sysstat`（默认已启用） |
| Debian/Ubuntu | `apt install -y sysstat` | 编辑`/etc/default/sysstat`设`ENABLED="true"`后重启sysstat服务 |

归档位置：

- RHEL/CentOS：`/var/log/sa/saDD`（DD为日期）
- Debian/Ubuntu：`/var/log/sysstat/saDD`

保留天数：RHEL系`/etc/sysconfig/sysstat`的`HISTORY=28`；Debian系`/etc/sysstat/sysstat`。

#### 常用参数

| 命令 | 说明 |
| --- | --- |
| `sar -u 1 3` | 实时CPU |
| `sar -r 1` | 内存使用（%memused、kbcached等） |
| `sar -b 1` | 整体I/O（tps、rtps、wtps、bread/s、bwrtn/s） |
| `sar -d -p 1` | 磁盘详情（含await、%util，`-p`输出设备名） |
| `sar -n DEV 1` | 网络接口吞吐（rxkB/s、txkB/s） |
| `sar -n EDEV 1` | 网络错误（rxdrop/s、txdrop/s等） |
| `sar -q 1` | 负载与运行队列 |
| `sar -W 1` | swap换入换出 |
| `sar -f <归档文件>` | 读取历史数据 |
| `-s hh:mm -e hh:mm` | 指定时间段 |

#### 输出解读

实时CPU：

```bash
$ sar -u 1 3
Linux 5.4.0 (host01)   10/14/2026   _x86_64_    (8 CPU)

10:30:01 AM     CPU     %user     %nice   %system   %iowait    %steal     %idle
10:30:02 AM     all      5.05      0.00      1.01      0.50      0.00     93.19
10:30:03 AM     all     12.53      0.00      2.01      8.00      0.00     77.46
```

历史复盘：

```bash
# 查看今天8:00到10:00的CPU
sar -u -s 08:00:00 -e 10:00:00

# 查看15日全天内存趋势（每10分钟一个采样点）
sar -r -f /var/log/sa/sa15

# 查看昨天磁盘I/O延迟（对比排查慢时段）
sar -d -p -f /var/log/sa/sa14
```

#### 实战示例

```bash
# 故障复盘四连：CPU、内存、负载、I/O
sar -u -s 14:00:00 -e 15:00:00 -f /var/log/sa/sa$(date +%d -d yesterday)
sar -r -s 14:00:00 -e 15:00:00 -f /var/log/sa/sa$(date +%d -d yesterday)
sar -q -s 14:00:00 -e 15:00:00 -f /var/log/sa/sa$(date +%d -d yesterday)
sar -d -p -s 14:00:00 -e 15:00:00 -f /var/log/sa/sa$(date +%d -d yesterday)

# 网络流量趋势（找带宽异常时段）
sar -n DEV -f /var/log/sa/sa15 | grep eth0
```

#### 注意事项

- 实时模式的**第一行同样是历史平均**，忽略
- 历史数据是每10分钟一次的快照，**短时毛刺（几秒级）无法捕捉**，需配合实时工具
- 归档文件按天轮转，跨月注意DD编号与`sar -f`路径
- 需确保sysstat采集服务开机自启，否则故障复盘时无数据可查——**建议所有生产服务器默认启用**
- `sar -d -p`在sysstat 12.x以下部分参数行为不同（老版本无`-p`时设备名显示为dev8-0形式）

---

### 6.9 dstat——多资源实时综合统计

#### 功能说明

dstat将vmstat、iostat、netstat等多工具的输出按列合并到一屏，实时展示CPU、磁盘、网络、内存、swap等的综合变化，颜色化输出直观，适合整体态势观察与对比分析。

重要说明：**原dstat项目已停止维护**（最后版本0.7.4，基于Python2）；Python3环境请使用其兼容分支**dool**（`pip install dool`，命令行完全兼容），或转向pcp（Performance Co-Pilot）等替代方案。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y dstat`；Python3环境：`pip3 install dool` |
| Debian/Ubuntu | `apt install -y dstat`（老版本）；`pip3 install dool` |

#### 常用参数

| 参数 | 说明 |
| --- | --- |
| `-c` | CPU统计（usr/sys/idl/wai/hiq/siq） |
| `-d` | 磁盘统计（disk read/writ） |
| `-n` | 网络统计（net recv/send） |
| `-g` | 页统计（paging in/out） |
| `-y` | 系统统计（int/csw，中断与上下文切换） |
| `-m` | 内存统计（used/buff/cach/free） |
| `-s` | swap统计 |
| `-l` | 负载（1m/5m/15m） |
| `-p` | 分区统计 |
| `-t` | 显示时间戳 |
| `--top-cpu` | 附注CPU占用最高的进程 |
| `--top-mem` | 附注内存占用最高的进程 |
| `--top-io` | 附注I/O最多的进程 |
| `-r` | I/O请求统计（read/writ请求数） |
| `--disk-util` | 磁盘利用率 |
| `<间隔> <次数>` | 如`2 10` |

#### 输出解读

```bash
$ dstat -tcdngy
----system---- ----total-cpu-usage---- -dsk/total- -net/total- ---paging-- ---system--
     time     |usr sys idl wai hiq siq| read  writ| recv  send|  in   out | int   csw
14-10 10:30:01|  5   1  93   1   0   0|  12k   45k|   0     0 |   0     0 | 312   582
14-10 10:30:02| 45   8  42   5   0   0|2048k 1536k|8906k 1234k|   0     0 |1520  4830
```

列解读与速查：

- `usr/sys/idl/wai`：同top口径；`wai`（wait）为I/O等待
- `read/writ`：磁盘读写速率；`recv/send`：网络收发速率
- `in/out`：分页换入换出（对应vmstat的si/so），**非0即内存压力信号**
- `int/csw`：中断数与上下文切换数；csw突增结合`--top-cpu`看是哪个进程

#### 实战示例

```bash
# 经典组合：CPU+磁盘+网络+分页+系统
dstat -tcdngy

# 综合视图+三个TOP进程附注
dstat -tcmndyl --top-cpu --top-mem --top-io

# 每秒磁盘利用率明细
dstat --disk-util 1

# 用dool（Python3环境）
dool -tcdngy
```

#### 注意事项

- dstat依赖Python；RHEL8+/Ubuntu 20.04+默认只有Python3，装dstat包可能失败或不工作，直接`pip3 install dool`
- dstat展示的存储单位自动换算（k/M），大流量时注意单位
- `--top-*`附注功能需要root（读取进程信息）
- dstat输出不适合脚本解析（有颜色与动态列宽），脚本场景用`vmstat`/`sar`的机器可读格式或`-o`JSON

---

### 6.10 turbostat——CPU频率与节能状态分析

#### 功能说明

turbostat是x86平台专用工具（内核源码tools/power/x86/turbostat），读取MSR（Model-Specific Register）报告处理器拓扑、实际运行频率、忙闲状态、C-State（休眠态）占比、温度、封装功耗，用于诊断**CPU降频、睿频不生效、功耗墙、散热墙**等问题。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y kernel-tools` |
| Debian/Ubuntu | `apt install -y linux-cpupower` |

#### 常用参数

| 参数 | 说明 |
| --- | --- |
| `turbostat` | 默认每5秒输出一次 |
| `-i <秒>` | 采样间隔 |
| `-c <cpu列表>` | 只显示指定CPU（如`-c 0,4`） |
| `--Summary` | 只输出汇总行（所有CPU聚合） |
| `-J` | JSON格式输出 |
| `--quiet` | 不显示表头注释行（便于脚本解析） |
| `-S` | 显示每个插槽汇总 |
| `-n <次数>` | 采样次数 |

运行前提：root权限，内核会自动加载msr模块（如未加载：`modprobe msr`）。

#### 输出解读

```bash
$ turbostat --Summary --quiet
Core    CPU     Avg_MHz Busy%   Bzy_MHz TSC_MHz IPC     CPU%c1  CPU%c3  CPU%c6  CPU%c7  CoreTmp PkgTmp  PkgWatt RAMWatt
-       -       2334    95.22   2450    2494    1.23    4.78    0.00    0.00    0.00    62      65      125.34  32.11
```

字段要点：

- `Avg_MHz`：平均频率（含空闲时段）；`Bzy_MHz`：**忙时实际频率**——与CPU标称频率对比，明显偏低说明降频
- `Busy%`：非空闲比例
- `IPC`：每周期指令数，同perf stat口径
- `CPU%c1/c3/c6/c7`：各级C-State（休眠深度）时间占比；`%c1`高说明CPU频繁浅睡眠（调度唤醒频繁）
- `PkgTmp`：封装温度；持续逼近TjMax(通常95~105°C)说明**散热瓶颈导致降频**
- `PkgWatt`：封装功耗估算（需要RAPL支持）；`RAMWatt`内存功耗

#### 实战示例

```bash
# 性能测试中监控是否降频（重点看Bzy_MHz与PkgWatt）
turbostat -i 2 --Summary

# JSON数据接入监控系统
turbostat -J -i 5 -n 12 > turbostat.json

# 只看0号与4号CPU（通常是两个物理核）
turbostat -c 0,4 -i 1
```

#### 注意事项

- **仅支持x86**（Intel/AMD），ARM平台用cpupower等替代
- 虚拟机上通常不可用或数据无意义（读不到真实MSR）
- Bzy_MHz受Turbo Boost影响可高于标称主频（如标称2.4GHz睿频到3.5GHz），基准对比应使用标称"基本频率"
- PkgWatt为模型估算值，非精密功率计，看趋势即可
- 降频排查顺序：散热（温度）→BIOS功耗策略（Power Limit）→操作系统cpufreq governor（`cpupower frequency-info`）

---

### 6.11 rdmsr——CPU寄存器直接读取

#### 功能说明

rdmsr（read MSR）直接读取x86处理器的MSR寄存器值，用于深度硬件调试与确认BIOS/固件层配置是否与预期一致（如Turbo是否被禁用、温度墙阈值、性能状态等）。属于"最后一公里"的底层确认手段，学习与排障使用需谨慎。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y msr-tools` |
| Debian/Ubuntu | `apt install -y msr-tools` |

运行前提：

```bash
modprobe msr        # 加载msr内核模块
lsmod | grep msr
```

需要root权限；仅x86平台。

#### 常用参数

| 参数 | 说明 |
| --- | --- |
| `rdmsr <0x地址>` | 读取指定MSR（十六进制） |
| `-a` | 所有CPU读取 |
| `-p <cpu>` | 指定CPU |
| `-c` | 十进制输出 |
| `-x` | 十六进制输出（默认） |
| `--bitfield h:l` | 提取指定位段 |
| `--all` | 聚合显示所有CPU的值（多CPU值相同时合并） |

#### 常用MSR地址

| 地址 | 寄存器 | 用途 |
| --- | --- | --- |
| `0x10` | IA32_TIME_STAMP_COUNTER | 时间戳计数器（TSC） |
| `0x1a0` | IA32_MISC_ENABLE | Turbo开关、硬件预取等使能位 |
| `0x198` | IA32_PERF_STATUS | 当前核心电压/倍频 |
| `0x199` | IA32_PERF_CTL | 期望的性能状态（可写） |
| `0x19c` | IA32_THERM_STATUS | 温度状态与降频（Prochot）标志 |
| `0x64a`等 | MSR_PKG_POWER_LIMIT | 封装功耗墙设置（型号相关） |

#### 输出解读

```bash
$ rdmsr 0x1a0
850089       # 十六进制值（实际输出为十六进制）

# 提取Turbo相关bit（位38：Enable Turbo Mode；位32-37：ID/FID值等）
$ rdmsr --bitfield 38:38 0x1a0
1            # 1=Turbo已启用（0=被BIOS禁用）

# 查看当前倍频/电压（0x198低16位为FID/VID）
$ rdmsr 0x198
160c         # 低byte为FID,高byte为VID（编码因代次而异）

# 温度状态：bit0=Thermal Status, bit2=Prochot/降频
$ rdmsr --bitfield 0:0 0x19c
1
```

#### 实战示例

```bash
# 确认所有CPU的Turbo模式是否启用
rdmsr -a --bitfield 38:38 0x1a0

# 读取各核心当前性能状态
rdmsr -a 0x198

# 检查是否有核心触发温度降频（bit0=1表示过热降频中）
rdmsr -a --bitfield 0:0 0x19c

# 记录基线用于对比
rdmsr -a 0x1a0 > msr_baseline.txt
```

#### 注意事项

- **wrmsr（写MSR）极其危险**，可能直接导致系统崩溃或硬件异常，生产环境严禁随意写入；排查以只读rdmsr为准
- MSR地址与位定义**随CPU代次（型号）不同而不同**，使用前须查阅对应型号的Intel SDM（Software Developer's Manual）Volume 4或AMD APM
- 虚拟机中多数MSR不可访问或虚拟化透传值无意义
- 位段提取的位定义以具体CPU代次的官方手册为准，上例为通用示意
- 本工具适合硬件工程师/深度调优场景，日常运维问题优先用turbostat与cpupower

---

## 7. I/O层（磁盘/交换）工具详解

### 7.1 iostat——磁盘I/O统计

#### 功能说明

iostat来自sysstat包，按设备维度报告每秒读写次数、吞吐量、平均延迟、请求队列与设备利用率，是**磁盘性能瓶颈判断的权威工具**（结合`-dx`扩展模式）。vmstat/top只能看到"I/O多"，iostat能定位"是哪块盘、瓶颈在延迟还是队列"。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y sysstat` |
| Debian/Ubuntu | `apt install -y sysstat` |

#### 常用参数

| 参数 | 说明 |
| --- | --- |
| `-d` | 只显示磁盘统计（不显示CPU） |
| `-x` | 扩展统计（延迟、队列、利用率，排查必备） |
| `-m` | 以MB/s为单位；`-k`KB/s默认 |
| `<间隔> <次数>` | 如`1 10`每秒一次共10次 |
| `-p <设备>` | 显示分区级统计（如`-p sda`） |
| `-t` | 附加时间戳 |
| `-g <组名>` | 设备分组统计（如将所有盘合为组） |
| `-y` | 跳过第一行自启动平均值 |
| `-o JSON` | JSON输出 |

#### 输出解读

```bash
$ iostat -dx 1
Device            r/s     w/s     rkB/s     wkB/s   rrqm/s   wrqm/s  r_await  w_await  aqu-sz  rareq-sz  wareq-sz  %util
sda              5.20   12.30     208.0     492.0     0.10     2.30     1.20     3.50    0.06     40.0      40.0    0.61
nvme0n1        120.50 2000.40   15424.0   51200.5     0.00   120.00     0.08     0.35    2.30    128.0      25.6   55.20
```

核心字段（跨版本通用）：

| 字段 | 含义 | 判断标准 |
| --- | --- | --- |
| `r/s` / `w/s` | 每秒读/写请求数（IOPS） | 与设备能力对比（HDD约100-200，SATA SSD数万，NVMe数十万） |
| `rkB/s` / `wkB/s` | 每秒读写吞吐 | 与设备带宽对比（SATA SSD约550MB/s，NVMe 3.x 3.5GB/s） |
| `r_await` / `w_await` | 读/写请求平均延迟（**毫秒**，含排队时间） | HDD>20ms、SSD>5ms、NVMe>1ms需关注 |
| `aqu-sz` | 平均请求队列长度 | 持续大于设备并发能力说明排队严重 |
| `%util` | 设备非空闲时间占比 | 持续>80%说明饱和（对SSD仅作参考） |
| `rareq-sz` / `wareq-sz` | 平均请求大小（KB） | 随机小IO（<16KB）多说明业务模式为OLTP型 |

注意：不同sysstat版本列顺序与列名略有差异（如`avgqu-sz`在12.x改名为`aqu-sz`，新增discard相关列），但上述核心列均存在。**`svctm`字段已被官方标注废弃，不要用它判断性能**。

#### 实战示例

```bash
# 标准排查姿势：每1秒刷新，只显示磁盘
iostat -dx 1

# 看指定盘的延迟趋势
iostat -dx 1 /dev/sda

# 跳过平均值行（脚本解析）
iostat -dx -y 1 5

# 判断是随机IO还是顺序IO（看请求大小）
iostat -dxm 1     # 以MB显示
```

#### 注意事项

- 综合分析：`%util`高+`await`高=设备真饱和；`%util`高+`await`低=设备并发处理中（SSD正常）；`await`高+`%util`低=可能是队列调度或个别慢请求
- 机械盘与SSD的基准完全不同，判断前先用`lsblk -d -o name,rota`确认盘类型（rota=1为机械）
- 云盘（EBS/云硬盘）的%util与await受底层共享影响，突发抖动需结合云监控
- RAID卡写缓存会影响实际写延迟，await可能显著优于裸盘

---

### 7.2 iotop——进程级实时I/O监控

#### 功能说明

iotop以top风格实时显示各进程/线程的磁盘读写速率与I/O等待占比，直接回答"到底是哪个进程在疯狂读盘/写盘"。底层基于内核taskstats（CONFIG_TASK_IO_ACCOUNTING）。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y iotop` |
| Debian/Ubuntu | `apt install -y iotop` |

#### 常用参数

| 参数 | 说明 |
| --- | --- |
| `iotop` | 交互模式（需要root） |
| `-o` | 只显示正在产生I/O的进程 |
| `-b` | 批处理模式（脚本用） |
| `-n <次数>` | 刷新次数 |
| `-d <秒>` | 刷新间隔 |
| `-P` | 显示进程粒度（默认线程粒度） |
| `-u <用户>` | 只看指定用户 |
| `-p <pid>` | 只看指定进程 |
| `-a` | 累计模式（自启动累计而非瞬时速率） |
| `-k` | 以KB/s为单位 |
| `-q` | 精简输出（少表头） |

#### 输出解读

```
Total DISK READ:         0.00 B/s | Total DISK WRITE:       2.05 M/s
Current DISK READ:       0.00 B/s | Current DISK WRITE:     1.80 M/s
    TID  PRIO  USER     DISK READ  DISK WRITE  SWAPIN     IO>    COMMAND
   1234  be/4  mysql      0.00 B/s   1.02 M/s  0.00 %  12.34 %  mysqld
   5678  be/4  app        0.00 B/s   512.0 K/s  0.00 %   3.21 %  java -Xmx4g
```

关键字段：

- `DISK READ` / `DISK WRITE`：该进程实时磁盘读写速率（累计模式`-a`下为总量）
- `SWAPIN`：**花在swap换入的时间占比**（内存压力指标）
- `IO>`：**进程被I/O阻塞的时间占比**——这才是"该进程是否受I/O拖累"的权威指标。IO>高+慢，说明进程卡在磁盘上
- `TID`：默认显示线程ID；`-P`切换为进程ID
- `PRIO`：I/O优先级（be=best-effort，rt=real-time，配合ionice调整）

#### 实战示例

```bash
# 找出当前写盘最猛的进程（过滤无I/O进程）
iotop -o -P

# 非交互抓5次快照（记录日志）
iotop -b -o -n 5 -d 1 -P -k

# 只看数据库进程的I/O行为
iotop -o -p $(pidof mysqld)

# 检查哪些进程因I/O被阻塞（IO>列）
iotop -o | awk '$8+0 > 20'
```

#### 注意事项

- 需要root（taskstats访问权限），部分发行版要求`CAP_NET_ADMIN`
- 内核需启用`CONFIG_TASK_IO_ACCOUNTING`（RHEL/CentOS 7+、Ubuntu 16.04+默认启用）
- 容器内使用需共享宿主机PID命名空间（`--pid=host`）
- `SWAPIN`高时优先查内存（free/vmstat），而不是磁盘
- iotop显示的是**进程发起的磁盘I/O**，不含page cache命中部分（缓存命中不产生磁盘I/O，这也是为什么iotop看到的量可能远小于应用日志字面量）

---

### 7.3 blktrace——块设备I/O深度跟踪

#### 功能说明

blktrace工作在块设备层（block layer），能记录每个I/O请求从进入队列、合并、调度、下发驱动到完成的**全生命周期事件与精确时间戳**，配合blkparse解析、btt做延迟分解分析，是定位磁盘I/O延迟来源（排队慢？驱动慢？设备慢？）的终极工具。

#### 安装

| 发行版 | 安装命令 |
| --- | --- |
| RHEL/CentOS | `yum install -y blktrace` |
| Debian/Ubuntu | `apt install -y blktrace` |

#### 工具组成

| 工具 | 作用 |
| --- | --- |
| `blktrace` | 采集原始事件数据 |
| `blkparse` | 将二进制数据格式化为文本事件流 |
| `btt` | 延迟分析：Q2C、D2C等分解与直方图 |
| `btrace` | 采集+解析的便捷脚本 |
| `iowatcher` | 生成可视化视频/图（需Graphviz） |

#### 常用参数（blktrace）

| 参数 | 说明 |
| --- | --- |
| `-d /dev/sda` | 目标设备 |
| `-o <前缀>` | 输出文件前缀（生成前缀.blktrace.N，每CPU一个） |
| `-o -` | 输出到stdout（配合blkparse管道） |
| `-w <秒>` | 采集时长 |
| `-a <动作>` | 只采集指定动作（如`-a issue -a complete`） |
| `-r <目录>` | debugfs挂载点（默认自动探测） |
| `-b <KB>` | 缓冲区大小 |

#### 事件生命周期（核心概念）

| 事件 | 含义 |
| --- | --- |
| Q（Queued） | I/O请求进入块层队列 |
| G（Get Request） | 分配到request结构 |
| I（Inserted） | 插入调度器队列（如mq-deadline） |
| D（Issued） | 下发到设备驱动（真正硬件访问开始） |
| C（Completed） | 设备完成 |

由此衍生关键延迟指标：

- **Q2C**：应用视角总延迟（入队到完成）
- **D2C**：设备+驱动服务时间
- **Q2D**：排队等待时间（调度与拥塞）
- **Q2G/G2I/I2D**：块层内部各段开销

#### 使用示例与输出解读

```bash
# 方式一：采集30秒到文件再解析
blktrace -d /dev/sda -o /tmp/io -w 30
blkparse -i /tmp/io -d /tmp/io.bin

# 方式二：实时管道（Ctrl+C停止）
blktrace -d /dev/sda -o - | blkparse -i -

# 方式三：btrace快捷脚本（直接看格式化事件）
btrace /dev/sda
```

blkparse输出：

```
  8,0    3        1     0.000000000  1234  Q   W 12345678 + 128 [java]
  8,0    3        2     0.000001234  1234  G   W 12345678 + 128 [java]
  8,0    3        3     0.000002345  1234  I   W 12345678 + 128 [java]
  8,0    3        4     0.000003456  1234  D   W 12345678 + 128 [java]
  8,0    3        5     0.005432109  1234  C   W 12345678 + 128 [java]
CPU3 (8,0):
 Reads Queued: 0, 0KiB   Writes Queued: 1, 64KiB
 Read Dispatches: 0, 0KiB   Write Dispatches: 1, 64KiB
 Reads Completed: 0, 0KiB   Writes Completed: 1, 64KiB
 Read Merges: 0   Write Merges: 0
 IO unplugs: 1   Timer unplugs: 0
```

字段：设备主次号（8,0=sda）、CPU、事件序号、时间戳、PID、事件类型（Q/G/I/D/C）、RWBS（R读、W写、D丢弃、B屏障、S同步）、扇区号+长度、进程名。

上例中D到C耗时约5.4ms，即设备实际服务时间。

延迟分解分析（btt）：

```bash
btt -i /tmp/io.blktrace.0 -o /tmp/btt_out
cat /tmp/btt_out/btt_latency.dat   # 各阶段延迟数据
cat /tmp/btt_out/btt_p_latency.dat # 百分比分布
```

btt输出包含：Q2C/D2C延迟统计（average/min/max/σ）、按进程分类的I/O延迟、Q2G/G2I/I2D/Q2M等细分，用于回答"延迟花在队列还是花在设备上"。

#### 实战示例

```bash
# 定位慢I/O：先实时看事件，找出D→C间隔大的请求
blktrace -d /dev/sda -o - | blkparse -i - | awk '$6=="D" {d[$8]=$4} $6=="C" && d[$8] {lat=($4-d[$8])*1000; if(lat>20) print $0, lat"ms"}'

# 只采集写请求并分析延迟分解
blktrace -d /dev/sda -a write -o /tmp/io -w 10
btt -i /tmp/io.blktrace.0 | head -60

# 查看特定进程的I/O模式
blktrace -d /dev/sda -o - | blkparse -i - -f "%p %a %d" | grep java
```

#### 注意事项

- 需要root权限并挂载debugfs（`mount -t debugfs none /sys/kernel/debug`）
- 采集数据量按I/O量成比例增长，高IOPS设备10秒可产生数百MB，注意磁盘空间与采样时长
- 对系统性能的影响为低到中等（relay通道高效），但生产使用仍建议分钟级采样
- `blktrace`按CPU输出多个文件（.blktrace.0、.blktrace.1...），blkparse会自动合并
- 虚拟机中只能看到虚拟块设备层（如vda），物理层需在宿主机观察
- 分析神器"iowatcher"可将结果生成可视化视频（`iowatcher -t /tmp/io.blktrace -o out.mp4`），适合向团队演示

---

### 7.4 swapon——交换空间查看与管理

#### 功能说明

swapon/swapoff用于启用、禁用交换空间，`swapon -s`（或`swapon --show`）列出当前所有交换设备及其使用量。swap是内存不足时的溢出区，其使用状况是内存压力的直接证据。

#### 安装

随util-linux预装。

#### 常用命令

| 命令 | 说明 |
| --- | --- |
| `swapon -s` | 摘要显示（Filename、Type、Size、Used、Priority） |
| `swapon --show` | 格式化显示（同上，推荐） |
| `swapon --show=SIZE,USED,PRIO --bytes` | 自定义列与单位（脚本用） |
| `swapon -a` | 启用/etc/fstab中所有swap条目 |
| `swapon /dev/sdXN` | 启用指定swap设备/文件 |
| `swapoff -a` | 禁用所有swap（**内存不足时禁用会引发OOM**） |
| `cat /proc/swaps` | 内核视角原始数据 |

#### 输出解读

```bash
$ swapon --show
NAME      TYPE       SIZE   USED PRIO
/dev/sda3 partition    8G   91.5M   -2
/swapfile file         4G      0B   -3
```

- `TYPE`：partition（分区）、file（交换文件）、zram等
- `SIZE` / `USED`：总容量 / 已用量；**USED持续增长是内存紧张的最直接标志**
- `PRIO`：使用优先级；数值越**高**越优先使用（负数也遵循此规则，-2高于-3）；相同优先级则轮询（多设备场景提升swap吞吐）

#### 实战示例

```bash
# 检查swap使用情况
swapon -s
free -h

# 确认swap活动是否正在发生（USED增长时配合）
vmstat 1        # 观察si/so列

# 找出占用swap最多的进程
for pid in $(ls /proc | grep -E '^[0-9]+$'); do
  if [ -r /proc/$pid/status ]; then
    s=$(awk '/VmSwap/{print $2}' /proc/$pid/status 2>/dev/null)
    [ -n "$s" ] && [ "$s" -gt 10240 ] && echo "$s KB PID:$pid $(cat /proc/$pid/comm)"
  fi
done | sort -rn | head

# 调整swappiness（降低内核主动换出倾向）
sysctl vm.swappiness        # 默认60
sysctl -w vm.swappiness=10  # 数据库服务器常设为1~10
```

#### 注意事项

- 现代服务器普遍配置swap，作用已从"内存不足兜底"扩展到支持内存回收策略，**有swap且少量使用是正常的**；但USED持续上涨且vmstat的si/so>0说明真实内存压力
- zram（内存压缩交换）场景下swap usage高不一定是坏事（压缩比通常2~4倍）
- 排查时注意区分：swap分区使用量大但无换入换出活动=历史残留；有活动才是当前压力
- 数据库服务器（Oracle/MySQL）对swap敏感，配置swap但通过`vm.swappiness=1~10`控制使用倾向，并监控si/so
- `swapoff -a`前必须确认`free`可用内存充足，否则操作过程可能触发OOM Killer

---

## 8. 典型性能诊断场景实战

### 8.1 场景一：CPU使用率异常排查

**现象**：监控告警CPU使用率>80%，或业务反馈响应变慢。

**排查流程**：

```bash
# 第1步：确认整体情况与是哪个核忙（看%usr/%sys/%iowait/%steal分解）
mpstat -P ALL 1 5
# 判断：%usr高→应用计算重；%sys高→系统调用/锁/中断；%iowait高→其实瓶颈在磁盘；%steal高→宿主机争抢

# 第2步：用top定位消耗CPU的进程
top -b -n 1 | head -20
# 或
ps -eo pid,user,%cpu,%mem,stat,etime,cmd --sort=-%cpu | head -11

# 第3步：对该进程做采样分析，找出热点函数
perf top -p <pid>
# 或采样30秒后离线分析
perf record -F 99 -p <pid> -g -- sleep 30
perf report

# 第4步：查看线程级CPU（多线程Java/Go应用）
pidstat -u -t -p <pid> 1 5
top -H -p <pid>

# 第5步：Java应用可进一步用jstack映射热点线程栈
top -H -p <pid>       # 记录高CPU线程TID（十六进制转换）
jstack <pid> | grep -A 30 <tid_hex>

# 第6步：若是%sys高，检查系统调用类型
strace -c -p <pid> -- sleep 10
# 或更轻量
perf trace -p <pid> -- sleep 10
```

**常见结论**：

- 用户态热点集中（GC线程、计算循环）→ 应用优化
- 内核态消耗高+大量锁函数→ 锁竞争（观察`native_queued_spin_lock_slowpath`）
- %iowait高 → 转磁盘排查（见8.3）
- %steal高 → 云平台侧处理

---

### 8.2 场景二：内存不足/泄漏排查

**现象**：free可用内存持续下降、swap使用增长、进程被OOM Killer杀掉、服务响应慢伴随SWAPIN高。

**排查流程**：

```bash
# 第1步：确认内存总体水位（关键看available与swap活动）
free -h
vmstat -w 1 10
# si/so持续非0=真实内存压力；swpd非0但si/so=0=历史残留

# 第2步：定位消耗内存的进程
ps -eo pid,user,%mem,rss,vsz,etime,cmd --sort=-rss | head -11

# 第3步：观察进程内存增长趋势（判断是否泄漏）
pidstat -r -p <pid> 5 12
# minflt/s极高=分配回收频繁；majflt/s非0=真读磁盘换页

# 第4步：区分用户态与内核态内存
# 应用占用（RSS合计）与free的used对不上时，查内核内存
slabtop -o -s c | head -30

# 第5步：检查swap明细
swapon -s
for pid in $(ls /proc | grep -E '^[0-9]+$'); do
  s=$(awk '/VmSwap/{print $2}' /proc/$pid/status 2>/dev/null)
  [ -n "$s" ] && [ "$s" -gt 10240 ] && echo "$s KB PID:$pid $(cat /proc/$pid/comm)"
done | sort -rn | head

# 第6步：查看OOM记录（如有进程被杀）
dmesg -T | grep -iE 'oom|killed process'
journalctl -k | grep -i oom

# 第7步：查看页缓存与直接内存
grep -E 'MemTotal|MemFree|MemAvailable|Buffers|Cached|Dirty|Huge' /proc/meminfo
```

**常见结论**：

- 单进程RSS持续单调增长 → 应用内存泄漏（按语言用valgrind/jmap/pprof深入）
- slab某个缓存持续暴涨 → 内核对象泄漏（如dentry，或驱动bug）
- 偶发majflt高（如定时任务）→ 正常现象
- page cache占满但available充足 → 正常且有益，不需要释放

---

### 8.3 场景三：磁盘I/O瓶颈排查

**现象**：业务写入慢、数据库查询变慢、%iowait高、负载高但CPU利用率低。

**排查流程**：

```bash
# 第1步：确认磁盘整体状况（%util与await）
iostat -dx 1 5
# 关注：哪块设备%util高、await是否异常（HDD>20ms/SSD>5ms/NVMe>1ms）

# 第2步：定位是哪个进程在读写
iotop -o -P
# 关注IO>列（进程被I/O阻塞的时间占比）与读写速率

# 第3步：判断I/O模式（随机还是顺序、大小）
iostat -dxm 1 5
# rareq-sz/wareq-sz很小（<16KB）=随机小IO；很大=顺序大IO

# 第4步：确认进程等待的内核调用
pidstat -d -p <pid> 1 5        # iodelay列
cat /proc/<pid>/stack          # root查看进程内核栈（DPC在等谁）

# 第5步：深度定位延迟来源（是排队慢还是设备慢）
blktrace -d /dev/sda -o /tmp/io -w 10
btt -i /tmp/io.blktrace.0 | head -60
# Q2C大而D2C小=排队拥塞（请求太多）；D2C大=设备本身慢

# 第6步：检查设备层面是否有错误
dmesg -T | grep -iE 'error|fail|timeout|reset' | tail -30
smartctl -a /dev/sda        # 需安装smartmontools，检查磁盘健康

# 第7步：查看页缓存效果（缓存命中率低=物理IO多）
pcstat /path/to/hotfile
```

**常见结论**：

- 单进程顺序写打满磁盘带宽 → 限速（ionice/cgroup io.max）或分流
- 数据库随机读await高 → 检查索引、缓存命中、存储性能
- 云盘%util高但吞吐低 → 云盘IOPS配额打满，查云监控
- dmesg有超时/reset记录 → 硬件或链路故障，联系硬件/云厂商

---

### 8.4 场景四：网络问题排查

**现象**：应用访问外部服务超时、丢包、吞吐低、连接数异常。

**排查流程**：

```bash
# 第1步：检查连接状态与数量
ss -s
ss -tan | awk '{print $1}' | sort | uniq -c | sort -rn
# 大量CLOSE-WAIT=TLS/HTTP连接未正常关闭；大量TIME-WAIT=短连接过多

# 第2步：查看TCP内部质量（重传、RTT、拥塞窗口）
ss -tin state established | head -30
# retrans上升=链路质量差/拥塞；rtt大=网络延迟高；cwnd被压=存在丢包

# 第3步：检查网卡物理状态与错误统计
ethtool eth0 | grep -E 'Speed|Duplex|Link'
ethtool -S eth0 | grep -iE 'err|drop|miss|nobuf'
watch -n 1 "ethtool -S eth0 | grep -iE 'error|drop'"

# 第4步：抓包分析（以数据库连接为例）
tcpdump -i eth0 -nn host 10.0.0.15 and port 3306 -w /tmp/db.pcap -c 1000
# 用tshark统计重传、乱序
tshark -r /tmp/db.pcap -q -z io,stat,0,"COUNT(tcp.analysis.retransmission)"

# 第5步：实时流量监控（哪个连接/进程占带宽）
iptraf-ng -i eth0
# 或按进程：nethogs eth0（需另行安装）

# 第6步：查看协议栈错误统计
netstat -s | grep -iE 'retrans|drop|overflow|reset'

# 第7步：历史趋势（故障时段带宽/错误）
sar -n DEV -s 14:00:00 -e 15:00:00 -f /var/log/sa/sa$(date +%d)
sar -n EDEV -s 14:00:00 -e 15:00:00 -f /var/log/sa/sa$(date +%d)

# 第8步：物理链路与拓扑确认
lldptool -t -i eth0 | grep -A2 -E 'Port ID|System Name'
```

**常见结论**：

- rx_dropped增长+软中断CPU高 → 增大ring buffer（ethtool -G）或开启RPS/RSS多队列
- 重传率高 → 链路质量/拥塞/MTU问题（检查`ip link show`的MTU与`ping -M do -s 1472`验证路径MTU）
- TIME-WAIT过多 → 调整tcp_tw_reuse或改长连接
- 连接数打满（ulimit/backlog）→ 检查ss的Send-Q（LISTEN）与内核`net.core.somaxconn`

---

### 8.5 场景五：系统整体卡顿/负载高但CPU不高

**现象**：服务器响应慢、负载(load average)很高，但top的CPU利用率不高。

**原因方向**：load包含D状态（不可中断睡眠）进程，多数是等I/O或等内核锁。

**排查流程**：

```bash
# 第1步：确认阻塞进程（D状态）数量
vmstat 1 5        # 看b列
ps -eo pid,stat,wchan:32,cmd | awk '$2 ~ /D/'

# 第2步：查看这些进程卡在哪个内核函数
cat /proc/<pid>/stack        # root
# 或ps的wchan列已显示等待点（如__flush_workqueue、rwsem_down_read等）

# 第3步：按方向深入
# 卡在磁盘I/O相关（wait_on_page_writeback等）→ 转8.3磁盘排查
iostat -dx 1
iotop -o -P

# 卡在网络I/O（如nfs、分布式存储）→ 转8.4网络排查
nfsstat -c    # NFS场景
ss -tan | grep -c ESTAB

# 卡在文件系统锁（如jbd2日志、ext4锁）→ 查看内核栈与dmesg
dmesg -T | tail -50

# 第4步：检查是否内存压力导致的直接回收（进程卡在内存回收）
vmstat 1      # si/so、free
cat /proc/meminfo | grep -E 'Dirty|Writeback'
# Dirty过大（默认阈值约几百MB）说明写回积压
sysctl vm.dirty_ratio vm.dirty_background_ratio

# 第5步：综合历史对比（故障发生时段）
sar -q -s <出事时间> -f /var/log/sa/sa$(date +%d)
sar -b -s <出事时间> -f /var/log/sa/sa$(date +%d)
```

**常见结论**：

- 进程卡在`wait_on_page_writeback`/`balance_dirty_pages` → 磁盘写回慢（磁盘饱和或存储抖动）
- 进程卡在网络文件系统 → 存储/网络侧故障
- 进程卡在`jbd2_log_wait_commit` → 文件系统journal提交慢（底层磁盘慢）
- 大量D进程+swap活动 → 内存不足导致换页风暴，优先扩内存或限流

---

## 附录A：工具包名与权限对照总表

| 工具 | RHEL/CentOS安装包 | Debian/Ubuntu安装包 | 权限要求 |
| --- | --- | --- | --- |
| strace | strace | strace | root（附加他人进程需CAP_SYS_PTRACE） |
| lsof | lsof | lsof | 普通用户可查自己；查他人需root |
| ltrace | ltrace | ltrace | 同strace |
| sysdig | 官方安装脚本 | 官方安装脚本 | root |
| ss | iproute2 | iproute2 | 无（-p查进程需root） |
| netstat | net-tools | net-tools | 无（-p查进程需root） |
| pcstat | 第三方工具（Go编译/下载二进制） | 同左 | root或文件属主 |
| perf | perf（kernel-tools） | linux-tools-common + linux-tools-$(uname -r) | root（或调整perf_event_paranoid） |
| ftrace | 内核内置 | 内核内置 | root |
| eBPF（bcc） | bcc-tools | bpfcc-tools | root |
| eBPF（bpftrace） | bpftrace | bpftrace | root |
| pidstat | sysstat | sysstat | 无（看他人进程需root） |
| stap | systemtap + kernel-devel + kernel-debuginfo | systemtap + linux-headers | root |
| lttng | lttng-tools + lttng-ust | lttng-tools + lttng-modules-dkms | root |
| tcpdump | tcpdump | tcpdump | root（或CAP_NET_RAW） |
| iptraf | iptraf-ng | iptraf-ng | root |
| ethtool | ethtool | ethtool | 查询无需权限；修改需root |
| lldptool | lldpad | lldpad | root（需lldpad服务运行） |
| snmpget | net-snmp-utils | snmp | 无 |
| top | procps-ng | procps | 无 |
| htop | htop（EPEL源） | htop | 无 |
| ps | procps-ng | procps | 无 |
| mpstat | sysstat | sysstat | 无 |
| vmstat | procps-ng | procps | 无 |
| free | procps-ng | procps | 无 |
| slabtop | procps-ng | procps | 无（root可看全部） |
| numastat | numactl | numactl | 无（-p查进程需root） |
| sar | sysstat | sysstat | 实时无；读历史归档需root或adm组 |
| dstat / dool | dstat（或pip3 install dool） | dstat（或pip3 install dool） | root（--top-*功能） |
| turbostat | kernel-tools | linux-cpupower | root（需msr模块，x86） |
| rdmsr | msr-tools | msr-tools | root（需modprobe msr，x86） |
| iostat | sysstat | sysstat | 无 |
| iotop | iotop | iotop | root |
| blktrace | blktrace | blktrace | root（需debugfs） |
| swapon | util-linux | util-linux | 查询无；启用/禁用需root |

---

## 附录B：高频单行命令速查

### CPU

```bash
top -b -n 1 | head -20                        # 批处理快照（CPU TOP）
mpstat -P ALL 1                               # 每核CPU分解
pidstat -u -t -p <pid> 1                      # 进程线程级CPU
perf top -p <pid>                             # 实时热点函数
perf stat -p <pid> -- sleep 10                # IPC与缓存统计
turbostat --Summary -i 2                      # CPU频率/功耗/降频（x86）
```

### 内存

```bash
free -h                                       # 内存水位（看available）
vmstat -w 1                                   # 综合（看r/b/si/so）
slabtop -o -s c | head -30                    # 内核slab TOP
pidstat -r -p <pid> 1                         # 进程内存（缺页）
numastat -m                                   # NUMA节点内存分布
ps -eo pid,rss,cmd --sort=-rss | head         # 进程RSS排行
```

### 磁盘I/O

```bash
iostat -dx 1                                  # 设备级I/O（await/%util）
iotop -o -P                                   # 进程级I/O
pidstat -d 1 5                                # 进程I/O速率与iodelay
blktrace -d /dev/sda -o - | blkparse -i -     # 块设备事件实时流
pcstat /data/db/ibdata1                       # 文件缓存命中率
```

### 网络

```bash
ss -tulnp                                     # 监听端口与进程
ss -tan | awk '{print $1}' | sort | uniq -c   # 连接状态分布
ss -tin state established                     # RTT/重传/拥塞窗口
tcpdump -i eth0 -nn port 80 -c 100 -A         # 抓包（看HTTP明文）
ethtool -S eth0 | grep -iE 'err|drop'         # 网卡错误统计
ethtool eth0 | grep -E 'Speed|Duplex|Link'    # 协商状态
lldptool -t -i eth0 | grep -A2 'Port ID'      # 对接交换机端口
```

### 综合与历史

```bash
dstat -tcdngy                                 # 综合实时（dool）
sar -u 1 3                                    # 实时CPU
sar -u -s 14:00:00 -e 15:00:00 -f /var/log/sa/sa15   # 历史复盘
uptime                                        # 负载快速查看
dmesg -T | tail -50                           # 内核日志（OOM/磁盘错误）
```

### 跟踪类（问题深挖）

```bash
strace -tt -T -p <pid>                        # 系统调用+耗时
lsof -p <pid> | wc -l                         # 句柄数统计
perf record -F 99 -a -g -- sleep 30           # 全系统采样（火焰图）
execsnoop                                     # 新进程执行（bcc）
biosnoop                                      # 块I/O详情（bcc）
runqlat 10 1                                  # 调度延迟直方图（bcc）
bpftrace -e 'tracepoint:syscalls:sys_enter_openat { printf("%s %s\n", comm, str(args->filename)); }'
```

---

## 附录C：参考资源

| 资源 | 地址 |
| --- | --- |
| Linux man手册（全部工具官方手册） | https://man7.org/linux/man-pages/ |
| 内核文档：ftrace | https://docs.kernel.org/trace/ftrace.html |
| 内核文档：numastat | https://docs.kernel.org/admin-guide/numastat.html |
| 内核文档：eBPF | https://docs.kernel.org/bpf/ |
| perf官方Wiki | https://perf.wiki.kernel.org/ |
| sysstat（sar/iostat/mpstat/pidstat）官方仓库 | https://github.com/sysstat/sysstat |
| bcc工具集官方仓库 | https://github.com/iovisor/bcc |
| bpftrace官方网站与文档 | https://bpftrace.org/ |
| Brendan Gregg性能分析资源（方法论、火焰图） | https://www.brendangregg.com/linuxperf.html |
| FlameGraph火焰图工具 | https://github.com/brendangregg/FlameGraph |
| pcstat官方仓库 | https://github.com/tobert/pcstat |
| dool（dstat的Python3维护分支） | https://github.com/scottchiefbaker/dool |
| LTTng官方文档 | https://lttng.org/docs/ |
| SystemTap官方项目 | https://sourceware.org/systemtap/ |
| tcpdump官方网站 | https://www.tcpdump.org/ |
| Wireshark官方文档 | https://www.wireshark.org/docs/ |
| net-snmp官方项目 | http://www.net-snmp.org/ |
| open-lldp（lldpad/lldptool）官方仓库 | https://github.com/intel/openlldp |
| trace-cmd官方站点 | https://trace-cmd.org/ |
| KernelShark（ftrace图形化分析） | https://www.kernelshark.org/ |
| Red Hat系统监控与性能调优指南 | https://docs.redhat.com/ |
| Oracle Linux监控指南（turbostat等） | https://docs.oracle.com/en/operating-systems/ |

---

## 文档说明

- 本手册基于"Linux 性能诊断工具速查表.xlsx"（含命令输出示例工作表）扩展编写，分层结构与速查表保持一致
- 命令行参数与字段说明以各工具官方man手册及官方文档为准；输出示例为反映典型格式的整理样例，实际输出随版本、发行版与硬件有所差异
- 工具状态提示：dstat项目已停止维护，Python3环境建议改用dool；netstat属net-tools已渐进淘汰，建议迁移ss；iptraf建议使用iptraf-ng
- 生产环境使用跟踪类工具（strace、perf record、tcpdump、blktrace、bpftrace等）前，务必评估性能开销，控制采样时长，优先在业务低峰执行
