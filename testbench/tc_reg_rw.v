// -----------------------------------------------------------------------------
// tc_reg_rw.v —— 测试用例 regs
//
// 目的：把寄存器映射钉死，后面的用例才有「我写进去的就是我以为的那个值」这个前提。
//
// 检查内容
//   1. 复位默认值：CLKDIV=3（12.5 MHz）、SPICMD/SPIADR/SPILEN/SPIDUM=0
//   2. 每个可写寄存器写后读回一致
//   3. REG_SPILEN = 0x00201808 读回**恰好等于写入值**（三个字段都是 6/6/16 bit
//      且低两位为空，所以对齐后原样回读）
//   4. REG_SPILEN 的**预期异常**：cmd_len / addr_len 在 RTL 里是 6 bit，写 0xFF
//      会被截断成 0x3F —— 这不是 bug，是位宽决定的行为，连同 data_len 一起
//      写进 spec
//   5. 读一个寄存器不会动到别的寄存器
//
// 注意：这里**不**读 RXFIFO。空 FIFO 上发读访问会让 PREADY 一直不响应（RTL 的
// 行为，spec 里有记录），在本用例里只会变成一次看门狗超时，测不到别的东西。
//
// 运行：make regs
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tc_reg_rw;

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

    reg [31:0] got;

    initial begin
        $display("==== tc_reg_rw: APB register map write / read-back ====");
        reset_dut;

        // ---------------------------------------------------------------
        // 1. 复位默认值
        // ---------------------------------------------------------------
        apb_expect_read(`A_CLKDIV, 32'h0000_0003, "reset CLKDIV = 3 (12.5 MHz)");
        apb_expect_read(`A_SPICMD, 32'h0000_0000, "reset SPICMD = 0");
        apb_expect_read(`A_SPIADR, 32'h0000_0000, "reset SPIADR = 0");
        apb_expect_read(`A_SPILEN, 32'h0000_0000, "reset SPILEN = 0");
        apb_expect_read(`A_SPIDUM, 32'h0000_0000, "reset SPIDUM = 0");

        // ---------------------------------------------------------------
        // 2. 逐寄存器写后读回
        //    CLKDIV 只保留低 8 bit，其余位必须被丢掉。
        // ---------------------------------------------------------------
        apb_write(`A_CLKDIV, 32'hFFFF_FF31);
        apb_expect_read(`A_CLKDIV, 32'h0000_0031, "CLKDIV write/read (upper bits dropped)");

        apb_write(`A_SPICMD, 32'h0B00_0000);
        apb_expect_read(`A_SPICMD, 32'h0B00_0000, "SPICMD write/read (32 bit)");

        apb_write(`A_SPIADR, 32'h0000_2000);
        apb_expect_read(`A_SPIADR, 32'h0000_2000, "SPIADR write/read (32 bit)");

        apb_write(`A_SPIDUM, 32'h000A_0005);
        apb_expect_read(`A_SPIDUM, 32'h000A_0005, "SPIDUM write/read ({dummy_wr, dummy_rd})");

        // ---------------------------------------------------------------
        // 3. SPILEN = {data_len[15:0], 2'b00, addr_len[5:0], 2'b00, cmd_len[5:0]}
        //    0x00201808 -> cmd_len=8, addr_len=24, data_len=32（单位 bit）
        //    三个字段都能装下且低两位本来就是 0，所以读回**恰好**等于写入值。
        //    这是「按位域理解寄存器」能成立的关键一条。
        // ---------------------------------------------------------------
        apb_write(`A_SPILEN, 32'h0020_1808);
        apb_expect_read(`A_SPILEN, 32'h0020_1808, "SPILEN 0x00201808 read-back (cmd8/addr24/data32)");

        // ---------------------------------------------------------------
        // 4. 预期异常：cmd_len / addr_len 是 6 bit
        //    写 0xFF 读回 0x3F。
        // ---------------------------------------------------------------
        apb_write(`A_SPILEN, 32'h0000_00FF);
        apb_expect_read(`A_SPILEN, 32'h0000_003F, "SPILEN cmd_len 0xFF truncates to 0x3F (6 bit)");

        apb_write(`A_SPILEN, 32'h0000_FF00);
        apb_expect_read(`A_SPILEN, 32'h0000_3F00, "SPILEN addr_len 0xFF truncates to 0x3F (6 bit)");

        // ---------------------------------------------------------------
        // 5. 读一个寄存器不影响别的
        //    重新写回一套完整配置，然后**打乱顺序**读回，值必须都对。
        // ---------------------------------------------------------------
        apb_write(`A_CLKDIV, 32'h0000_0000);
        apb_write(`A_SPICMD, 32'h6B00_0000);
        apb_write(`A_SPIADR, 32'h00FF_FF00);
        apb_write(`A_SPILEN, 32'h0020_1808);
        apb_write(`A_SPIDUM, 32'h0000_0008);

        apb_expect_read(`A_SPILEN, 32'h0020_1808, "read SPILEN first, others intact");
        apb_expect_read(`A_SPIADR, 32'h00FF_FF00, "read SPIADR second");
        apb_expect_read(`A_SPICMD, 32'h6B00_0000, "read SPICMD third");
        apb_expect_read(`A_SPIDUM, 32'h0000_0008, "read SPIDUM fourth");
        apb_expect_read(`A_CLKDIV, 32'h0000_0000, "read CLKDIV last");

        // ---------------------------------------------------------------
        // 6. STATUS 是控制器状态打包字，不是寄存器的影子
        //    写 STATUS 只是把 rd/wr/qrd/qwr 交给控制器；读回来的是
        //    apb_flash_top.v 拼出来的 spi_status：
        //        [31:29]=0  [28:24]=elements_tx  [23:21]=0  [20:16]=elements_rx
        //        [15:10]=0  [9:8]=STIG 常量      [7:0]=spi_ctrl_status
        //    此刻两个 FIFO 都空、控制器 IDLE(bit0=1) -> 0x0000_0101。全 32 位比对。
        //
        //    写进去的值是 2'b00，与读回的 [9:8]=2'b01 相反：若 [9:8] 变成可写，
        //    这条断言会读到 0x0000_0001 并失败。[3:0] 写 0，不会误触发事务。
        // ---------------------------------------------------------------
        apb_write(`A_STATUS, 32'h0000_0000);       // PWDATA[9:8]=2'b00 被忽略，且不置触发位
        apb_read(`A_STATUS, got);
        check_eq(got, 32'h0000_0101,
                 "STATUS = {tx=0, rx=0, STIG(read-only), IDLE}");
        check_true(probe_ctrl_idle === 1'b1,           "no trigger bit set -> controller still IDLE");

        // 写 STATUS 不能顺带触发一次 SPI 事务
        check_int(probe_sclk_rises, 0, "no SPI clocks during register-only test");

        report_and_finish("tc_reg_rw");
    end

endmodule
