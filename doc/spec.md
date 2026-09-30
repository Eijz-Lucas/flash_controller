# Flash Controller 规格说明

---

## 1. 范围

### 1.1 概述

一个 APB 从机形态的可配置 SPI Master

```
APB Master  <── APB ──>  flash_controller  <── SPI ──>  NOR Flash
```

Flash Controller不通过「APB 地址到 Flash 地址」隐式映射，而是通过一组寄存器：APB总线配置命令、地址、
长度、dummy 个数，置触发位，控制器将事务在 SPI 上跑一遍，收到的数据进 RX
FIFO，再由 APB 读走。

### 1.2 工作模式

只有一种：STIG(Software Triggered Instruction Generation) —— 软件写 `STATUS` 触发位，控制器跑一次事务。

`STATUS[9:8]` 是这个模式的编码，读回恒为 `2'b01`，是只读常量，写 `PWDATA[9:8]` 被忽略。

### 1.3 复位

异步复位、低有效（`HRESETn`）。复位后：FSM 在 `IDLE`，`spi_mode = SPI_QUAD_RX`
（四根数据线全高阻），`clk_div = 3`，其余寄存器为 0，两个 FIFO 为空。
`STATUS` 读回 `0x0000_0101`。

---

## 2. 框图

```
                    ┌──────────────────────────────────────────────────────────┐
                    │                  apb_flash_top                           │
                    │                                                          │
   APB  ────────────►  flash_ctrl_apb_if                                                 │
   (PSEL/PENABLE/   │   ├── 寄存器组（STATUS/CLKDIV/SPICMD/SPIADR/SPILEN/SPIDUM/…）│
    PWRITE/PADDR/   │   ├── 地址译码 → PRDATA 多路选择                              │
    PWDATA)         │   └── rd_ready → PREADY（读何时完成）                         │
                    │            │                                             │
                    │            │ spi_rd/wr/qrd/qwr, spi_cmd, spi_addr, len…    │
                    │            ▼                                             │
                    │      flash_controller  ◄──── spi_status[7:0]             │
                    │   ┌──────────────────────────────────────────┐           │
                    │   │ FSM: IDLE→CMD→ADDR→DUMMY→DATA_RX/DATA_TX │           │
                    │   │      →WAIT_EDGE→IDLE                     │           │
                    │   └───┬───────────────┬──────────────┘                   │
                    │       │ tx_data       │ rx_data                          │
                    │       ▼               ▲                                  │
                    │  flash_ctrl_tx   flash_ctrl_rx                           │
                    │       │ sdo0..3       │ sdi0..3                          │
                    │       ▼               │                                  │
                    │   ┌───┴───────────────┴───┐      flash_ctrl_clkgen       │
                    │   │  三态 pad 合成（inout）│◄──── spi_clock_en, clk_div   │
                    │   │  spi_dq[3:0]          │      → spi_clk, spi_cs       │
                    │   └───────────┬───────────┘                              │
                    │               │                                          │
                    │        ┌──────┴──────┐                                   │
                    │        │  TX FIFO    │  ┌──────────┐                     │
                    │        │  RX FIFO    │◄─┤ elements │──► spi_status[20:16]│
                    │        └─────────────┘  └──────────┘                     │
                    └───────────────┬──────────────────────────────────────────┘
                                    │ spi_clk / spi_csn0 / spi_dq[3:0]
                                    ▼
                              ┌───────────┐
                              │ NOR Flash │
                              └───────────┘
```

数据通路：APB 寄存器 → (TX 移位器) → pad → Flash → pad → (RX 移位器) → RX FIFO → APB 读。

---

## 3. 端口

### 3.1 顶层端口（`apb_flash_top`）

| 信号 | 方向 | 宽度 | 说明 |
| --- | --- | --- | --- |
| `HCLK` | in | 1 | 系统时钟（讲义约定 100 MHz） |
| `HRESETn` | in | 1 | 异步复位，低有效 |
| `PADDR` | in | 32 | APB 地址。只用 `PADDR[5:2]` 译码，`[1:0]` 与 `[31:6]` 被忽略 |
| `PWDATA` | in | 32 | APB 写数据 |
| `PWRITE` | in | 1 | 1 = 写，0 = 读 |
| `PSEL` | in | 1 | APB 选中 |
| `PENABLE` | in | 1 | APB 访问相 |
| `PRDATA` | out | 32 | APB 读数据 |
| `PREADY` | out | 1 | 0 = 主机继续等待 |
| `PSLVERR` | out | 1 | 恒 0 |
| `spi_clk` | out | 1 | SPI 时钟，空闲低电平（Mode 0） |
| `spi_csn0` | out | 1 | SPI 片选，低有效 |
| `spi_dq` | inout | 4 | SPI 数据线 DQ0~DQ3。三态只在这一层做 |

