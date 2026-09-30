// -----------------------------------------------------------------------------
// tc_write_read.v —— 测试用例 write
//
// 目的：证明**写通路**是通的，而不只是「仿真没报错」。
//
// 判据只有一条，但是逐位的：把 32 bit 写进去，再用读通路读回来，必须**完全相等**。
// 相等的意义比看上去大 —— 它同时钉死了三件事：
//   - 数据相的字节序（哪个字节先上线）
//   - 单线的位序（MSB first）
//   - 地址相的落点（写进的字节确实落在 addr+0..addr+3）
// 任何一处错位，读回值都会是一个「看着合理但不等」的数。
//
// 为什么是三笔事务
//   真实 NOR Flash 的编程必须先发 WREN(0x06) 把 WEL 置起来，本模型照此实现。
//   于是用例天然变成三段：
//       ① WREN  0x06   8 个 SPI 时钟，FSM 走 CMD -> IDLE（**没有地址相也没有数据相**）
//       ② PP    0x02   64 个 SPI 时钟，FSM 走 CMD -> ADDR -> DATA_TX -> IDLE
//       ③ 读回  0x0B   复用读通路的 helper
//   第 ① 段顺带覆盖了 RTL 里 CMD -> IDLE 这条**此前没有任何用例走过**的最短路径。
//
// 负向检查（本用例真正的价值所在）
//   跳过 WREN 直接发 PP：命令照样发到线上（probe_last_seq 能证明），但存储必须
//   **纹丝不动**。这就是真实器件上「忘了 WREN 所以写不进去、还查不出原因」那个
//   经典坑。如果这段读回来变成了新值，说明模型根本没在管 WEL —— 那么正例的
//   PASS 也就没有任何意义了。
//
// 关于写事务的收尾
//   写没有 RX 数据，**绝不能**用 apb_read(A_RXFIFO) 收尾：FIFO 永远为空，
//   会一直卡在 while(!PREADY) 直到看门狗超时。收尾一律用 wait_ctrl_idle
//   （stig_wren / stig_page_program 内部已经调了）。
//
// 运行：make write
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tc_write_read;

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

    localparam SPI_STD     = 2'b00;
    localparam SPI_QUAD_TX = 2'b01;
    localparam SPI_QUAD_RX = 2'b10;

    // 写入字刻意选成高低半字节交替：字节序或位序错一位，读回值就面目全非，
    // 一眼能看出是「左右反了」还是「前后反了」。
    localparam [31:0] WR_WORD = 32'hA5C3_5A3C;

    reg [23:0] ADDR = 24'h000020;
    reg [31:0] rd;
    reg [31:0] status;
    reg [15:0] ris;

    initial begin
        $display("==== tc_write_read: WREN 0x06 -> Page Program 0x02 -> read back ====");
        $display("  -- addr 0x%06x, write 0x%08x, original 0x%08x --",
                 ADDR, WR_WORD, exp_word(ADDR));

        harness_quad_mode = 1'b0;      // 全程单线：命令/地址/数据都走 DQ0
        reset_dut;

        // ------------------------------------------------------------------
        // 0. 前置：确认写入前存储里**确实不是**目标值。
        //    少了这一步，正例的 PASS 有可能只是「读回了本来就有的东西」。
        // ------------------------------------------------------------------
        stig_fast_read(8'd0, 32'h0B00_0000, ADDR, 16'd8, rd);
        check_eq(rd, exp_word(ADDR), "pre-write value is the reference pattern");

        // ------------------------------------------------------------------
        // 1. 负向：不发 WREN 直接 Page Program
        //    命令必须真的到了线上，但存储必须一点没变。
        // ------------------------------------------------------------------
        stig_page_program(8'd0, ADDR, WR_WORD);
        check_eq (probe_last_seq, {8'h02, ADDR}, "PP w/o WREN: opcode+addr reached the pad");
        check_int(probe_sclk_rises, 8 + 24 + 32,  "PP w/o WREN: 64 SPI clocks");
        // 事务刚跑完，probe_bus_conflict 就是这一笔的结论（按片选窗口粘滞）。
        // 写事务的 pad 方向是本次最容易出错的地方：模型没把 oe 放掉的话，
        // 数据相就是模型和控制器抢 DQ0 —— 这里会立刻抓住，而不是拖到读回
        // 值变成 x 之后再去猜原因。
        check_true(probe_bus_conflict === 1'b0, "PP w/o WREN: no pad bus conflict");

        stig_fast_read(8'd0, 32'h0B00_0000, ADDR, 16'd8, rd);
        check_eq(rd, exp_word(ADDR), "PP without WREN must leave memory untouched");

        // ------------------------------------------------------------------
        // 2. WREN 0x06 —— 只发命令
        //    FSM 走的是 CMD -> IDLE 这条最短路径：没有地址相，也没有数据相。
        //    这是 RTL 里此前没有任何用例覆盖过的一条路，时钟数必须是 8。
        // ------------------------------------------------------------------
        stig_wren(8'd0);
        ris = probe_sclk_rises;
        $display("  info  WREN: clocks=%0d, last_seq=0x%08x", ris, probe_last_seq);
        check_int(ris, 8, "WREN 0x06 drives exactly 8 SPI clocks");
        check_eq (probe_last_seq, {8'h06, 24'h0}, "WREN 0x06 opcode on pad");
        check_true(probe_ctrl_idle === 1'b1, "controller back to IDLE right after WREN");
        check_true(probe_bus_conflict === 1'b0, "WREN: no pad bus conflict");

        // ------------------------------------------------------------------
        // 3. Page Program 0x02
        //    8(命令) + 24(地址) + 32(数据) = 64 个 SPI 时钟。
        //    写通路**不经过 WAIT_EDGE** —— 那是读通路才有的收尾状态。
        // ------------------------------------------------------------------
        stig_page_program(8'd0, ADDR, WR_WORD);
        ris = probe_sclk_rises;
        $display("  info  PP  : clocks=%0d, last_seq=0x%08x", ris, probe_last_seq);
        check_eq (probe_last_seq, {8'h02, ADDR}, "PP opcode+addr on pad");
        check_int(ris, 8 + 24 + 32, "PP drives 64 SPI clocks (no dummy, no WAIT_EDGE)");
        check_true(probe_bus_conflict === 1'b0, "PP: no pad bus conflict (model released DQ0)");

        // ------------------------------------------------------------------
        // 4. 读回 —— 本用例的头条断言
        //    逐位相等 = 字节序、位序、地址落点全部正确。
        // ------------------------------------------------------------------
        stig_fast_read(8'd0, 32'h0B00_0000, ADDR, 16'd8, rd);
        check_true(^rd !== 1'bx, "read-back is fully defined (no X)");
        check_eq (rd, WR_WORD, "read back == written word (byte order + bit order)");

        // ------------------------------------------------------------------
        // 5. 邻域没被写坏
        //    落点偏移一个字节、或者多写/少写了字节，都会在这里露出来。
        //    这一步把「写对了」和「写对了但顺带踩了别人」区分开。
        // ------------------------------------------------------------------
        stig_fast_read(8'd0, 32'h0B00_0000, ADDR - 24'd4, 16'd8, rd);
        check_eq(rd, exp_word(ADDR - 24'd4), "4 bytes before the target untouched");
        stig_fast_read(8'd0, 32'h0B00_0000, ADDR + 24'd4, 16'd8, rd);
        check_eq(rd, exp_word(ADDR + 24'd4), "4 bytes after the target untouched");

        // ------------------------------------------------------------------
        // 6. WEL 已被这一笔编程消耗掉
        //    再发一笔不带 WREN 的 PP（数据故意给全 1），必须又写不进去。
        //    这条与第 1 段互补：第 1 段证明「初始 WEL=0」，这条证明
        //    「编程之后 WEL 会自己清掉」，也就是 WREN 是**每笔一次**的。
        // ------------------------------------------------------------------
        stig_page_program(8'd0, ADDR, 32'hFFFF_FFFF);
        stig_fast_read(8'd0, 32'h0B00_0000, ADDR, 16'd8, rd);
        check_eq(rd, WR_WORD, "WEL was cleared by the previous Page Program");

        // ------------------------------------------------------------------
        // 7. 控制器侧的收尾状态
        // ------------------------------------------------------------------
        apb_read(`A_STATUS, status);
        $display("  info  STATUS = 0x%08x", status);
        check_int(status[28:24], 0, "TX FIFO drained (elements_tx == 0)");
        check_int(status[9:8], 2'b01, "STATUS[9:8] reads STIG (read-only field)");

        // ------------------------------------------------------------------
        // 8. 防呆
        //    probe_bus_conflict 按片选窗口粘滞，上面每一笔事务后都单独查过了；
        //    这里再查一次，覆盖的是最后那笔读回。
        // ------------------------------------------------------------------
        check_true(probe_quad_mismatch === 1'b0, "model quad_en matched DUT en_quad throughout");
        check_true(probe_bus_conflict === 1'b0,  "read-back: no pad bus conflict");
        check_true(probe_ctrl_idle    === 1'b1,  "controller IDLE at end of test");

        report_and_finish("tc_write_read");
    end

endmodule
