# 2026 虚拟项目：Flash Controller

## 1. 练习简介

本练习要求你使用 Verilog/SystemVerilog 设计一个简单的 Flash Controller。

Controller 位于 APB 总线和 NOR Flash 芯片之间：

```text
APB Master  <── APB ──>  Flash Controller  <── SPI ──>  NOR Flash
```

APB Master 只需要像访问普通内存一样发起读操作，Flash Controller 负责完成下面的工作：

1. 接收并解析 APB 读事务；
2. 把 APB 地址转换为 Flash 地址；
3. 按照 NOR Flash 的协议发送“快速读”命令；
4. 等待 Flash 返回数据；
5. 通过 APB `PRDATA` 返回读取结果。

本题面向第一次编写总线控制器的同学。基础题只要求实现“APB 读 + SPI 快速读”，不要求实现写 Flash、擦除、四线 QSPI 或寄存器配置功能。进阶内容放在文档末尾。

## 2. 你将练习什么

完成本题后，你应该能够：

- 看懂一个简单的 APB 从机读事务；
- 使用状态机控制一个多周期外设访问；
- 设计时钟分频器，产生低速 SPI 时钟；
- 理解命令、地址、dummy clock 和数据之间的关系；
- 正确使用双向 `inout` 信号和高阻态 `Z`；
- 使用仿真波形定位时序问题。

## 3. 基础题的固定约定

为了避免大家在实现时对规格产生不同理解，基础题统一采用以下约定。

| 项目 | 约定 |
| --- | --- |
| 系统时钟 | `100 MHz`，周期 `10 ns` |
| SPI 时钟 | `1 MHz`，周期 `1 us`，高电平和低电平各 `500 ns` |
| SPI 模式 | Mode 0：时钟空闲低电平，在上升沿采样、下降沿改变输出 |
| Flash 容量 | `128 Mbit = 16 MiB` |
| Flash 地址范围 | `0x0000_0000 ~ 0x00FF_FFFF`，按字节寻址 |
| APB 数据宽度 | `32 bit` |
| APB 读数据宽度 | 每次 APB 读返回连续 4 个 Flash 字节 |
| Flash 读命令 | `0x0B`，Fast Read |
| Flash 地址 | 发送 24 bit 地址，高位先发送（MSB first） |
| Dummy clock | 固定 8 个 SPI 时钟周期 |
| 数据返回端 | Flash 在 `DQ1` 上输出，Controller 在 SPI 上升沿采样 |
| 基础题支持的 APB 操作 | 只读，不实现写 Flash |

### 3.1 APB 地址映射

本题把 Flash 直接映射到 APB 地址空间的低 16 MiB：

```text
APB 地址 0x0000_0000  ->  Flash 地址 0x000000
APB 地址 0x0000_0004  ->  Flash 地址 0x000004
APB 地址 0x0000_0008  ->  Flash 地址 0x000008
...
APB 地址 0x00FF_FFFC  ->  Flash 地址 0xFFFFFC
```

一次 APB 读必须满足地址 4 字节对齐，即 `PADDR[1:0] == 2'b00`。例如，读取 `PADDR = 0x20` 时，Controller 应从 Flash 的 `0x000020` 开始读取 4 个字节。

本题示例采用小端拼接方式：如果 Flash 中连续 4 个字节为：

```text
Flash[0x20] = 0x11
Flash[0x21] = 0x22
Flash[0x22] = 0x33
Flash[0x23] = 0x44
```

则 APB 返回：

```text
PRDATA = 0x44332211
```

如果你的老师提供的测试平台对数据排列有额外约定，以测试平台为准。

## 4. 顶层接口要求

模块名可以自行决定，但建议使用下面的接口。信号名可以调整，含义不要改变。

```systemverilog
module flash_controller (
    input  logic        clk,
    input  logic        rst_n,

    // APB interface
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [31:0] paddr,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,
    output logic        pslverr,

    // SPI interface
    output logic        spi_csn,
    output logic        spi_clk,
    inout  wire         spi0,       // Flash DQ0：发送命令和地址
    inout  wire         spi1        // Flash DQ1：接收数据
);
```

基础题中不使用 `pwdata`。如果暂时没有实现错误响应，也可以先把 `pslverr` 固定为 `0`，但建议在完成基础功能后补上错误处理。