### 3.2 SPI pad 的三态

控制器内部一路到底都是分开的 `sdo0..3` / `sdi0..3` / `oe0..3`，双向只在顶层合成：

```verilog
assign spi_dq[n] = spi_oe[n] ? spi_sdo[n] : 1'bz;   // n = 0..3
assign spi_sdi[n] = spi_dq[n];
```

方向是 `spi_mode` 的组合函数（`apb_flash_top.v`）：

| `spi_mode` | 编码 | `spi_oe[3:0]` | 含义 |
| --- | --- | --- | --- |
| `SPI_STD` | `2'b00` | `4'b0001` | 只有 DQ0 是输出 |
| `SPI_QUAD_TX` | `2'b01` | `4'b1111` | 四根全输出 |
| `SPI_QUAD_RX` | `2'b10` | `4'b0000` | 四根全高阻 |

行为细节：

1. 复位和 `IDLE` 时 `spi_mode = SPI_QUAD_RX`，四根全部高阻，不会和 Flash 抢线。
2. 单线读（`SPI_STD`）时 `spi_oe0` 一直是 1，也就是控制器在数据相仍然驱动 DQ0。

---

## 4. APB 寄存器映射

### 4.1 地址译码

`PADDR[5:2]` 译码成 `write_address/read_address`（`define.v` 里的 `REG_*`），`PADDR[1:0]` 和
`PADDR[31:6]` 被忽略。所以 `0x00`、`0x40`、`0x00FF_FF00` 指的是同一个寄存器。

| `PADDR[5:2]` | 地址 | 名称 | 可写 | 说明 |
| --- | --- | --- | --- | --- |
| `4'b0000` | `0x00` | `STATUS` | ✔ | 触发位；读回来的是控制器状态打包字 |
| `4'b0001` | `0x04` | `CLKDIV` | ✔ | SPI 时钟分频，只用低 8 bit |
| `4'b0010` | `0x08` | `SPICMD` | ✔ | 命令字（32 bit） |
| `4'b0011` | `0x0C` | `SPIADR` | ✔ | 地址字（32 bit） |
| `4'b0100` | `0x10` | `SPILEN` | ✔ | 长度 |
| `4'b0101` | `0x14` | `SPIDUM` | ✔ | 读/写 dummy 个数 |
| `4'b0110` | `0x18` | `TXFIFO` | ✔ | 写数据入 TX FIFO |
| `4'b1000` | `0x20` | `RXFIFO` | 读 | 读数据出 RX FIFO |
| 其它 | — | — | — | 读回 0（`default: PRDATA = 'b0;`） |

### 4.2 寄存器位域

**`STATUS`（`0x00`）—— 写**

| 位 | 名称 | 说明 |
| --- | --- | --- |
| `[0]` | `spi_rd` | 触发一次单线读 |
| `[1]` | `spi_wr` | 触发一次单线写 |
| `[2]` | `spi_qrd` | 触发一次四线读（同时把 `en_quad` 拉起） |
| `[3]` | `spi_qwr` | 触发一次四线写 |
| `[9:8]` | — | 忽略（只读位域，读回恒 `2'b01`） |
| 其它 | — | 忽略 |

`[3:0]` 是单周期脉冲。`flash_ctrl_apb_if.v` 的时序块里，只有「本拍是 STATUS 的写访问」
那一拍才会置位，其余每一拍都清零。所以触发写必须放在寄存器编程序列的最后一步 —— 如果先
写 `STATUS` 再写 `SPICMD`，控制器会拿着旧命令就跑起来。

**`STATUS`（`0x00`）—— 读**

| 位 | 内容 |
| --- | --- |
| `[31:29]` | 0 |
| `[28:24]` | `elements_tx`（TX FIFO 元素数） |
| `[23:21]` | 0 |
| `[20:16]` | `elements_rx`（RX FIFO 元素数） |
| `[15:10]` | 0 |
| `[9:8]` | 恒 `2'b01`（只读常量，见 1.2） |
| `[7:0]` | `spi_status`（控制器 FSM 状态，见 7.2） |

