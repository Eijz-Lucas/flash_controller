# 题 5：Flash 事务状态机

## 目标与接口

补全 `design.v`。复位异步低有效。`phase` 编码固定为 `IDLE=0, CMD=1, ADDR=2, DUMMY=3, DATA_TX=4, DATA_RX=5`。空闲时接受单拍 `start`，在该时钟上升沿锁存 `has_addr`、`has_dummy`、`do_read`，转入 `CMD`。之后即使这些输入变化，也按锁存选项运行。

在 CMD 等 `cmd_done`；若有地址转 ADDR，否则按选项进入 DUMMY 或数据相。ADDR 等 `addr_done`，DUMMY 等 `dummy_done`。数据相由 `do_read` 决定 `DATA_RX` 或 `DATA_TX`，等 `data_done` 后回 IDLE，输出单拍 `done`。等待期间状态不变。`busy = phase != IDLE`；`cs_n` 在整个事务低，IDLE 高。只要求状态与片选控制，不做移位和分频。

## 功能波形

下图每列对应 `clk` 一个周期，显示上升沿后的信号值。第 1～8 列是带地址和 dummy 的读事务（第 3 列仍等待命令完成）；第 9～11 列是跳过地址和 dummy 的写事务。`phase` 使用上文固定的数字编码。

```wavedrom
{ "signal": [
  {"name":"clk", "wave":"p.........."},
  {"name":"phase", "wave":"==.====.===", "data":["0","1","2","3","5","0","1","4","0"]},
  {"name":"cs_n", "wave":"10....1.0.1"},
  {"name":"busy", "wave":"01....0.1.0"},
  {"name":"done", "wave":"0.....10..1"}
]}
```

## 验证

```sh
make fsm
```

Testbench 检查完整读路径、选项锁存、等待、跳过可选阶段的写路径、片选与 `done` 单拍。成功打印 `RESULT: PASS fsm`。
完整时序保存在 `sim/fsm.vcd`。
