# 题 7：单线 SPI 接收移位器

## 目标与接口

补全 `design.v`。`rst_n` 异步低有效，复位后 `data=0`、`busy=done=0`。空闲时在 `clk` 上升沿接受 `start`，清空 `data` 并置 `busy=1`。之后仅在 `busy && rise_pulse` 的系统时钟上升沿采样 `sdi`，执行 `data <= {data[6:0], sdi}`。每次采样一个 bit，先收最高位；第八次采样后得到完整字节，`busy=0` 且 `done=1` 一拍。忙时忽略 `start`；空闲时忽略 `rise_pulse`。脉冲间隔中 `data` 保持。本题不产生 SPI 时钟，`rise_pulse` 由外部提供。

## 功能波形

每列是 `clk` 一个周期，显示上升沿后的值。`start` 后每隔一拍采样一次 `sdi`，顺序接收 `8'hA6 = 1010_0110`。第 4 列忙时再次拉高 `start`，接收不被打断。`data` 展示逐次移入后的值；第 8 次 `rise_pulse` 后 `done` 单拍有效。

```wavedrom
{ "signal": [
  {"name":"clk", "wave":"p................."},
  {"name":"start", "wave":"01010............."},
  {"name":"rise_pulse", "wave":"0.1010101010101010"},
  {"name":"sdi", "wave":"0.1.0.1.0...1...0."},
  {"name":"data", "wave":"=.=.=.=.=.=.=.=.=.", "data":["00","01","02","05","0A","14","29","53","A6"]},
  {"name":"busy", "wave":"01..............0."},
  {"name":"done", "wave":"0...............10"}
]}
```

`data` 标签均为十六进制；连续保持的二值电平用 `.` 表示。图中的 `rise_pulse` 对应系统时钟上升沿上的采样使能。

## 验证

```sh
make spi_rx
# 波形：sim/spi_rx.vcd
```

Testbench 逐位检查移位值、脉冲间保持、忙时忽略 `start`、第八位完成、`done` 单拍及空闲时忽略输入。通过时打印 `RESULT: PASS spi_rx`；失败时打印 `FAIL spi_rx` 并非零退出。