复位后的值是 `0x0000_0101`（两个 FIFO 空、`[9:8]`=STIG、FSM 在 IDLE）。

**`CLKDIV`（`0x04`）** —— 只用低 8 bit，`[31:8]` 写入即丢。复位值 `3`。见第 6 节。

**`SPICMD`（`0x08`）** —— 32 bit，原样回读。发送时取的是高位：

```
cmd_len = 8  →  送出 spi_cmd[31:24]
```

所以 `0x0B` 命令必须写成 `0x0B00_0000`，不是 `0x0000_000B`。

**`SPIADR`（`0x0C`）** —— 32 bit，原样回读。同样高位对齐：

```
addr_len = 24  →  送出 spi_addr[31:8]
```

所以 24 bit 地址 `A` 必须写成 `A << 8`。

**`SPILEN`（`0x10`）** —— 三段长度打包，单位都是 bit：

```
SPILEN = { spi_data_len[15:0], 2'b00, spi_addr_len[5:0], 2'b00, spi_cmd_len[5:0] }
       = { data_len,            2'b00, addr_len,           2'b00, cmd_len            }
         [31:16]                      [15:8]                      [7:0]
```

| 字段 | 位 | 宽度 | 合法范围 |
| --- | --- | --- | --- |
| `cmd_len` | `[7:0]`（实际 6 bit） | 6 | 0~63 |
| `addr_len` | `[15:8]`（实际 6 bit） | 6 | 0~63 |
| `data_len` | `[31:16]` | 16 | 0~65535 |


**`SPIDUM`（`0x14`）** —— 读/写各一个 dummy 计数，单位是 SPI 时钟周期：

```
SPIDUM = { spi_dummy_wr[15:0], spi_dummy_rd[15:0] }
           [31:16]              [15:0]
```

复位值 0。四线模式下这个数不除以 4（dummy 是按周期数的，不是按 bit 数的），见 6.4 节。

**`TXFIFO`（`0x18`）** 的一条已知限制 —— 推入是无条件的：`spi_data_tx_valid` 不看 FIFO
满（FIFO 的 `ready_o` 没有接进来），满时这次推入静默丢失。深度 16字；软件也可以先读 `STATUS[28:24]` 看 `elements_tx`。

### 4.3 APB 应答（`PREADY`）

APB 事务两相：setup（`PSEL=1, PENABLE=0`）→ access（`PSEL=1, PENABLE=1`）。

| 传输 | `PREADY` |
| --- | --- |
| 写 | `PENABLE & PWRITE`（写访问相当拍即完成） |
| 读，非 `RXFIFO` 地址 | access 相立即为 1，`PRDATA` 当拍有效 |
| 读，`RXFIFO` 地址 | 等 `spi_data_rx_valid`（即 FIFO 非空）才为 1 |

`PSLVERR` 恒 0 —— 本实现不做错误响应。

在 STIG 模式下读空的 `RXFIFO`，`PREADY` 会一直保持 0 直到有数据为止，主机就一直等下去。

---

## 5. STIG 事务

### 5.1 读事务

软件写一组寄存器，然后写 `STATUS` 置一个触发位。控制器按

```
CMD → ADDR → DUMMY → DATA_RX → WAIT_EDGE → IDLE
```

跑一遍，收到的 32 bit 进 RX FIFO，由 APB 读 `RXFIFO` 取走。

编程序列（触发写必须最后）：

| # | 地址 | 写入值 | 作用 |
| --- | --- | --- | --- |
| 1 | `0x04` `CLKDIV` | `0x0000_0000` | `clk_div=0` → 50 MHz SPI |
| 2 | `0x08` `SPICMD` | `0x0B00_0000` | 命令 `0x0B`，高位对齐 |
| 3 | `0x0C` `SPIADR` | `addr24 << 8` | 24 bit 地址，高位对齐 |
| 4 | `0x10` `SPILEN` | `0x0020_1808` | `cmd_len=8`, `addr_len=24`, `data_len=32`（bit） |
| 5 | `0x14` `SPIDUM` | `0x0000_0008` | 8 个 dummy 时钟周期 |
| 6 | `0x00` `STATUS` | `0x0000_0101` | `[0]=spi_rd`, `[9:8]=2'b01`，最后写 |
| 7 | `0x20` `RXFIFO` | 读 | `PREADY` 会一直等到数据到达 |

四线读把第 6 步换成 `0x0000_0104`（`[2]=spi_qrd`），命令换成 `0x6B00_0000`。

### 5.2 写事务

