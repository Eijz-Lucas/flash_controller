# Flash Controller 核心练习

本分支包含八道可独立完成的 Verilog 练习。每题的 `design.v` 只有模块接口；按题目文档实现模块后，运行对应 Testbench。题目聚焦原项目的 APB、SPI、三态、分频、FIFO 和状态机知识点，不要求拼成完整 Flash Controller。

## 环境与运行

需要 `iverilog`、`vvp` 和 `make`。在仓库根目录执行：

```sh
make list                 # 列出题目
make apb                  # 运行单题；通过打印 RESULT: PASS
make all                  # 运行全部题目，生成 sim/*.vcd
make EX=spi_tx run        # 另一种单题运行方式
```

每题在 `exercises/<题名>/` 中包含 `README.md`（要求和 WaveDrom 波形）、`design.v`（待实现接口）、`tb.v`（自检 Testbench）。运行后生成 `sim/<题名>.vcd`，可用 GTKWave、Surfer 等查看。文档波形按 Testbench 的 `clk` 周期绘制；三态题的 `clk` 只属于 Testbench，用于安排组合逻辑激励。失败时打印 `FAIL` 并以非零状态退出。未实现的接口理应使测试失败。`answer` 分支提供对应实现。

| 题名 | 核心知识点 |
| --- | --- |
| [apb](exercises/apb/README.md) | APB setup/access、寄存器读写、脉冲 |
| [clkdiv](exercises/clkdiv/README.md) | SPI Mode 0 分频与边沿脉冲 |
| [spi_tx](exercises/spi_tx/README.md) | SPI 单线 MSB 先发、发送握手 |
| [tristate](exercises/tristate/README.md) | `inout` 三态与单线/四线方向 |
| [fsm](exercises/fsm/README.md) | Flash 事务状态机与分支 |
| [sync_fifo](exercises/sync_fifo/README.md) | 同步 FIFO 满空判断、同拍读写 |
| [spi_rx](exercises/spi_rx/README.md) | SPI 单线接收与 MSB 先收 |
| [dummy](exercises/dummy/README.md) | SPI dummy 周期计数 |

原项目的完整端到端实现和测试仍可从 `main` 分支查看。
