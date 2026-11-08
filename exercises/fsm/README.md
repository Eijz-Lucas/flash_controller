# 题 5：Flash 事务状态机

## 目标与接口

补全 `design.v`。复位异步低有效。`phase` 编码固定为 `IDLE=0, CMD=1, ADDR=2, DUMMY=3, DATA_TX=4, DATA_RX=5`。空闲时接受单拍 `start`，在该时钟上升沿锁存 `has_addr`、`has_dummy`、`do_read`，转入 `CMD`。之后即使这些输入变化，也按锁存选项运行。

在 CMD 等 `cmd_done`；若有地址转 ADDR，否则按选项进入 DUMMY 或数据相。ADDR 等 `addr_done`，DUMMY 等 `dummy_done`。数据相由 `do_read` 决定 `DATA_RX` 或 `DATA_TX`，等 `data_done` 后回 IDLE，输出单拍 `done`。等待期间状态不变。`busy = phase != IDLE`；`cs_n` 在整个事务低，IDLE 高。只要求状态与片选控制，不做移位和分频。

## 功能波形

带地址和 dummy 的读事务：

```wavedrom
{ "signal": [
  {"name":"clk", "wave":"p......."},
  {"name":"start", "wave":"10......"},
  {"name":"cmd_done", "wave":"0.10...."},
  {"name":"addr_done", "wave":"0..10..."},
  {"name":"dummy_done", "wave":"0...10.."},
  {"name":"data_done", "wave":"0.....10"},
  {"name":"phase", "wave":"=.=.=.=.=.=", "data":["IDLE","CMD","ADDR","DUMMY","DATA_RX","IDLE"]},
  {"name":"cs_n", "wave":"10.....1"},
  {"name":"done", "wave":"0......10"}
]}
```

## 验证

```sh
make fsm
```

Testbench 检查完整读路径、选项锁存、等待、跳过可选阶段的写路径、片选与 `done` 单拍。成功打印 `RESULT: PASS fsm`。
