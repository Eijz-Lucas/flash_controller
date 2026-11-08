# 题 4：SPI 四线三态 pad

## 目标与接口

补全 `design.v`。`sdo[3:0]` 是控制器输出值，`dq[3:0]` 是双向引脚，`sdi[3:0]` 是控制器读到的引脚电平。每位使用连续赋值实现三态：本端不驱动时输出 `1'bz`。`sdi` 始终读 `dq`，不能直接回读 `sdo`。本题为纯组合逻辑。

| mode | 方向 | 本端驱动掩码 `dq[3:0]` |
| --- | --- | --- |
| `2'b00` | 空闲或四线接收 | `0000` |
| `2'b01` | 单线发送 | `0001`，只驱动 DQ0 |
| `2'b10` | 四线发送 | `1111` |
| `2'b11` | 保留，安全高阻 | `0000` |

Testbench 使用另一个连续赋值模拟 Flash 对 `dq` 的驱动；同一根线上同时驱动不同值会出现 `X`，因此需正确控制方向。

## 功能波形

`sdo=4'b1010`；Flash 在接收阶段驱动 `4'b0101`。

```wavedrom
{ "signal": [
  {"name":"mode", "wave":"=.=.=.=", "data":["idle","single TX","quad TX","quad RX"]},
  {"name":"flash_oe", "wave":"0....1."},
  {"name":"dq", "wave":"z.=.=.=", "data":["zzz0","1010","0101"]},
  {"name":"sdi", "wave":"z.=.=.=", "data":["zzz0","1010","0101"]}
]}
```

## 验证

```sh
make tristate
```

Testbench 检查高阻、DQ0 单线驱动、Flash 驱动 DQ1、四线发送和四线接收。成功打印 `RESULT: PASS tristate`。