### 4.1 APB 信号说明

| 信号 | 方向 | 含义 |
| --- | --- | --- |
| `PSEL` | 输入 | APB Master 选中本从机 |
| `PENABLE` | 输入 | APB 进入访问阶段 |
| `PWRITE` | 输入 | `0` 表示读，`1` 表示写 |
| `PADDR` | 输入 | 本次访问的地址 |
| `PWDATA` | 输入 | 写数据，本题基础功能不使用 |
| `PRDATA` | 输出 | 读数据 |
| `PREADY` | 输出 | `1` 表示本次访问完成；`0` 表示需要等待 |
| `PSLVERR` | 输出 | `1` 表示本次访问非法或出错 |

APB 事务分为两个阶段：

1. Setup phase：`PSEL=1, PENABLE=0`；
2. Access phase：`PSEL=1, PENABLE=1`。

对于一个需要访问 Flash 的读事务，Controller 应在 Access phase 期间保持 `PREADY=0`，直到 SPI 读操作完成。完成时，Controller 在一个 APB 时钟周期内同时给出有效的 `PRDATA` 和 `PREADY=1`。

```wavedrom
{ signal: [
  { name: "PCLK",    wave: "p............." },
  { name: "PSEL",    wave: "0.1.........0." },
  { name: "PENABLE", wave: "0..1........0." },
  { name: "PADDR",   wave: "x.3.........x.", data: ["0x00000020"] },
  { name: "PREADY",  wave: "1.0.......1.0." },
  { name: "PRDATA",  wave: "x.........3.x.", data: ["0x44332211"] }
]}
```

上图表示：APB 事务开始后，Controller 需要等待若干个系统时钟；当 Flash 数据准备好时，拉高 `PREADY`，并在同一个周期提供 `PRDATA`。

## 5. SPI 与 NOR Flash 访问协议

### 5.1 SPI 信号连接

本题使用单线 SPI 的命令/地址发送和数据接收阶段：

| Controller 信号 | Flash 模型信号 | 作用 |
| --- | --- | --- |
| `spi_csn` | `S` | 片选，低电平有效 |
| `spi_clk` | `C_` | SPI 时钟 |
| `spi0` | `DQ0` | Controller 发送命令和地址 |
| `spi1` | `DQ1` | Flash 返回读取数据 |

注意：`spi0` 和 `spi1` 都连接到了 Flash 模型的 `inout` 端口。发送阶段 Controller 驱动 `spi0`；接收阶段 Controller 应释放 `spi1`，让 Flash 驱动它。未使用的方向必须输出高阻态 `Z`，否则可能与 Flash 模型发生总线冲突。

### 5.2 Fast Read 一次访问的组成

一次 Fast Read 访问由下面几部分组成，`spi_csn` 在整个过程中保持低电平：

| 阶段 | 时钟周期数 | Controller 在 `DQ0` 上做什么 | Controller 在 `DQ1` 上做什么 |
| --- | ---: | --- | --- |
| Command | 8 | 发送 `0x0B` | 忽略 |
| Address | 24 | 发送 `A[23:0]` | 忽略 |
| Dummy | 8 | 发送任意值，通常为 `0` | 忽略 |
| Data | 32 | 释放总线 | 接收 4 个字节 |

所以，一次 APB 读至少需要 `8 + 24 + 8 + 32 = 72` 个 SPI 时钟周期。SPI 时钟为 1 MHz 时，纯 SPI 传输时间约为 72 us，实际 APB 延迟还会包括状态机和时钟分频带来的少量额外周期。

下面的图按“阶段”展示一次访问。每个阶段内部仍然需要逐 bit 发送或接收，图中省略了重复的时钟边沿，以便先看懂整体顺序。

```wavedrom
{ signal: [
  { name: "spi_csn", wave: "1.0..............1", data: ["active"] },
  { name: "spi_clk", wave: "0.p..............0" },
  { name: "spi0/DQ0", wave: "z.3.4.5.6.7.8.z", data: ["0x0B", "A[23:16]", "A[15:8]", "A[7:0]", "dummy", "dummy", "dummy"] },
  { name: "spi1/DQ1", wave: "z.............3.z", data: ["D[31:0]"] }
]}
```

实现时请牢记两个边沿：

- 在下降沿准备下一个发送 bit；
- 在上升沿采样 `spi1` 上的接收 bit。

