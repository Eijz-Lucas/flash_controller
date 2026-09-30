// -----------------------------------------------------------------------------
// dut_harness.v
//
// 所有测试共用的外壳。它负责：
//   1. 实例化 DUT（apb_flash_top）和 flash_model，并把 SPI pad 对接起来
//   2. 生成 HCLK、看门狗、可选的 VCD 波形
//   3. 把测试需要的内部信号集中成一组探针输出
//
// 测试**只实例化本模块、只连它的端口**，不直接实例化 DUT，也不写内部层次路径。
// 层次路径只出现在这里一处，RTL 改动时只有本文件需要跟着改，测试不受影响。
//
// -----------------------------------------------------------------------------
// 关于 pad
// -----------------------------------------------------------------------------
// apb_flash_top 的顶层数据口是 `inout [3:0] spi_dq`，三态（oe 选择驱动/高阻）在
// RTL 内部完成。本文件只是把这一根双向线和 flash_model 接到一起，**不做**任何
// sdo/oe/sdi 的拼接 —— 那会掩盖掉 RTL 自己的方向逻辑，让「谁在驱动」这件事失去
// 单一出处。
//
// -----------------------------------------------------------------------------
// 关于 quad_mode
// -----------------------------------------------------------------------------
// flash_model 需要一个 quad_en 输入来决定命令/地址走 1 根线还是 4 根线。真实 Flash
// 是靠解析 opcode 知道的，但本 RTL 的约定是「en_quad 有效时命令/地址/数据全走 4 线」
// （见 flash_controller.v 的 s_spi_mode 选择），opcode 本身就在 4 根线上，模型无法
// 自行判断，所以由外部显式给出。
//
// quad_mode 由测试驱动（做 quad 事务前置 1）。harness 会在事务开始后自动比对它与
// DUT 内部实际的 en_quad 是否一致，不一致就把 probe_quad_mismatch 置起来 —— 免得
// 测试写错了模式却得到一个「看起来像 RTL bug」的失败。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module dut_harness #(
    parameter CLK_HALF = 5,           // HCLK 半周期 (ns)：5 -> 10ns -> 100 MHz
    parameter TIMEOUT  = 2_000_000    // 看门狗超时 (ns)
)(
    // ---- 时钟（由本模块生成，测试用它的沿来驱动/采样）----
    output reg         HCLK,

    // ---- APB 主机接口（由测试驱动）----
    input  wire        HRESETn,
    input  wire [31:0] PADDR,
    input  wire [31:0] PWDATA,
    input  wire        PWRITE,
    input  wire        PSEL,
    input  wire        PENABLE,
    output wire [31:0] PRDATA,
    output wire        PREADY,
    output wire        PSLVERR,

    input  wire        quad_mode,     // 告诉 Flash 模型本次事务是否四线

    // ---- 探针（只读，供测试断言与看波形）----
    output wire        probe_cs_n,         // SPI 片选（低有效）
    output wire        probe_sclk,         // SPI 时钟
    output wire [4:0]  probe_state,        // flash_controller 的 FSM 状态
    output wire [1:0]  probe_spi_mode,     // SPI_STD / SPI_QUAD_TX / SPI_QUAD_RX
    output wire        probe_ctrl_idle,    // FSM 是否在 IDLE
    output wire [31:0] probe_rxfifo_data,  // RX FIFO 输出数据
    output wire        probe_rxfifo_valid, // RX FIFO 非空
    output wire [15:0] probe_sclk_rises,   // 本次片选的 spi_clk 上升沿数
    output wire [31:0] probe_last_seq,     // 模型收到 {opcode, addr}
    output wire        probe_bus_conflict, // 模型检测到 pad 冲突
    output wire        probe_quad_mismatch // quad_mode 与 DUT 实际 en_quad 不符
);

//------------------------------------------------------------------
// HCLK
//------------------------------------------------------------------
    initial HCLK = 1'b0;
    always #(CLK_HALF) HCLK = ~HCLK;

//------------------------------------------------------------------
// DUT 与 Flash 模型
//------------------------------------------------------------------
    wire        spi_clk;
    wire        spi_csn0;

    wire [3:0]  dq;                       // 控制器 <-> Flash 的共享总线（DUT 的 inout pad）
    wire [31:0] last_seq;
    wire        bus_conflict;

    apb_flash_top u_dut (
        .HCLK       ( HCLK       ),
        .HRESETn    ( HRESETn    ),
        .PADDR      ( PADDR      ),
        .PWDATA     ( PWDATA     ),
        .PWRITE     ( PWRITE     ),
        .PSEL       ( PSEL       ),
        .PENABLE    ( PENABLE    ),
        .PRDATA     ( PRDATA     ),
        .PREADY     ( PREADY     ),
        .PSLVERR    ( PSLVERR    ),
        .spi_clk    ( spi_clk    ),
        .spi_csn0   ( spi_csn0   ),
        .spi_dq     ( dq         )
    );

    // DQ 是真正的双向线：控制器的三态在 apb_flash_top 内部做，这里只是把它和
    // Flash 模型接到同一根线上。测试不再需要（也不应该）自己拼 sdo/oe/sdi。

    flash_model u_flash (
        .cs_n         ( spi_csn0     ),
        .sclk         ( spi_clk      ),
        .dq           ( dq           ),
        .quad_en      ( quad_mode    ),
        .last_seq     ( last_seq     ),
        .bus_conflict ( bus_conflict )
    );

