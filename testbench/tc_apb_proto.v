// -----------------------------------------------------------------------------
// tc_apb_proto.v —— 测试用例 apb
//
// 目的：在碰 SPI 之前，先把 APB 从机本身钉死。它是后面所有测试的地基 —— 如果
// 握手不可信，任何读回值都不可信。
//
// 检查内容
//   1. 复位后 PREADY / PSLVERR / PRDATA 无 X
//   2. **setup 相（PSEL=1, PENABLE=0）PREADY 必须为 0**，access 相才拉高
//      —— 这一条直接验证 flash_ctrl_apb_if 里 PREADY 与 RX FIFO 弹出的解耦修复。
//      修复前 spi_data_rx_ready 在 setup 相就被拉高并直接驱动 PREADY，主机会在
//      setup 相就认为读完成，从而读到 X。
//   3. 每个可读寄存器的 PRDATA 32 位全非 X
//   4. CLKDIV 写后读回一致
//   5. 未映射寄存器 0x30 返回 0（而不是 X）
//   6. PADDR[1:0] 与 PADDR[31:6] 被忽略（只有 PADDR[5:2] 参与译码）
//
// 运行：make apb
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tc_apb_proto;

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

    reg [31:0] rd;

    initial begin
        $display("==== tc_apb_proto: APB protocol and handshake ====");
        reset_dut;

        // ---- 1. 复位后的静态状态 ----
        check_true(PSLVERR === 1'b0,        "PSLVERR is 0 out of reset");
        check_true(PREADY  === 1'b0,        "PREADY is 0 while PSEL=0");
        check_true(probe_ctrl_idle === 1'b1, "controller FSM is in IDLE after reset");

        // ---- 2. setup 相 PREADY 必须为低，access 相才拉高 ----
        //    这一段手写传输，不用 BFM，因为要观察 setup 相中间的值。
        @(negedge HCLK);
        PADDR = `A_CLKDIV; PWRITE = 1'b0; PSEL = 1'b1; PENABLE = 1'b0;
        @(negedge HCLK);                                  // setup 相中点
        check_true(PREADY === 1'b0, "PREADY stays LOW during setup phase");
        PENABLE = 1'b1;                                   // 进 access 相
        @(posedge HCLK);
        check_true(PREADY === 1'b1, "PREADY goes HIGH in access phase");
        check_true(PSLVERR === 1'b0, "PSLVERR is 0 on a good read");
        @(negedge HCLK);
        apb_idle;
        repeat (2) @(negedge HCLK);

        // ---- 3. 每个可读寄存器都不得返回 X ----
        //    REG_RXFIFO 不在此列：它在数据到达前会让 PREADY 一直为低，属于 tc_fast_read
        apb_read(`A_STATUS, rd); check_true(^rd !== 1'bx, "PRDATA STATUS  fully defined");
        apb_read(`A_CLKDIV, rd); check_true(^rd !== 1'bx, "PRDATA CLKDIV  fully defined");
        apb_read(`A_SPICMD, rd); check_true(^rd !== 1'bx, "PRDATA SPICMD  fully defined");
        apb_read(`A_SPIADR, rd); check_true(^rd !== 1'bx, "PRDATA SPIADR  fully defined");
        apb_read(`A_SPILEN, rd); check_true(^rd !== 1'bx, "PRDATA SPILEN  fully defined");
        apb_read(`A_SPIDUM, rd); check_true(^rd !== 1'bx, "PRDATA SPIDUM  fully defined");

        // ---- 3b. 保留地址 0x24 / 0x28：未映射，必须读回 0 ----
        //    PRDATA 落到 default 分支。断言「恰好是 0」而不是「不是 X」：
        //    如果哪天有人把这两个地址接到别的信号上，这两条会立刻红。
        apb_expect_read(`A_RSVD24, 32'h0, "reserved 0x24 reads as 0");
        apb_expect_read(`A_RSVD28, 32'h0, "reserved 0x28 reads as 0");

        // ---- 4. 写后读回 ----
        apb_write(`A_CLKDIV, 32'h0000_0031);
        apb_expect_read(`A_CLKDIV, 32'h0000_0031, "CLKDIV write/read round trip");
        apb_write(`A_CLKDIV, 32'h0000_0007);
        apb_expect_read(`A_CLKDIV, 32'h0000_0007, "CLKDIV write/read round trip 2");

        // ---- 5. 未映射寄存器返回 0，不返回 X ----
        apb_expect_read(32'h30, 32'h0000_0000, "unmapped 0x30 reads as 0");

        // ---- 6. 只有 PADDR[5:2] 参与译码 ----
        apb_write(`A_CLKDIV, 32'h0000_0011);
        apb_expect_read(`A_CLKDIV,         32'h0000_0011, "PADDR[1:0] ignored (0x04)");
        apb_expect_read(32'h07,            32'h0000_0011, "PADDR[1:0] ignored (0x07)");
        apb_expect_read(32'h0000_0104,     32'h0000_0011, "PADDR[31:6] ignored (0x104)");
        apb_expect_read(32'hFFFF_FF04,     32'h0000_0011, "PADDR[31:6] ignored (0xFFFFFF04)");

        // ---- 7. 一路读下来不应触发任何 SPI 活动 ----
        check_true(probe_last_seq === 32'h0, "no SPI transaction was started");
        check_true(probe_ctrl_idle === 1'b1, "controller still idle at the end");

        report_and_finish("tc_apb_proto");
    end

endmodule
