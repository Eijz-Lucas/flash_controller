# 题 3：单线 SPI 发送移位器

## 目标与接口

补全 `design.v`。`start` 在空闲时有效，时钟上升沿锁存 `data[7:0]` 并置 `busy=1`。锁存之后立刻让 `sdo` 输出最高位，先发 bit 7。每个 `fall_pulse` 对应一个已传完的位：前 7 个脉冲使数据左移并准备下一位；第 8 个脉冲结束发送，`busy=0`，`done=1` 一拍。`done` 平时为 0；忙时忽略新的 `start`。复位异步低有效；复位后 `busy=done=0`。`fall_pulse` 是同步单拍脉冲，本题不生成 SPI 时钟。

## 功能波形

以 `8'hA6 = 1010_0110` 为例。`0`～`7` 分别是第 1～8 个 `fall_pulse` **之前**的观测点；`8` 是第 8 个脉冲后的完成拍，`9` 是下一拍。每一列对应 VCD 中同编号的 `doc_point`，列宽不代表等长时间。

```wavedrom
{ "signal": [
  {"name":"sample", "wave":"==========", "data":["0","1","2","3","4","5","6","7","8","9"]},
  {"name":"sdo", "wave":"1010011000"},
  {"name":"busy", "wave":"1111111100"},
  {"name":"done", "wave":"0000000010"}
]}
```

发送数据在 SPI 上升沿被 Flash 采样，本模块只在所给下降沿推进。连续 `fall_pulse` 的间隔可大于一拍，期间数据必须稳定。

## 验证

```sh
make spi_tx
```

Testbench 逐位检查 `A6` 的顺序、前七位 `busy`、第八位完成及 `done` 单拍。成功打印 `RESULT: PASS spi_tx`。
完整时序保存在 `sim/spi_tx.vcd`；测试命令还会逐列核对上图与 VCD。
