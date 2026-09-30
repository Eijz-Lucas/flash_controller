// -----------------------------------------------------------------------------
// tc_addr_sweep.v —— 测试用例 addr
//
// 目的：证明 24 bit 地址通路整条宽度都是通的，而不是只有低位在工作。
//
// 取址依据
//   flash_mem_pattern() 用 a[15:8] ^ a[7:0] 生成字节，**高 8 位地址直接参与**。
//   所以只要地址高位在传输中被丢掉或错位，读回值就一定不同 —— 不是「看着像对的」。
//
// 四个地址
//   0x000000  全 0，基准
//   0x000020  讲义里用的那个地址
//   0xFFFFFC  24 bit 地址空间的最后一个 4 字节对齐地址
//   0xFFFFF8  倒数第二个（验证地址加法时的进位，不越界）
//
// 存储器是 64 KiB、地址取模（见 flash_model.v），所以 0xFFFFFC 落在 0xFFFC。
// 期望值由 exp_word() 用同一个 flash_mem_pattern() 算，不会和模型内容漂移。
//
// 运行：make addr
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tc_addr_sweep;

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

    reg [23:0] addr_list [0:3];
    reg [31:0] rd;
    integer    k;

    initial begin
        $display("==== tc_addr_sweep: 24-bit address path, four addresses ====");

        addr_list[0] = 24'h000000;
        addr_list[1] = 24'h000020;
        addr_list[2] = 24'hFFFFFC;
        addr_list[3] = 24'hFFFFF8;

        for (k = 0; k < 4; k = k + 1) begin
            $display("  -- addr 0x%06x (expected PRDATA 0x%08x) --",
                     addr_list[k], exp_word(addr_list[k]));

            reset_dut;
            stig_fast_read(8'd0, 32'h0B00_0000, addr_list[k], 16'd8, rd);

            check_eq (rd, exp_word(addr_list[k]), "  RX data matches reference");
            check_eq (probe_last_seq, {8'h0B, addr_list[k]},
                                          "  flash saw {opcode, addr}");
            check_int(probe_sclk_rises, 8 + 24 + 8 + 32,
                                          "  SPI clocks in transaction");
            check_true(probe_ctrl_idle === 1'b1, "  controller back to IDLE");
        end

        report_and_finish("tc_addr_sweep");
    end

endmodule
