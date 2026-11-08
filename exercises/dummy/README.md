# 题 8：SPI dummy 周期计数

## 目标与接口

补全 `design.v`。`rst_n` 异步低有效；复位后 `remaining=0`、`busy=done=0`。空闲时在 `clk` 上升沿接受 `start`，锁存 `cycles[3:0]` 到 `remaining`。若 `cycles=0`，同拍给出单拍 `done=1`，保持空闲。若非零，置 `busy=1`；之后只有 `tick=1` 的系统时钟上升沿才消耗一个 dummy 周期，使 `remaining` 减 1。最后一个 tick 后 `remaining=0`、`busy=0`、`done=1` 一拍。忙时忽略 `start`；没有 tick 时计数保持。本题只计数，不生成 SPI 时钟。

## 功能波形

每列是 `clk` 一个周期，显示上升沿后的值。先启动 3 个 dummy 周期；第 5 列忙时以 `cycles=7` 再次启动会被忽略。三个 `tick` 使 `remaining` 从 3 降到 0；随后启动 0 周期事务，立即产生另一个单拍 `done`。

```wavedrom
{ "signal": [
  {"name":"clk", "wave":"p.........."},
  {"name":"start", "wave":"010.10...10"},
  {"name":"cycles", "wave":"==..=....=.", "data":["0","3","7","0"]},
  {"name":"tick", "wave":"0..101010.."},
  {"name":"remaining", "wave":"==.=.=.=...", "data":["0","3","2","1","0"]},
  {"name":"busy", "wave":"01.....0..."},
  {"name":"done", "wave":"0......1010"}
]}
```

`cycles` 和 `remaining` 为十进制；连续保持的二值电平用 `.` 表示。

## 验证

```sh
make dummy
# 波形：sim/dummy.vcd
```

Testbench 检查复位、仅 tick 递减、忙时忽略新启动、终点 `done`、零周期立即完成及脉冲清除。通过时打印 `RESULT: PASS dummy`；失败时打印 `FAIL dummy` 并非零退出。
