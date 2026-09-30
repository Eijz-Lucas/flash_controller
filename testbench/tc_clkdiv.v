// -----------------------------------------------------------------------------
// tc_clkdiv.v —— 测试用例 div
//
// 目的：这是**唯一**直接对着讲义数字验收的用例。讲义要求「1 MHz SPI、8 个 dummy、
// 一次读 72 个时钟」，本用例把这几个数字逐个回到 pad 上去量。
//
// 公式（见 flash_ctrl_clkgen.v）
//     f_sclk = f_HCLK / (2 * (clk_div + 1))
//     T_sclk = 2 * (clk_div + 1) * T_HCLK
// 本工程 HCLK = 100 MHz（T = 10 ns），取 clk_div = 49：
//     T_sclk = 2 * 50 * 10 ns = 1000 ns   ->  f_sclk = 1 MHz
//
// 关于时间单位（踩过一次的坑，写下来）
//     iverilog 里 $time 的**数值**是模块时间单位（这里是 ns），而 $display("%0t")
//     打印的是按仿真精度（1 ps）换算过的值，同一个时刻会差 1000 倍。
//     本用例一律用 $time 的数值做算术，量到的就是 ns。
//
// 量的东西
//   1. 数据相内相邻两个上升沿的间隔 = 1000 ns（占空比 50%：高低各 500 ns）
//   2. 任何两个相邻上升沿的间隔都不小于 1000 ns（换字处只会更长，不会更短）
//   3. 分相计数：命令 8、地址 24、dummy 8、数据 32，合计 72
//
// 运行：make div
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tc_clkdiv;

    `include "flash_mem_init.vh"

    localparam CLK_DIV  = 8'd49;
    localparam T_SCLK   = 1000;      // ns，2*(49+1)*10ns

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

    // FSM 状态编号（flash_controller.v 的 localparam）
    localparam S_CMD   = 5'd1;
    localparam S_ADDR  = 5'd2;
    localparam S_DUMMY = 5'd3;
    localparam S_DATA  = 5'd5;

    reg [23:0] ADDR = 24'h000020;
    reg [31:0] rd;

    // ---- pad 级测量 ----
    integer    n_cmd, n_addr, n_dummy, n_data;
    integer    n_periods;
    integer    min_period;          // 所有相邻上升沿间隔的最小值
    integer    t_prev_rise, t_rise, t_fall;
    integer    data_period;         // 数据相内量到的第一个周期
    integer    data_high, data_low; // 同一周期内的高低电平宽度
    integer    data_rise_seen;      // 数据相已经过了几个上升沿

    initial begin
        n_cmd = 0; n_addr = 0; n_dummy = 0; n_data = 0;
        n_periods = 0; min_period = 0;
        // t_rise 也要给 -1：监视块先做 t_prev_rise = t_rise 再判断，
        // 若 t_rise 从 0 起步，第一个上升沿就会拿「上升沿的绝对时刻 - 0」当周期
        // （clk_div=49 时正好是 835 ns，看起来像 RTL 少跑了时钟，其实是测量假象）。
        t_prev_rise = -1; t_rise = -1; t_fall = 0;
        data_period = 0; data_high = 0; data_low = 0; data_rise_seen = 0;

        $display("==== tc_clkdiv: clk_div=49 -> 1 MHz SPI ====");
        reset_dut;

        stig_fast_read(CLK_DIV, 32'h0B00_0000, ADDR, 16'd8, rd);

        $display("  info  sclk_rises=%0d  分相 cmd=%0d addr=%0d dummy=%0d data=%0d",
                 probe_sclk_rises, n_cmd, n_addr, n_dummy, n_data);
        $display("  info  data-phase period=%0d ns (high=%0d low=%0d), min period=%0d ns",
                 data_period, data_high, data_low, min_period);

        // ---- 数据本身仍然要正确（分频不影响内容）----
        check_eq (rd, exp_word(ADDR), "RX data at 1 MHz");
        check_eq (probe_last_seq, {8'h0B, ADDR}, "flash saw {opcode, addr}");

        // ---- 讲义契约：8 dummy、共 72 个时钟 ----
        check_int(n_dummy, 8,  "dummy clocks (handout: 8)");
        check_int(probe_sclk_rises, 72, "total SPI clocks (handout: 72)");

        // ---- 分相计数 ----
        check_int(n_cmd,  8,  "command phase clocks");
        check_int(n_addr, 24, "address phase clocks");
        check_int(n_data, 32, "data phase clocks");

        // ---- 时钟周期 ----
        check_int(data_period, T_SCLK, "T_sclk in data phase = 2*(49+1)*10ns");
        check_int(data_high,   T_SCLK / 2, "sclk high time (50% duty)");
        check_int(data_low,    T_SCLK / 2, "sclk low time (50% duty)");
        check_true(min_period >= T_SCLK, "no sclk period shorter than programmed");

        check_true(probe_ctrl_idle === 1'b1,    "controller back to IDLE");
        check_true(probe_bus_conflict === 1'b0, "no pad bus conflict");

        report_and_finish("tc_clkdiv");
    end

    // ------------------------------------------------------------------
    // pad 级监视：分相计数 + 周期测量
    // 只在片选有效期内统计；换字处时钟会停两拍 HCLK，那些间隔会略大于 1000ns，
    // 所以「最小值 >= 1000」是要断言的性质，而周期精确值只看数据相内部。
    // ------------------------------------------------------------------
    always @(posedge probe_sclk) begin
        if (!probe_cs_n) begin
            t_prev_rise = t_rise;
            t_rise      = $time;

            // t_prev_rise < 0 只可能是第一个上升沿（初值 -1），没有周期可算
            if (t_prev_rise >= 0) begin
                n_periods = n_periods + 1;
                if (min_period == 0 || (t_rise - t_prev_rise) < min_period)
                    min_period = t_rise - t_prev_rise;
            end

            case (probe_state)
                S_CMD:   n_cmd   = n_cmd   + 1;
                S_ADDR:  n_addr  = n_addr  + 1;
                S_DUMMY: n_dummy = n_dummy + 1;
                S_DATA: begin
                    n_data = n_data + 1;
                    data_rise_seen = data_rise_seen + 1;
                    // 数据相的第 1、2 个上升沿之间：完整一个周期，且不跨换字边界
                    if (data_rise_seen == 2) begin
                        data_period = t_rise - t_prev_rise;
                        data_low    = t_rise - t_fall;
                        data_high   = t_fall - t_prev_rise;
                    end
                end
                default: ;
            endcase
        end
    end

    always @(negedge probe_sclk)
        if (!probe_cs_n) t_fall = $time;


endmodule