把触发位换成 `[1]=spi_wr`，状态机路径变成

```
CMD → ADDR → DATA_TX → IDLE
```

两个差别：

- 没有 `WAIT_EDGE`。那是读通路专有的收尾状态（停时钟、等 SCLK 落地，让接收端在同一个
  低电平里不至于采两次）。发送相的最后一个数据位在下降沿就发完了，采样它的上升沿在此
  之前已经发生，所以发完直接回 IDLE。见 `flash_controller.v` 的 `DATA_TX` 分支。
- 数据来自 TX FIFO，而且必须在触发之前预装。`REG_TXFIFO` 的写是直通口
  （`spi_data_tx_valid = (PSEL&PENABLE&PWRITE) & (write_address == REG_TXFIFO)`），没有
  独立的装载时序；触发那一拍 FSM 就离开 IDLE 了，之后再写就来不及。每次 `DATA_TX` 只
  消费一个 32 bit 字。

一次单线 `Page Program`（`0x02`）的序列：

| # | 地址 | 写入值 | 作用 |
| --- | --- | --- | --- |
| 1 | `0x18` `TXFIFO` | 待写的 32 bit | 必须在触发前 |
| 2 | `0x04` `CLKDIV` | `0x0000_0000` | 50 MHz SPI |
| 3 | `0x08` `SPICMD` | `0x0200_0000` | 命令 `0x02` |
| 4 | `0x0C` `SPIADR` | `addr24 << 8` | 目标地址 |
| 5 | `0x10` `SPILEN` | `0x0020_1808` | `cmd=8`, `addr=24`, `data=32` |
| 6 | `0x14` `SPIDUM` | `0x0000_0000` | `Page Program` 不插 dummy |
| 7 | `0x00` `STATUS` | `0x0000_0102` | `[1]=spi_wr`, `[9:8]=2'b01`，最后写 |

SPI 时钟数：8(命令) + 24(地址) + 32(数据) = 64。

`WREN`（`0x06`）是另一笔独立事务：`SPILEN` 的 `addr_len=0`、`data_len=0`，于是 `CMD`
状态在 `tx_done` 之后直接 `next_state = IDLE;`，不经过 `ADDR`。SPI 时钟数正好 8。这是
RTL 里最短的一条事务路径。

---

## 6. 时钟分频

### 6.1 公式

`flash_ctrl_clkgen.v` 把 `HCLK` 分频成 `spi_clk`，占空比 50%：

```
f_sclk = f_HCLK / (2 * (clk_div + 1))
T_sclk = 2 * (clk_div + 1) * T_HCLK
```

是 divide-by-`2*(clk_div+1)`，不是 `2*clk_div`。

| `clk_div` | SPI 频率（`f_HCLK`=100 MHz） | 用途 |
| ---: | ---: | --- |
| 0 | 50 MHz | 所有功能用例的默认值 |
| 3 | 12.5 MHz | 复位默认值 |
| 49 | 1 MHz | |

### 6.2 两个脉冲：`spi_rise` / `spi_fall`

分频器同时产生两个脉冲，按「本次翻转之后的那条边沿」定义：

```
counter == counter_trgt 时：
    spi_clk 现在为 0  ->  即将上升  ->  spi_rise = running
    spi_clk 现在为 1  ->  即将下降  ->  spi_fall = running
```

- `spi_rise` 给接收用（Mode 0 在上升沿采样）；
- `spi_fall` 给发送用（Mode 0 在下降沿换数据）。

两者都是电平，被 `running` 和 `counter == counter_trgt` 门控。当 `counter_trgt == 0`
（`clk_div = 0`）时 `counter` 每次都被清成 0，比较式每拍都成立，于是 `spi_clk` 每隔一个
HCLK 翻转一次 —— 这就是表里 `clk_div=0` → 50 MHz 的来历。

---

## 7. 状态机

### 7.1 状态表

`flash_controller.v` 的 `cur_state`（5 bit），编号 `0..6` 连续：