以一个 8 bit 字节为例，发送最高位 `bit[7]`，再依次发送 `bit[6]` 到 `bit[0]`。接收数据也按 MSB first 拼接：每次上升沿执行类似 `rx_shift <= {rx_shift[6:0], spi1}` 的操作。

```wavedrom
{ signal: [
  { name: "CS#", wave: "0................" },
  { name: "SCK", wave: "0p..p..p..p..p..p..p..p.." },
  { name: "DQ0", wave: "3.4.5.6.7.8.9.10.", data: ["b7", "b6", "b5", "b4", "b3", "b2", "b1", "b0"] },
  { name: "DQ1", wave: "z...............", data: ["sample on rising edge"] }
]}
```

## 6. 推荐的内部结构

建议把设计拆成三个容易理解的部分。可以写在一个文件中，也可以拆成多个模块。

### 6.1 APB 从机部分

职责：

- 检测 APB 访问开始；
- 检查 `PWRITE`、地址范围和地址对齐；
- 保存本次访问的 Flash 地址；
- 启动 SPI 读操作；
- 在 SPI 完成后给出 `PRDATA` 和 `PREADY`。

### 6.2 SPI 时钟与移位部分

职责：

- 使用 `clk` 产生 1 MHz 的 `spi_clk`；
- 控制 `spi_csn`；
- 在 `spi0` 上发送字节；
- 在 `spi1` 上接收字节；
- 控制 `spi0`/`spi1` 的输出使能和高阻态。

100 MHz 到 1 MHz 的分频并不复杂。因为 SPI 周期包含一个高半周期和一个低半周期，所以每经过 50 个系统时钟翻转一次 `spi_clk`，即可得到：

```text
100 MHz / (50 + 50) = 1 MHz
```

请在设计中明确区分“系统时钟周期”和“SPI 时钟周期”，不要每个 `clk` 周期都把 SPI bit 计数器加一。

### 6.3 Flash 访问状态机

可以参考下面的状态划分，也可以采用自己的划分：

| 状态 | 主要工作 |
| --- | --- |
| `IDLE` | 等待合法的 APB 读访问 |
| `START` | 锁存地址，拉低 `spi_csn`，准备第一个命令 bit |
| `SEND_CMD` | 发送 `0x0B` |
| `SEND_ADDR` | 发送 24 bit Flash 地址 |
| `SEND_DUMMY` | 产生 8 个 dummy clock |
| `RECV_DATA` | 在 `spi1` 接收 32 bit 数据 |
| `FINISH` | 拉高 `spi_csn`，整理 `PRDATA`，拉高 `PREADY` |
| `ERROR` | 对非法访问返回 `PSLVERR=1` |

建议先在纸上画出状态之间的跳转，再开始写 RTL。例如：

```text
IDLE
  ├─ 非法访问 ─> ERROR ─> IDLE
  └─ 合法读   ─> START -> SEND_CMD -> SEND_ADDR
                         -> SEND_DUMMY -> RECV_DATA
                         -> FINISH -> IDLE
```

## 7. 分阶段完成任务

不要一开始就把 APB、分频器和 Flash 模型全部连在一起。建议按下面顺序完成。

### 任务 0：读懂接口和波形

在写代码前，回答以下问题：

1. APB 的 Setup phase 和 Access phase 分别是什么？
2. 为什么 Flash 访问期间 `PREADY` 需要保持低电平？
3. `0x0B` 命令后面为什么还要发送地址和 dummy clock？
4. 为什么 `spi1` 必须在 Controller 侧保持高阻态？
5. 一次 32 bit APB 读需要从 Flash 读取多少个字节？

### 任务 1：先做 SPI 时钟分频

暂时不连接 Flash，产生 1 MHz 的 `spi_clk`。

验收要求：

- `spi_clk` 空闲时为低电平；
- 高、低电平时间均约为 `500 ns`；
- 复位期间 `spi_csn=1`、`spi_clk=0`；
- 波形中没有额外的毛刺。

### 任务 2：实现发送一个字节

实现一个简单的 SPI 发送器，先固定发送 `8'h0B`。

验收要求：

- `spi_csn` 拉低后才允许产生 SPI 时钟；
- 发送顺序为 `1、0、0、0、1、0、1、1`；
- 每个 bit 只发送一次；
- 发送完成后，`spi0` 回到高阻态或保持协议允许的安全值。

