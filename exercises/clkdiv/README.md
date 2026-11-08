# 题 2：SPI Mode 0 时钟分频器

## 目标与接口

补全 `design.v`。`clk` 是系统时钟；`rst_n` 异步低有效。`en=1` 时产生空闲为低的 `sclk`，每 `div+1` 个系统时钟上升沿翻转一次。因此 `div=0` 时每拍翻转，`div=1` 时每两拍翻转。`en=0` 或复位时立刻在下一个系统时钟把分频计数和 `sclk` 清零。重新使能从完整半周期开始。

在 `sclk` 从 0 翻成 1 的那个系统时钟周期，`rise_pulse=1`；从 1 翻成 0 时，`fall_pulse=1`。两个脉冲单拍有效、互斥，其他周期为零。测试时 `div` 在使能期间保持不变。

## 功能波形

每一列是 VCD 中的 `doc_point`。`0` 为复位，`1`～`4` 是 `div=1` 使能后的连续四个系统时钟上升沿，`5` 为禁用，`6`～`7` 是 `div=0` 的两个上升沿。`rise_pulse` 和 `fall_pulse` 与翻转后的 `sclk` 同拍有效。

```wavedrom
{ "signal": [
  {"name":"sample", "wave":"========", "data":["0","1","2","3","4","5","6","7"]},
  {"name":"en", "wave":"01111011"},
  {"name":"div", "wave":"=.....=.", "data":["1","0"]},
  {"name":"sclk", "wave":"00110010"},
  {"name":"rise_pulse", "wave":"00100010"},
  {"name":"fall_pulse", "wave":"00001001"}
]}
```

## 验证

```sh
make clkdiv
```

Testbench 检查复位、`div=1` 的半周期、上升/下降脉冲、停钟清相位、`div=0`。成功打印 `RESULT: PASS clkdiv`。
完整时序保存在 `sim/clkdiv.vcd`；测试命令还会逐列核对上图与 VCD。