| 状态 | 编码 | 片选 `spi_cs` | 时钟使能 `spi_clock_en` | `spi_mode` | 做什么 |
| --- | ---: | --- | --- | --- | --- |
| `IDLE` | 0 | 1（释放） | 0 | `QUAD_RX` | 等触发 |
| `CMD` | 1 | 0 | `tx_clk_en` | `en_quad ? QUAD_TX : STD` | 发命令 |
| `ADDR` | 2 | 0 | `tx_clk_en` | 同上 | 发地址 |
| `DUMMY` | 3 | 0 | 1 | `en_quad ? QUAD_RX : STD` | 空转 dummy 个时钟 |
| `DATA_TX` | 4 | 0 | `tx_clk_en` | `en_quad ? QUAD_TX : STD` | 从 TX FIFO 发数据（写通路） |
| `DATA_RX` | 5 | 0 | `rx_clk_en` | `en_quad ? QUAD_RX : STD` | 收数据 |
| `WAIT_EDGE` | 6 | 0 → 1 | 0 | 同上 | 停时钟、等 SCLK 落地、释放片选 |

### 7.2 `spi_status[7:0]`

组合输出：每个周期先清 0，当前状态再把自己的位置 1（`flash_controller.v` 的
`always @(*)`）。经 `STATUS` 的 `[7:0]` 读出来。

| 位 | 置位的状态 |
| --- | --- |
| `[0]` | `IDLE` |
| `[1]` | `CMD` |
| `[2]` | `ADDR` |
| `[3]` | 保留位，恒 0 |
| `[4]` | `DUMMY` |
| `[5]` | `DATA_TX` |
| `[6]` | `DATA_RX`、`WAIT_EDGE` |
| `[7]` | 保留位，恒 0 |

### 7.3 跳转

```
IDLE ──(任一触发位)──► CMD ──(tx_done)──► ADDR ──(tx_done)──► DUMMY ──(tx_done)──► DATA_RX
  ▲                                                                                  │
  └────────────────────────── WAIT_EDGE ◄──────────(rx_done)─────────────────────────┘
                                  │
                                  └──(spi_clk 落地)──► IDLE
```

进 `IDLE` 的条件就是 `spi_rd || spi_wr || spi_qrd || spi_qwr` 里任意一个置起。

各跳转的跳过条件（`flash_controller.v` 的 `IDLE` 状态）：

- `spi_cmd_len == 0` → 直接跳到 `ADDR`；
- `spi_addr_len == 0` → 直接跳到 `DUMMY` 或 `DATA_RX`；
- `spi_dummy_rd == 0` → 跳过 `DUMMY`，直接 `DATA_RX`；
- `spi_data_len == 0` → 直接结束，回 `IDLE`。

写事务走的是另一条支路（触发位置 `spi_wr` / `spi_qwr` 而不是 `spi_rd`）：

```
IDLE ──(任一触发位)──► CMD ──(tx_done, addr_len!=0)──► ADDR ──(tx_done)──► DATA_TX
  ▲                                                                            │
  └──────────────────────────────(tx_done)────────────────────────────────────┘
```

- 这里没有 `DUMMY`（`spi_dummy_wr = 0`），也没有 `WAIT_EDGE` —— `DATA_TX` 在 `tx_done`
  之后直接 `next_state = IDLE;`。
- `ADDR` 的跳过条件在写路径上退化成了「`spi_addr_len == 0` 就直接 `DATA_TX`」（没有
  dummy 可选）。
- 只发命令的事务（`WREN`：`addr_len = 0` 且 `data_len = 0`）在 `CMD` 的 `tx_done` 处就
  结束了，既不去 `ADDR` 也不去 `DATA_TX`：

  ```
  IDLE ──(任一触发位)──► CMD ──(tx_done, addr_len==0 && data_len==0)──► IDLE
  ```

  这是全 RTL 最短的一条事务路径，SPI 时钟数正好 8。`tc_write_read` 覆盖它。

### 7.4 完成信号 `tx_done` / `rx_done`

```verilog
tx_done = (tx_cur_state == TRANSMIT) && (counter == counter_trgt - 1) && tx_edge;
rx_done = (rx_cur_state == RECEIVE)  && (counter == counter_trgt);
```

这两个信号是控制器内部用的。软件判断事务是否结束只有两条路：读 `RXFIFO` 时 `PREADY` 会
一直等到达，主机拿到 `PRDATA` 就等于知道事务完成了；写事务没有 RX 数据，看 `STATUS[0]`
（`IDLE`）。

---


## 8.Example: 一次 STIG 单线 Fast Read 的完整时序

以讲义里的那次读为例：`clk_div=0`（50 MHz SPI）、命令 `0x0B`、地址 `0x000020`、
8 个 dummy、读 32 bit。

### 8.1 pad 级序列

`spi_csn0` 在整个过程中保持低电平。

