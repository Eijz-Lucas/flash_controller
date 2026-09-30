# Flash Controller

---

## 1. 项目结构

```
flash_attention/
├── makefile                     
├── README.md                    
│
├── doc/
│   ├── flash_controller.md
│   └── spec.md                  
│
├── rtl/
│   ├── flash_ccontroller/
│   │   ├── apb_flash_top.v      顶层：APB 从机 + 控制器 + 两个 FIFO + SPI 三态 pad
│   │   ├── flash_controller.v   事务状态机（IDLE/CMD/ADDR/DUMMY/DATA_TX/DATA_RX/WAIT_EDGE）
│   │   ├── flash_ctrl_apb_if.v  APB 寄存器组、PREADY/PRDATA
│   │   ├── flash_ctrl_tx.v      发送移位器（单线 / 四线）
│   │   ├── flash_ctrl_rx.v      接收移位器（单线 / 四线）
│   │   ├── flash_ctrl_clkgen.v  SPI 时钟分频，产生 spi_rise / spi_fall
│   │   ├── flash_ctrl_fifo.v    同步 FIFO wrapper
│   │   └── define.v             宏：寄存器地址、SPI_MODE 编码、默认参数
│   └── IP/
│       ├── syn_fifo.v           同步 FIFO
│       └── dpram_wrap.v         双口 RAM（FIFO 的存储体）
│
├── testbench/
│   ├── dut_harness.v            
│   ├── tb_common.vh             
│   ├── tc_*.v                   
│   └── flash_model/
│       ├── flash_model.v        行为级 SPI NOR Flash 模型（单线 + 四线，读 + 写）
│       ├── flash_model_tb.v     
│       └── flash_mem_init.vh    
│
├── filelist/                    iverilog 的 -c 文件列表
│   ├── rtl.f                    RTL
│   ├── dtb.f                    
│   ├── tc_<case>.f              每个用例一份
│   └── flash_model_tb.f         
│
└── sim/                         所有产物：<用例>.vvp / <用例>.vcd / 展开后的 f
```

---

## 2. 依赖

| 依赖 | 版本 | 说明 |
| --- | --- | --- |
| Icarus Verilog | 12.0 | 必需。`iverilog` + `vvp` |
| GNU make | 任意 | 跑 makefile |
| 波形查看器 | 任意 | 可选。本机用 VSCode 的 Surfer 插件（`make gui`）；波形是标准 VCD，gtkwave 等同样可以 |

### ubuntu 依赖安装

```bash
sudo apt update
sudo apt install iverilog
```

安装检查
```bash
iverilog -v
# Icarus Verilog version 12.0 (stable) ()
```
## 3. 运行

```bash
make                  # 等价于 make all：环境检查 + 模型冒烟 + 全部 8 个用例
make read             # 只跑某一个用例（用例名见 make list）
make list             # 列出所有用例及其验证内容
make vcd              # 列出已生成的波形
make gui TC=write     # 用 VSCode 打开 sim/write.vcd
make NOWAVE=1 all     # 快跑一遍，不生成波形
make clean            # 删掉整个 sim/（含波形）
make clean-keep-vcd   # 只删编译产物，保留波形
```

### 波形

跑任何用例都会同时留下 `sim/<用例名>.vcd`，不需要额外的开关；`make wave TC=<用例>`
仍然可用，它现在只是 `make <用例>` 的别名。

`make clean` 会连波形一起删掉。只想清编译产物、留住波形（波形要重跑整个仿真才回得来）
用 `make clean-keep-vcd`。

---

## 4. 测试用例一览

每个用例都打印带标签的 `PASS` / `FAIL` 行，最后给出 `RESULT: PASS|FAIL`。

| 目标 | 文件 | 证明什么 |
| --- | --- | --- |
| `smoke` | `flash_model_tb.v` | 模型本身对：`0x9F`/`0x03`/`0x0B`/`0x6B` 的位序与存储内容，以及 `0x06`+`0x02` 的写语义。不经过 APB |
| `apb` | `tc_apb_proto.v` | APB 握手（setup/access 两相、`PREADY` 时机）、`PSLVERR` 恒 0、未映射地址（`0x24`/`0x28` 读回 0）、写后读回 |
| `regs` | `tc_reg_rw.v` | `CLKDIV`/`SPICMD`/`SPIADR`/`SPILEN`/`SPIDUM` 的复位值与写后读回；`SPILEN` 位域打包；`cmd_len` 6 bit 截断；`STATUS` 是控制器状态打包字 |
| `read` | `tc_fast_read.v` | 一次完整的 STIG 单线 Fast Read，从 APB 寄存器一路走到 pad 再回来 |
| `addr` | `tc_addr_sweep.v` | 24 bit 地址通路整条宽度（`0x000000` / `0x000020` / `0xFFFFFC` / `0xFFFFF8`） |
| `b2b` | `tc_back2back.v` | 连续两次读、中间不复位：第二次不带第一次的残留 |
| `div` | `tc_clkdiv.v` | 分频 |
| `quad` | `tc_quad_read.v` | 四线读测试 |
| `write` | `tc_write_read.v` | 写测试 |

### 期望值的来源

Flash 模型和测试平台 `include` 同一个 `flash_mem_init.vh`，用同一个函数算字节值：

```
flash_mem_pattern(a) = a[7:0] ^ a[15:8] ^ 8'h5A
```

所以期望值不会随模型内容漂移。几个常用值：

| Flash 地址 | 4 字节 | APB 读回 `PRDATA` |
| --- | --- | --- |
| `0x000000` | `5A 5B 58 59` | `0x5A5B5859` |
| `0x000020` | `7A 7B 78 79` | `0x7A7B7879` |
| `0xFFFFFC` | `59 58 5B 5A` | `0x59585B5A`（地址对 64 KiB 取模，见下） |

模型的存储是 64 KiB，地址取模，所以 `0xFFFFFC` 会落在 `0xFFFC`。真 16 MiB 数组在
iverilog 下要 64 MB 堆 + 1600 万次初始化，对功能验证没有收益。需要真实范围时改
`flash_model.v` 的 `MEM_BYTES` 参数即可。取模规则同时写在模型、测试平台和 spec 里，
期望值始终可算。

---

## 5. 查看波形

跑完任意用例，波形就在 `sim/<用例名>.vcd`：

```bash
make all                 # 8 个用例 + 冒烟，共 9 份波形
make vcd                 # 列出来
make gui TC=write        # 用 VSCode 打开 sim/write.vcd
```

`makefile` 里的 `gui` 只是把文件交给 `code`，由 VSCode 的 Surfer 插件接管 `.vcd` 的
打开方式。换成任何别的 viewer 都不影响波形本身。

`dut_harness.v` 里已经备好一组探针，直接拖出来看：

| 探针 | 内容 |
| --- | --- |
| `probe_cs_n` / `probe_sclk` | SPI 片选与时钟（片选低有效） |
| `probe_state` | `flash_controller` 的 FSM 状态 |
| `probe_spi_mode` | `SPI_STD` / `SPI_QUAD_TX` / `SPI_QUAD_RX` |
| `probe_ctrl_idle` | 控制器是否在 IDLE |
| `probe_rxfifo_data` / `_valid` | RX FIFO 输出 |
| `probe_sclk_rises` | 本次片选内的 SPI 上升沿数 |
| `probe_last_seq` | 模型解析出的 `{opcode, addr}` |

---

## 6. 下一步

- `doc/spec.md` —— 寄存器映射、FSM 状态表、一次 Fast Read 的逐位推演、讲义契约映射表
- `doc/flash_controller.md` —— 题目原文
