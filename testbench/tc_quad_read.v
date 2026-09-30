// -----------------------------------------------------------------------------
// tc_quad_read.v —— 测试用例 quad
//
// 目的：同一份数据用两种读法读出来必须**完全一样**。
//
// 为什么这条用例不可替代
//   单线读对了，并不能证明位序对。四线通路的位序是另一种排法：
//       flash_ctrl_tx.v:118-121   sdo0=[28] sdo1=[29] sdo2=[30] sdo3=[31]
//       flash_ctrl_rx.v:121       {rx_data_locked[27:0], sdi3, sdi2, sdi1, sdi0}
//   即 DQ0 承载 nibble 的**最低位**。把这条约定搞反，症状恰恰是「单线读全对、
//   quad 读每个字节的高低位半字节反序」—— 结果看着合理，所以单线用例抓不到。
//   本用例把同一个地址用 0x0B（单线）和 0x6B（四线）各读一次做交叉验证。
//
// 时钟数（与单线的 72 对比）
//   命令 8 bit /4 = 2，地址 24 bit /4 = 6，dummy 8（单位是 SPI 时钟周期，不 /4），
//   数据 32 bit /4 = 8，合计 24。见 flash_ctrl_tx.v:106 / flash_ctrl_rx.v:109 的
//   {2'b0, counter_in[15:2]}。
//
// 关于 harness 的 quad_mode
//   本 RTL 的四线约定是「命令 + 地址 + 数据全走 4 线」，与真实 NOR Flash 的 0x6B
//   （命令/地址仍是单线）不同。模型判断不了，所以由测试通过 harness 的 quad_mode
//   显式告知，并靠 probe_quad_mismatch 反向确认测试没写错模式。
//
// 运行：make quad
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tc_quad_read;

    `include "flash_mem_init.vh"

    reg         HCLK;
    reg         HRESETn = 1'b0;
    reg  [31:0] PADDR   = 32'h0;
    reg  [31:0] PWDATA  = 32'h0;
    reg         PWRITE  = 1'b0;
    reg         PSEL    = 1'b0;
    reg         PENABLE = 1'b0;
    wire [31:0] PRDATA;
    wire        PREADY;
    wire        PSLVERR;

    reg         harness_quad_mode = 1'b0;

    wire [4:0]  probe_state;
    wire [1:0]  probe_spi_mode;
    wire        probe_ctrl_idle;
    wire [31:0] probe_rxfifo_data;
    wire        probe_rxfifo_valid;
    wire [15:0] probe_sclk_rises;
    wire [31:0] probe_last_seq;
    wire        probe_bus_conflict;
    wire        probe_quad_mismatch;

    dut_harness u_harness (
        .HCLK                ( HCLK                ),
        .HRESETn             ( HRESETn             ),
        .PADDR               ( PADDR               ),
        .PWDATA              ( PWDATA              ),
        .PWRITE              ( PWRITE              ),
        .PSEL                ( PSEL                ),
        .PENABLE             ( PENABLE             ),
        .PRDATA              ( PRDATA              ),
        .PREADY              ( PREADY              ),
        .PSLVERR             ( PSLVERR             ),
        .quad_mode           ( harness_quad_mode   ),
        .probe_cs_n          (                     ),
        .probe_sclk          (                     ),
        .probe_state         ( probe_state         ),
        .probe_spi_mode      ( probe_spi_mode      ),
        .probe_ctrl_idle     ( probe_ctrl_idle     ),
        .probe_rxfifo_data   ( probe_rxfifo_data   ),
        .probe_rxfifo_valid  ( probe_rxfifo_valid  ),
        .probe_sclk_rises    ( probe_sclk_rises    ),
        .probe_last_seq      ( probe_last_seq      ),
        .probe_bus_conflict  ( probe_bus_conflict  ),
        .probe_quad_mismatch ( probe_quad_mismatch )
    );

    `include "tb_common.vh"

    // 四线通路的 SPI_MODE 编码（define.v）
    localparam SPI_STD     = 2'b00;
    localparam SPI_QUAD_TX = 2'b01;
    localparam SPI_QUAD_RX = 2'b10;

    reg [23:0] ADDR = 24'h000020;
    reg [31:0] rd_single;
    reg [31:0] rd_quad;
    reg [31:0] rd_after;
    reg [15:0] ris_single;
    reg [15:0] ris_quad;

    initial begin
        $display("==== tc_quad_read: 0x0B (single) vs 0x6B (quad) on the same address ====");
        $display("  -- addr 0x%06x, expected PRDATA 0x%08x --", ADDR, exp_word(ADDR));

        reset_dut;

        // ------------------------------------------------------------------
        // 1. 先做单线读，拿到基准值（此刻模型的 quad_en 必须是 0）
        // ------------------------------------------------------------------
        harness_quad_mode = 1'b0;
        stig_fast_read(8'd0, 32'h0B00_0000, ADDR, 16'd8, rd_single);
        ris_single = probe_sclk_rises;

        check_eq (rd_single, exp_word(ADDR), "single-line 0x0B data");
        check_eq (probe_last_seq, {8'h0B, ADDR}, "single-line {opcode, addr} on pad");
        check_int(ris_single, 8 + 24 + 8 + 32,   "single-line SPI clocks (72)");
        check_true(probe_quad_mismatch === 1'b0,
                   "single-line: model quad_en matches DUT en_quad");

        // ------------------------------------------------------------------
        // 2. 再做四线读。触发前置 qrd=1（stig_quad_read 内部做），
        //    并同步把模型的 quad_en 拉起来。
        // ------------------------------------------------------------------
        harness_quad_mode = 1'b1;
        stig_quad_read(8'd0, 32'h6B00_0000, ADDR, 16'd8, rd_quad);
        ris_quad = probe_sclk_rises;

        $display("  info  single: data=0x%08x clocks=%0d", rd_single, ris_single);
        $display("  info  quad  : data=0x%08x clocks=%0d", rd_quad,   ris_quad);

        check_true(^rd_quad !== 1'bx, "quad PRDATA fully defined (no X)");
        check_eq (probe_last_seq, {8'h6B, ADDR}, "quad {opcode, addr} on pad");
        check_int(ris_quad, 2 + 6 + 8 + 8,       "quad SPI clocks (bit counts /4)");
        check_true(probe_quad_mismatch === 1'b0,
                   "quad: model quad_en matches DUT en_quad");

        // ------------------------------------------------------------------
        // 3. 交叉验证 —— 本用例存在的理由
        // ------------------------------------------------------------------
        check_eq (rd_quad, rd_single,  "quad read == single-line read (bit order)");
        check_eq (rd_quad, exp_word(ADDR), "quad read == reference memory");
        check_true(ris_quad < ris_single,  "quad moves the same 64 bits in fewer clocks");

        check_true(probe_bus_conflict === 1'b0, "no pad bus conflict in either read");
        check_true(probe_ctrl_idle === 1'b1,    "controller back to IDLE after both");

        // ------------------------------------------------------------------
        // 4. 四线之后紧跟一笔单线读 —— 给模型的三态方向切换留一个回归保护
        //
        // 这一段跟上面两步**方向相反**，而方向正是它存在的理由。
        //
        // 这一段的理由是模型的 dq_oe 必须在片选下降沿清零：否则上一笔四线事务
        // 留下的 1111 会在下一笔单线事务的数据相开头（进入数据相到第一个下降沿
        // 之间那半个 SPI 周期）继续驱动全部四根线，而控制器此刻是 SPI_STD、
        // 正在驱动 DQ0 —— 抢线，读回值全变成 x。
        //
        // tc_quad_read 是唯一同时用到两种线宽的用例，所以这条序列放在这里：
        // 去掉模型的清零，本段的 no pad bus conflict 会立刻失败。
        // ------------------------------------------------------------------
        harness_quad_mode = 1'b0;
        stig_fast_read(8'd0, 32'h0B00_0000, ADDR, 16'd8, rd_after);

        check_true(^rd_after !== 1'bx, "single-line after quad: PRDATA fully defined (no X)");
        check_eq (rd_after, rd_single, "single-line after quad == earlier single-line read");
        check_int(probe_sclk_rises, 8 + 24 + 8 + 32,
                  "single-line after quad: SPI clocks (72)");
        check_true(probe_bus_conflict === 1'b0,
                   "single-line after quad: no pad bus conflict");
        check_true(probe_quad_mismatch === 1'b0,
                   "single-line after quad: model quad_en matches DUT en_quad");
        check_true(probe_ctrl_idle === 1'b1, "controller IDLE at end of test");

        report_and_finish("tc_quad_read");
    end

endmodule