//------------------------------------------------------------------
// 探针
//------------------------------------------------------------------
    assign probe_cs_n         = spi_csn0;
    assign probe_sclk         = spi_clk;
    assign probe_state        = u_dut.u_spictrl.cur_state;
    assign probe_spi_mode     = u_dut.spi_mode;
    assign probe_ctrl_idle    = (u_dut.u_spictrl.cur_state == 5'd0);
    assign probe_rxfifo_data  = u_dut.spi_data_rx;
    assign probe_rxfifo_valid = u_dut.spi_data_rx_valid;
    assign probe_last_seq     = last_seq;

    // pad 冲突：**按片选窗口**粘滞。
    //
    // 模型给的 bus_conflict 是纯组合的 —— 只在 dq 真被两方同时驱动的那一刻有效。
    // 事务一结束 cs_n 拉高、两边 oe 全放掉，再读它就恒为 0，等于没接。
    // 所以这里在**一次片选之内**把它粘住，片选结束时锁存，测试在事务跑完之后
    // 读到的是「刚过去这笔事务有没有抢过线」。
    //
    // 为什么不做成「复位前一直粘着」：一个用例里会跑好几笔事务，那样某一笔的
    // 冲突会一直留到最后，把「这次读干净吗」这条断言变成「整个用例里干净吗」
    // —— 测的就不是同一件事了。
    //
    // conflict_seen 挂 HCLK 采样：sclk 最快也只有 HCLK 的 1/2，真正的抢线
    // （oe 配错）会持续整个相，不可能只出现一个毛刺，所以采样不会漏。
    // 锁存时额外或上当拍的组合值，免得冲突恰好发生在 cs_n 拉高前最后一拍。
    reg conflict_seen = 1'b0;   // 本次片选内是否冲突过
    reg conflict_last = 1'b0;   // 上一笔事务的结论
    always @(posedge HCLK) begin
        if (!HRESETn)          conflict_seen <= 1'b0;
        else if (spi_csn0)     conflict_seen <= 1'b0;
        else if (bus_conflict) conflict_seen <= 1'b1;
    end
    always @(negedge spi_csn0 or posedge spi_csn0) begin
        if (!spi_csn0) conflict_last <= 1'b0;
        else           conflict_last <= conflict_seen | bus_conflict;
    end
    assign probe_bus_conflict = spi_csn0 ? conflict_last : conflict_seen;

    // 最近一笔片选内的 spi_clk 上升沿计数。
    // 单驱动：两个触发条件写在同一个 always 里。
    // 必须给初值：复位后 cs_n 一直无效、spi_clk 也不动，这个块根本不会触发，
    // 没有初值探针就是 X，测试会拿到「X != 0」这种看不出所以然的失败。
    //
    // 这个值是**粘滞**的：清零走的是同一个 always 的 else 分支，而安静期
    // （cs_n 为高、spi_clk 不翻转）没有任何边沿，块根本不执行 —— 它就一直保持
    // 上一笔事务的数字。所以它只能断言「刚跑完的那笔事务有多少个时钟」，
    // 不能断言「这段时间没有 SPI 流量」：那种断言会因为「从没被写过」而空过。
    // 要数事务请自己挂一个 CS 沿的计数器。
    reg [15:0] sclk_rises = 16'd0;
    always @(negedge spi_csn0 or posedge spi_clk) begin
        if (!spi_csn0 && spi_clk) sclk_rises <= sclk_rises + 16'd1;
        else                      sclk_rises <= 16'd0;
    end
    assign probe_sclk_rises = sclk_rises;

    // quad_mode 与 DUT 实际 en_quad 的一致性监视。
    // 等 2 个 SPI 时钟之后再比：事务刚发起那一拍 en_quad_int 还在更新，不宜下结论。
    wire h_en_quad = u_dut.u_spictrl.en_quad;
    reg  quad_mismatch = 1'b0;
    always @(posedge HCLK) begin
        if (!spi_csn0 && (sclk_rises >= 16'd2) && (quad_mode !== h_en_quad))
            quad_mismatch <= 1'b1;
    end
    assign probe_quad_mismatch = quad_mismatch;

//------------------------------------------------------------------
// 可选波形：make wave TC=<case> 会传 -DDUMPFILE
//------------------------------------------------------------------
`ifdef DUMPFILE
    initial begin
        $dumpfile(`DUMPFILE);
        $dumpvars(0, dut_harness);
    end
`endif

//------------------------------------------------------------------
// 看门狗
//------------------------------------------------------------------
    initial begin
        #(TIMEOUT);
        $display("[%0t] HARNESS: FAIL - 仿真超时，FSM 卡在 state=%0d spi_mode=%b cs_n=%b",
                 $time, u_dut.u_spictrl.cur_state, u_dut.spi_mode, spi_csn0);
        $fatal;
    end

endmodule
