# 题 2：SPI Mode 0 时钟分频器

## 目标与接口

补全 `design.v`。`clk` 是系统时钟；`rst_n` 异步低有效。`en=1` 时产生空闲为低的 `sclk`，每 `div+1` 个系统时钟上升沿翻转一次。因此 `div=0` 时每拍翻转，`div=1` 时每两拍翻转。`en=0` 或复位时立刻在下一个系统时钟把分频计数和 `sclk` 清零。重新使能从完整半周期开始。

在 `sclk` 从 0 翻成 1 的那个系统时钟周期，`rise_pulse=1`；从 1 翻成 0 时，`fall_pulse=1`。两个脉冲单拍有效、互斥，其他周期为零。测试时 `div` 在使能期间保持不变。

## 功能波形

`div=1`，每两拍翻转；SPI Mode 0 的发送端可在下降沿更新，接收端在上升沿采样。

```wavedrom
{ "signal": [
  {"name":"clk", "wave":"p......."},
  {"name":"en", "wave":"1......."},
  {"name":"div", "wave":"=.......", "data":["1"]},
  {"name":"sclk", "wave":"0.1.0.1."},
  {"name":"rise_pulse", "wave":"0.10..10"},
  {"name":"fall_pulse", "wave":"0...10.."}
]}
```

## 验证

```sh
make clkdiv
```

Testbench 检查复位、`div=1` 的半周期、上升/下降脉冲、停钟清相位、`div=0`。成功打印 `RESULT: PASS clkdiv`。
