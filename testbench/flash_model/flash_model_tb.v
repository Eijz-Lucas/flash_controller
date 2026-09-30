// -----------------------------------------------------------------------------
// flash_model_tb.v
//
// Flash 模型的独立冒烟测试：手搓 cs_n / sclk / dq，**完全不经过 APB 和 RTL**。
//
// 它的作用是把模型的位序、dummy 时钟数和存储表冻结下来。它先跑通，之后任何
// tc_* 的失败就只可能出在 RTL / pad / 测试平台，不可能在模型。
//
// 与 RTL 的约定（详见 flash_model.v 头部注释）：
//   - 模式 0：TB 在 sclk 低电平期间改变 MOSI，模型在上升沿采样；
//     模型在下降沿更新 MISO，TB 在下一个上升沿采样。
//   - 单线：MOSI 走 dq[0]，MISO 走 dq[1]（对应 RTL 的 sdo0 / sdi1）。
//   - 四线：命令/地址/数据全部走 dq[3:0]，dq[0] 是 nibble 最低位。
//
// 运行：make smoke
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module flash_model_tb;

    `include "flash_mem_init.vh"

    localparam HALF = 5;          // sclk 半周期 5ns -> 10ns 周期 = 100 MHz

    reg         cs_n      = 1'b1;
    reg         sclk      = 1'b0;
    reg         quad_en   = 1'b0;
    reg  [3:0]  dq_drv    = 4'bzzzz;
    wire [3:0]  dq;
    wire [31:0] last_seq;
    wire        bus_conflict;

    assign dq = dq_drv;

    flash_model u_flash (
        .cs_n        ( cs_n        ),
        .sclk        ( sclk        ),
        .dq          ( dq          ),
        .quad_en     ( quad_en     ),
        .last_seq    ( last_seq    ),
        .bus_conflict( bus_conflict)
    );

    integer errors   = 0;
    integer sclk_cnt = 0;         // 本次事务的 sclk 上升沿数（在 BFM 里显式计数，单一驱动）

//------------------------------------------------------------------
// 检查
//------------------------------------------------------------------
    // 标签端口留 64 字节，避免长字符串被 Verilog 从左截断。
    // 标签一律用 ASCII：日志便于 grep，也不受终端编码影响。
    task check_eq;
        input [31:0]      got;
        input [31:0]      exp;
        input [8*64-1:0]  label;
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL  %0s: got 0x%08x, expected 0x%08x", label, got, exp);
            end
            else
                $display("PASS  %0s: 0x%08x", label, got);
        end
    endtask

    task check_int;
        input integer     got;
        input integer     exp;
        input [8*64-1:0]  label;
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL  %0s: got %0d, expected %0d", label, got, exp);
            end
            else
                $display("PASS  %0s: %0d", label, got);
        end
    endtask

    // 地址 a 起 4 字节的期望值。字节 0 最先被接收到，落在 [31:24]。
    function [31:0] exp_word;
        input [23:0] a;
        begin
            exp_word = { flash_mem_pattern(a),
                         flash_mem_pattern(a + 24'd1),
                         flash_mem_pattern(a + 24'd2),
                         flash_mem_pattern(a + 24'd3) };
        end
    endfunction

//------------------------------------------------------------------
// 位级 BFM
//   drive=1 时 TB 驱动总线；drive=0 时释放，交给 Flash 模型
//------------------------------------------------------------------
    task tick_single;
        input        mosi;
        input        drive;
        output       miso;
        begin
            dq_drv = drive ? {3'bzzz, mosi} : 4'bzzzz;
            #(HALF);
            sclk = 1'b1;
            #1 miso = dq[1];        // 模型已在上一个下降沿放好该位
            #(HALF - 1);
            sclk = 1'b0;            // 模型在此下降沿放好下一位
            sclk_cnt = sclk_cnt + 1;
        end
    endtask

    task tick_quad;
        input  [3:0] nib;
        input        drive;
        output [3:0] rx;
        begin
            dq_drv = drive ? nib : 4'bzzzz;
            #(HALF);
            sclk = 1'b1;
            #1 rx = dq;
            #(HALF - 1);
            sclk = 1'b0;
            sclk_cnt = sclk_cnt + 1;
        end
    endtask

//------------------------------------------------------------------
// 事务级 BFM
//------------------------------------------------------------------
    // 单线读：opcode(8 bit) [+ addr(24 bit)] + dummy 个空时钟 + rbits 位数据
    task single_xfer;
        input  [7:0]   op;
        input          use_addr;
        input  [23:0]  a;
        input  integer dummy;
        input  integer rbits;
        output [31:0]  data;
        integer i;
        reg     b;
        reg [31:0] acc;
        begin
            quad_en  = 1'b0;
            sclk_cnt = 0;
            cs_n     = 1'b0;
            #(HALF);

            for (i = 7; i >= 0; i = i - 1) tick_single(op[i], 1'b1, b);
            if (use_addr)
                for (i = 23; i >= 0; i = i - 1) tick_single(a[i], 1'b1, b);
            for (i = 0; i < dummy; i = i + 1) tick_single(1'b0, 1'b0, b);

            acc = 32'h0;
            for (i = 0; i < rbits; i = i + 1) begin
                tick_single(1'b0, 1'b0, b);
                acc = {acc[30:0], b};
            end
            data = acc;

            #(HALF);
            cs_n = 1'b1;
            #(HALF);
        end
    endtask

    // 四线读：2 个 nibble 命令 + 6 个 nibble 地址 + dummy 个空时钟 + rbits/4 个 nibble 数据
    task quad_xfer;
        input  [7:0]   op;
        input  [23:0]  a;
        input  integer dummy;
        input  integer rbits;
        output [31:0]  data;
        integer i;
        reg [3:0]  n;
        reg [31:0] acc;
        begin
            quad_en  = 1'b1;
            sclk_cnt = 0;
            cs_n     = 1'b0;
            #(HALF);

            tick_quad(op[7:4], 1'b1, n);
            tick_quad(op[3:0], 1'b1, n);
            for (i = 5; i >= 0; i = i - 1) tick_quad(a[i*4 +: 4], 1'b1, n);
            for (i = 0; i < dummy; i = i + 1) tick_quad(4'b0000, 1'b0, n);

            acc = 32'h0;
            for (i = 0; i < rbits/4; i = i + 1) begin
                tick_quad(4'b0000, 1'b0, n);
                acc = {acc[27:0], n};
            end
            data = acc;

            #(HALF);
            cs_n = 1'b1;
            #(HALF);
        end
    endtask

    // 只发命令（WREN 0x06）：8 个时钟，无地址相也无数据相
    task cmd_only_xfer;
        input [7:0] op;
        integer i;
        reg     b;
        begin
            quad_en  = 1'b0;
            sclk_cnt = 0;
            cs_n     = 1'b0;
            #(HALF);
            for (i = 7; i >= 0; i = i - 1) tick_single(op[i], 1'b1, b);
            #(HALF);
            cs_n = 1'b1;
            #(HALF);
        end
    endtask

    // 单线 Page Program：8 bit 命令 + 24 bit 地址 + wbits 位数据。
    // 数据相**全程由 TB 驱动**（模拟控制器的行为），模型此时必须高阻。
    task page_program_xfer;
        input [23:0]  a;
        input [31:0]  w;
        input integer wbits;
        integer i;
        reg     b;
        reg [7:0] op;
        begin
            op       = 8'h02;
            quad_en  = 1'b0;
            sclk_cnt = 0;
            cs_n     = 1'b0;
            #(HALF);
            for (i = 7;  i >= 0;      i = i - 1) tick_single(op[i], 1'b1, b);
            for (i = 23; i >= 0;      i = i - 1) tick_single(a[i],  1'b1, b);
            for (i = wbits - 1; i >= 0; i = i - 1) tick_single(w[i], 1'b1, b);
            #(HALF);
            cs_n = 1'b1;
            #(HALF);
        end
    endtask

//------------------------------------------------------------------
// 主流程
//------------------------------------------------------------------
    reg [31:0] got;

    initial begin
        $display("==== flash_model 冒烟测试 ====");

        // ---- 1. RDID (0x9F)：无地址、无 dummy，固定返回 ID ----
        single_xfer(8'h9F, 1'b0, 24'h000000, 0, 32, got);
        check_eq(got, 32'h2018_2018, "RDID 0x9F");
        check_int(sclk_cnt, 8 + 0 + 0 + 32, "RDID sclk count");

        // ---- 2. Read (0x03)：无 dummy，是 dummy 计数的边界用例 ----
        single_xfer(8'h03, 1'b1, 24'h000000, 0, 32, got);
        check_eq(got, exp_word(24'h000000), "Read 0x03 @0x000000");
        check_int(sclk_cnt, 8 + 24 + 0 + 32, "Read 0x03 sclk count");

        // ---- 3. Fast Read (0x0B)：8 个 dummy ----
        single_xfer(8'h0B, 1'b1, 24'h000020, 8, 32, got);
        check_eq(got, exp_word(24'h000020), "FastRead 0x0B @0x000020");
        check_int(sclk_cnt, 8 + 24 + 8 + 32, "FastRead 0x0B sclk count");
        check_eq(last_seq, {8'h0B, 24'h000020}, "last_seq probe");

        // ---- 4. 同一路径再读一次不同地址，确认无残留状态 ----
        single_xfer(8'h0B, 1'b1, 24'h00FFFC, 8, 32, got);
        check_eq(got, exp_word(24'h00FFFC), "FastRead 0x0B @0x00FFFC");

        // ---- 5. Quad I/O Fast Read (0x6B)：与单线读同一地址，结果必须一致 ----
        quad_xfer(8'h6B, 24'h000020, 8, 32, got);
        check_eq(got, exp_word(24'h000020), "QuadRead 0x6B @0x000020");
        check_int(sclk_cnt, 2 + 6 + 8 + 8, "QuadRead 0x6B sclk count");

        // ---- 6. quad 与单线交叉验证：同一地址两种读法结果必须相同 ----
        single_xfer(8'h0B, 1'b1, 24'h001234, 8, 32, got);
        check_eq(got, exp_word(24'h001234), "single-line @0x001234");
        quad_xfer(8'h6B, 24'h001234, 8, 32, got);
        check_eq(got, exp_word(24'h001234), "quad-line   @0x001234 (must equal previous)");

        // ---- 7. 写通路：WREN 0x06 + Page Program 0x02 + 读回 ----
        // 这一组把模型的写语义冻结下来。它必须独立证明：
        //   a) 不发 WREN 写不进去（WEL 纪律）
        //   b) 发了 WREN 就能写进去，且读回逐位相等（字节序 + 位序都对）
        //   c) 编程结束后 WEL 自动清零，第二笔 PP 又需要重新 WREN
        begin : wr_block
            reg [23:0] wa;
            reg [31:0] ww;
            wa = 24'h000040;
            ww = 32'hA5C3_5A3C;      // 高低半字节交替：位序/字节序错了一眼能看出来

            // 7a. 写之前先确认「原值确实不是目标值」，否则后面的断言不成立
            single_xfer(8'h0B, 1'b1, wa, 8, 32, got);
            check_eq(got, exp_word(wa), "write-target original value");

            // 7b. 负向：跳过 WREN 直接 PP，存储必须纹丝不动
            page_program_xfer(wa, ww, 32);
            check_int(sclk_cnt, 8 + 24 + 32, "PP(no WREN) sclk count");
            check_eq(last_seq, {8'h02, wa}, "PP(no WREN) reached the wire");
            single_xfer(8'h0B, 1'b1, wa, 8, 32, got);
            check_eq(got, exp_word(wa), "PP without WREN must be ignored");

            // 7c. WREN：只有 8 个时钟，走 CMD -> IDLE（不经过 ADDR）
            cmd_only_xfer(8'h06);
            check_int(sclk_cnt, 8, "WREN 0x06 sclk count");
            check_eq(last_seq, {8'h06, 24'h0}, "WREN last_seq");

            // 7d. 真正的 Page Program
            page_program_xfer(wa, ww, 32);
            check_int(sclk_cnt, 8 + 24 + 32, "PP sclk count");
            check_eq(last_seq, {8'h02, wa}, "PP last_seq");

            // 7e. 读回：必须逐位等于写入值
            single_xfer(8'h0B, 1'b1, wa, 8, 32, got);
            check_eq(got, ww, "read back after Page Program");

            // 7f. 邻域没被写坏：地址 wa-4 和 wa+4 仍是 pattern。
            //     四个字节的落点算错时会在这里露出来（少写/多写/偏移一个字节）。
            single_xfer(8'h0B, 1'b1, wa - 24'd4, 8, 32, got);
            check_eq(got, exp_word(wa - 24'd4), "byte before the programmed word");
            single_xfer(8'h0B, 1'b1, wa + 24'd4, 8, 32, got);
            check_eq(got, exp_word(wa + 24'd4), "byte after the programmed word");

            // 7g. WEL 已被编程消耗：再发一笔不带 WREN 的 PP，必须又写不进去
            page_program_xfer(wa, 32'hFFFF_FFFF, 32);
            single_xfer(8'h0B, 1'b1, wa, 8, 32, got);
            check_eq(got, ww, "WEL cleared after Page Program");
        end

        // ---- 8. 全程不得出现总线冲突 ----
        if (bus_conflict !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL  bus conflict detected");
        end
        else
            $display("PASS  no bus conflict");

        // ---- 汇总 ----
        $display("==== flash_model smoke test done ====");
        if (errors != 0) begin
            $display("RESULT: FAIL (%0d mismatches)", errors);
            $fatal;
        end
        $display("RESULT: PASS");
        $finish;
    end

//------------------------------------------------------------------
// 可选波形：make 默认就给每个用例传 -DDUMPFILE（见 makefile 的「波形」一节）
//------------------------------------------------------------------
`ifdef DUMPFILE
    initial begin
        $dumpfile(`DUMPFILE);
        $dumpvars(0, flash_model_tb);
    end
`endif

//------------------------------------------------------------------
// 看门狗
//------------------------------------------------------------------
    initial begin
        #2_000_000;
        $display("FAIL  simulation timeout (2ms)");
        $fatal;
    end

endmodule