### 任务 3：实现地址和 dummy 阶段

在任务 2 的基础上继续发送 24 bit 地址和 8 个 dummy clock。

验收要求：

- 地址从 `A[23]` 开始发送；
- 地址结束后仍保持 `spi_csn=0`，不能提前结束事务；
- dummy 阶段正好产生 8 个 SPI 时钟周期。

### 任务 4：接收 Flash 数据

让 Controller 释放 `spi1`，在 SPI 上升沿采样 Flash 返回的数据。

先只接收 1 个字节，确认正确后再扩展到 4 个字节。

验收要求：

- 接收数据按 MSB first 拼接；
- 只在有效采样边沿更新接收移位寄存器；
- 收到 4 个字节后才结束 SPI 事务；
- 结束时拉高 `spi_csn`，并保存接收到的数据。

### 任务 5：接入 APB

把 APB 读请求接到 Flash 访问状态机。

验收要求：

- 合法 APB 读能启动一次 Flash 读；
- Flash 访问期间 `PREADY=0`；
- 返回数据时 `PREADY=1` 且 `PRDATA` 正确；
- 下一次访问不会复用上一次访问的地址、计数器或数据；
- 写访问、未对齐访问和非法地址不会让总线卡死。

### 任务 6：完整仿真

至少验证以下地址：

- `0x0000_0000`：起始地址；
- `0x0000_0004`：普通对齐地址；
- `0x00FF_FFFC`：最后一个可以完整读取 4 字节的地址；
- 一个未对齐地址，例如 `0x0000_0001`；
- 一个超出映射范围的地址，例如 `0x0100_0000`。

## 8. 仿真验收标准

基础题满足以下条件即可认为完成：

- APB 读事务的握手符合 APB 时序；
- SPI 时钟频率为 1 MHz，空闲电平为低；
- 命令为 `0x0B`，地址为 24 bit，且 MSB first；
- dummy clock 数量为 8；
- 能从 Flash 模型中读出 4 个连续字节；
- `PRDATA` 的字节顺序符合本题约定；
- 至少连续完成两次不同地址的读操作；
- 复位后 `spi_csn` 不会误动作；
- `spi0` 和 `spi1` 没有明显的总线冲突或 `X` 扩散；
- 仿真波形中可以清晰看到 APB 等待、SPI 访问和 APB 完成三个阶段。

建议在 testbench 中加入如下检查：

```systemverilog
assert (spi_clk_frequency == 1_000_000);
assert (dummy_count == 8);
assert (read_command == 8'h0B);
assert (pready |-> !$isunknown(prdata));
```

上面的代码只是检查思路示例，不要求直接复制使用。

## 9. 进阶挑战（可选）

完成基础题后，可以继续实现以下功能：

### 9.1 可配置 SPI 频率

增加配置寄存器，让软件或 APB Master 可以设置 SPI 分频值。需要注意：配置改变时不能破坏正在进行的 Flash 访问。

### 9.2 可配置 dummy clock

增加 dummy clock 配置寄存器，并验证不同 Flash 速度下的读取结果。

### 9.3 间接访问模式

不再把整个 Flash 地址空间直接映射到 APB，而是增加一组寄存器，例如：

| 寄存器 | 作用 |
| --- | --- |
| `ADDR` | Flash 起始地址 |
| `LENGTH` | 读取长度 |
| `CMD` | Flash 命令 |
| `CTRL` | 启动访问 |
| `STATUS` | 忙/完成/错误状态 |
| `DATA` | 读取结果 |

这种模式更接近实际芯片中的 Flash Controller，但也需要处理软件启动、状态轮询和 FIFO 等问题。

### 9.4 QSPI 或 Quad Read

在基础的单线 SPI 读通路上扩展双线或四线数据通路。扩展前请先明确每个阶段使用几根数据线，以及数据在哪些边沿采样。

## 10. 参考资料

- QSPI/SPI 协议：`SPIQSPI specification.pdf`
- APB 协议说明：[APB 总线协议](https://www.yuejianzun.xyz/2017/09/30/APB%E6%80%BB%E7%BA%BF%E5%8D%8F%E8%AE%AE/)
- NOR Flash 器件手册：`mt25q_qlhs_l_128_aba_0.pdf`
