# 题 1：APB 寄存器从机

## 目标与接口

补全 `design.v`。时钟为 `clk`，复位 `rst_n` 异步低有效。APB 使用 setup（`psel=1, penable=0`）和 access（`psel=1, penable=1`）两相；传输仅在 access 相生效。本题无等待周期。

| 地址 | 访问 | 行为 |
| --- | --- | --- |
| `0x00` | 读写 | `clk_div` 取写入数据的低 8 位；复位值 3，读回零扩展到 32 位 |
| `0x04` | 只读 | 直接返回输入 `status` |
| `0x08` | 只写 | 写入值 bit 0 为 1 时产生 `command_pulse` |
| 其他 | 读零、忽略写 | 不产生错误 |

`pready` 只在 `psel && penable` 时为 1；`pslverr` 恒为 0。`command_pulse` 只在 `0x08` 的有效写 access 相为 1，setup 相和未选中时为 0。读数据使用组合逻辑，未映射地址不得返回 `X` 或推断锁存器。写操作在 access 相的时钟上升沿更新 `clk_div`。

## 功能波形

下图每列对应 `clk` 一个周期，显示上升沿后的信号值。第 1 列为空闲，第 2 列为写 setup，第 3 列为写 access，`clk_div` 在该上升沿写为 `0x2A`；第 5、6 列分别为读 setup、读 access。输入由 Testbench 在前一个下降沿切换。

```wavedrom
{ "signal": [
  {"name":"clk", "wave":"p....."},
  {"name":"psel", "wave":"01.01."},
  {"name":"penable", "wave":"0.10.1"},
  {"name":"pwrite", "wave":"01.0.."},
  {"name":"pwdata", "wave":"==....", "data":["0","0x2A"]},
  {"name":"pready", "wave":"0.10.1"},
  {"name":"clk_div", "wave":"=.=...", "data":["3","0x2A"]},
  {"name":"prdata", "wave":"=.=...", "data":["3","0x2A"]}
]}
```

## 验证

```sh
make apb
# 或 make EX=apb run
```

Testbench 检查复位值、两相握手、写入和读回、只读状态、未映射地址及命令脉冲。通过时末行是 `RESULT: PASS apb`；失败时打印 `FAIL apb` 并退出。
完整时序保存在 `sim/apb.vcd`。
