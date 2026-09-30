// -----------------------------------------------------------------------------
// tc_back2back.v —— 测试用例 b2b
//
// 目的：连读两次、中间不复位。讲义把「连续访问」列为验收项，而这一类 bug 的
// 典型症状是第二次事务还带着第一次的残留（命令/地址没换、FIFO 没清、
// FSM 停在 WAIT_EDGE 没回 IDLE）。
//
// 所以本用例除了比对数据，还要求：
//   - 两次事务的 {opcode, addr} 探针**都**正确（第二次的地址确实到了 pad 上）
//   - 两次数据不同（不同地址取到不同字节），排除「第二次读了第一次的缓存」
//   - 两次的 SPI 时钟数都是 72（第二次没有被缩短或拉长）
//
// 期望值全由 exp_word() / flash_mem_pattern() 算出，与 Flash 模型同源。
//
// 运行：make b2b
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tc_back2back;

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

    reg [23:0] A1 = 24'h000010;      // 两次读的地址不同，数据也就不同
    reg [23:0] A2 = 24'h000100;

    reg [31:0] rd1, rd2;
    reg [31:0] seq1, seq2;           // 各事务结束时的 last_seq 快照
    reg [15:0] ris1, ris2;           // 各事务的 SPI 时钟数快照

    initial begin
        $display("==== tc_back2back: two reads, no reset in between ====");
        $display("  -- addr 0x%06x then 0x%06x --", A1, A2);

        reset_dut;

        // ---- 第一次 ----
        stig_fast_read(8'd0, 32'h0B00_0000, A1, 16'd8, rd1);
        seq1 = probe_last_seq;
        ris1 = probe_sclk_rises;

        check_eq (rd1,  exp_word(A1), "first read data");
        check_eq (seq1, {8'h0B, A1},  "first read {opcode, addr} on pad");
        check_int(ris1, 8 + 24 + 8 + 32, "first read SPI clocks");

        // ---- 第二次：中间不复位，只重写寄存器 ----
        stig_fast_read(8'd0, 32'h0B00_0000, A2, 16'd8, rd2);
        seq2 = probe_last_seq;
        ris2 = probe_sclk_rises;

        check_eq (rd2,  exp_word(A2), "second read data");
        check_eq (seq2, {8'h0B, A2},  "second read {opcode, addr} on pad");
        check_int(ris2, 8 + 24 + 8 + 32, "second read SPI clocks");

        // ---- 交叉检查 ----
        check_true(rd1 !== rd2,                 "two addresses returned different data");
        check_true(seq1 !== seq2,               "second transaction carried a new address");
        check_true(probe_ctrl_idle === 1'b1,    "controller back to IDLE after both");
        check_true(probe_bus_conflict === 1'b0, "no pad bus conflict across both");

        report_and_finish("tc_back2back");
    end

endmodule
