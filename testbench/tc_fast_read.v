// -----------------------------------------------------------------------------
// tc_fast_read.v —— 测试用例 read
//
// 这是整个项目的核心用例：它第一次把 APB -> 寄存器 -> FSM -> SPI pad -> Flash
// 模型 -> RX FIFO -> APB 整条链路走通。
//
// 时序（单线 0x0B Fast Read，clk_div=0 -> 50 MHz SPI）：
//     命令 8 个时钟 + 地址 24 个时钟 + dummy 8 个时钟 + 数据 32 个时钟 = 72
//
// 寄存器编程序列见 tb_common.vh 的 stig_prog / stig_go。两个最容易踩的坑：
//   - cmd/addr 必须高位对齐（0x0B -> 0x0B000000，addr -> addr<<8）
//   - 触发写必须最后做（STATUS[3:0] 是单周期脉冲）
//
// 运行：make read
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tc_fast_read;

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

    wire        probe_cs_n;
    wire        probe_sclk;

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
        .probe_cs_n          ( probe_cs_n          ),
        .probe_sclk          ( probe_sclk          ),
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

    reg [23:0] ADDR = 24'h000020;
    reg [31:0] rd;


    initial begin
        $display("==== tc_fast_read: one full STIG single-line Fast Read ====");
        reset_dut;

        // ---- 一次完整的 0x0B Fast Read ----
        stig_fast_read(8'd0, 32'h0B00_0000, ADDR, 16'd8, rd);

        $display("  info  last_seq=0x%08x  sclk_rises=%0d  state=%0d spi_mode=%b",
                 probe_last_seq, probe_sclk_rises, probe_state, probe_spi_mode);

        check_eq(rd, exp_word(ADDR), "RX FIFO data");
        check_true(^rd !== 1'bx,     "PRDATA fully defined (no X)");

        // ---- pad 级的证据 ----
        check_eq(probe_last_seq, {8'h0B, ADDR}, "flash saw {opcode, addr}");
        check_int(probe_sclk_rises, 8 + 24 + 8 + 32, "total SPI clocks per transaction");
        check_true(probe_bus_conflict === 1'b0,   "no pad bus conflict");
        check_true(probe_quad_mismatch === 1'b0,  "single-line: model quad_en matches DUT en_quad");

        // ---- 事务结束后控制器回到 IDLE ----
        check_true(probe_ctrl_idle === 1'b1, "controller returned to IDLE");

        report_and_finish("tc_fast_read");
    end

endmodule