| 相 | 时钟数 | DQ0 上是什么 | DQ1 上是什么 |
| --- | ---: | --- | --- |
| Command | 8 | `0x0B`（MSB first） | 忽略 |
| Address | 24 | `0x000020`（MSB first） | 忽略 |
| Dummy | 8 | 0（`DATA_EMPTY`，全 0） | 忽略 |
| Data | 32 | 控制器仍在驱动（见 3.2 细节 2） | Flash 驱动，控制器在上升沿采样 |
| — | 合计 72 | | |

### 8.2 数据的拼接

接收器每次上升沿做：

```verilog
rx_data_locked <= { rx_data_locked[30:0], sdi1 };      // 单线
rx_data_locked <= { rx_data_locked[27:0], sdi3, sdi2, sdi1, sdi0 };   // 四线
```

32 个上升沿之后，`rx_data_locked[31]` 是收到的第一位。所以字节 0 落在 `[31:24]`。

Flash 里 `0x000020` 起 4 个字节是 `7A 7B 78 79`（见 9.3），于是：

```
PRDATA = 0x7A7B7879
```

这正是讲义要求的「小端拼接」：`Flash[0x20..0x23] = 11,22,33,44 → PRDATA = 0x44332211`。
RTL 的字节序与讲义一致，不需要任何改动。

### 8.3 本工程 Flash 模型的存储内容

模型和测试平台 `include` 同一个 `flash_mem_init.vh`，地址 `a` 处的字节：

```
flash_mem_pattern(a) = a[7:0] ^ a[15:8] ^ 8'h5A
```

低 16 位都参与运算，所以任何丢掉高位地址的译码错误都会让读回值不同，而不是「看着像对
的」。`tc_addr_sweep` 就是靠这个性质验证 24 bit 地址通路的。

| 地址 | 字节 | `PRDATA` |
| --- | --- | --- |
| `0x000000` | `5A 5B 58 59` | `0x5A5B5859` |
| `0x000020` | `7A 7B 78 79` | `0x7A7B7879` |
| `0xFFFC`（`0xFFFFFC` 取模后） | `59 58 5B 5A` | `0x59585B5A` |

模型只有 64 KiB，地址对 `MEM_BYTES` 取模。理由见第 10 节。

### 8.4 四线读的位序

`flash_ctrl_tx.v` 发送时：

```verilog
sdo0 = tx_data_locked[28];   sdo1 = [29];   sdo2 = [30];   sdo3 = [31];
```

即 DQ0 承载 nibble 的最低位。接收时按 `{sdi3, sdi2, sdi1, sdi0}` 拼回。

搞反的症状是「单线读全对、quad 读每个字节的高低位半字节互换」—— 值看着合理，所以单线
用例抓不到。`tc_quad_read` 拿同一个地址用 `0x0B` 和 `0x6B` 各读一次做交叉验证，就是专门
抓这个的。

---

## 9. 验证

`make all` 的构成：

| 用例 | 检查项数 | 证明什么 |
| --- | ---: | --- |
| `smoke` | 25 | Flash 模型本身的位序与存储内容，含 `WREN`/`Page Program` 的写语义（不经过 APB） |
| `apb` | 23 | APB 握手、`PSLVERR` 恒 0、未映射地址（`0x24`/`0x28` 读回 0）、写后读回 |
| `regs` | 20 | 寄存器映射、位域打包、6 bit 截断、`STATUS` 打包字（含 `[9:8]` 只读恒 STIG） |
| `read` | 7 | 完整的一次 STIG 单线 Fast Read |
| `addr` | 16 | 24 bit 地址通路（含 `0xFFFFFC` 边界） |
| `b2b` | 10 | 连续两次读，中间不复位 |
| `div` | 13 | `clk_div=49` → 1 MHz、8 dummy、72 时钟（讲义数字契约） |
| `quad` | 19 | 四线读与单线读结果一致（位序交叉验证）；四线之后紧跟一笔单线读，守住 pad 方向切换 |
| `write` | 22 | 写通路：`WREN 0x06`（8 时钟，`CMD → IDLE`）+ `Page Program 0x02`（64 时钟）+ 读回逐位相等；不发 `WREN` 则写不进去 |

一共 155 条断言，全部通过；`iverilog -Wall` 零警告；产物是 `sim/` 下 9 份 VCD
（8 个用例 + `smoke`，用例名到波形文件名一一对应，如 `sim/read.vcd`）。

端到端标准：`make clean && make all` 全部通过，且每个用例失败时 `vvp` 以非零码退出。
