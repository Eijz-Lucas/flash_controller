// -----------------------------------------------------------------------------
// tb_common.vh
//
// 所有测试共用的 APB BFM 与检查库。在测试 module 内部 `include。
//
// 依赖测试 module 里存在下列名字（通常就是 dut_harness 的连线）：
//     HCLK PADDR PWDATA PWRITE PSEL PENABLE PRDATA PREADY PSLVERR
//     harness_quad_mode
//
// 故意不写 include guard：本文件是给每个测试 module 各包含一份的。
// -----------------------------------------------------------------------------

    integer error_count = 0;

    // ------------------------------------------------------------------
    // 检查
    // 标签一律用 ASCII：日志便于 grep，也不受终端编码影响。
    // ------------------------------------------------------------------
    task check_eq;
        input [31:0]     got;
        input [31:0]     exp;
        input [8*64-1:0] label;
        begin
            if (got !== exp) begin
                error_count = error_count + 1;
                $display("  FAIL  %0s: got 0x%08x, expected 0x%08x", label, got, exp);
            end
            else
                $display("  PASS  %0s: 0x%08x", label, got);
        end
    endtask

    task check_int;
        input integer    got;
        input integer    exp;
        input [8*64-1:0] label;
        begin
            if (got !== exp) begin
                error_count = error_count + 1;
                $display("  FAIL  %0s: got %0d, expected %0d", label, got, exp);
            end
            else
                $display("  PASS  %0s: %0d", label, got);
        end
    endtask

    task check_true;
        input            cond;
        input [8*64-1:0] label;
        begin
            if (!cond) begin
                error_count = error_count + 1;
                $display("  FAIL  %0s", label);
            end
            else
                $display("  PASS  %0s", label);
        end
    endtask

    task report_and_finish;
        input [8*64-1:0] name;
        begin
            $display("---- %0s: %0d error(s) ----", name, error_count);
            if (error_count != 0) begin
                $display("RESULT: FAIL");
                $fatal;
            end
            $display("RESULT: PASS");
            $finish;
        end
    endtask

    // ------------------------------------------------------------------
    // APB BFM
    //
    // 驱动一律在 HCLK 下降沿，采样一律在上升沿 —— 这样测试不会和被时钟沿触发的
    // DUT 抢同一个 delta。BFM 绝不在自己拉高 PENABLE 的同一拍去采 PRDATA，
    // 那是 APB 测试平台「有时对有时错」的头号来源。
    // ------------------------------------------------------------------
    task apb_idle;
        begin
            PADDR   = 32'h0;
            PWDATA  = 32'h0;
            PWRITE  = 1'b0;
            PSEL    = 1'b0;
            PENABLE = 1'b0;
        end
    endtask

    task apb_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(negedge HCLK);
            PADDR = addr; PWDATA = data; PWRITE = 1'b1; PSEL = 1'b1; PENABLE = 1'b0;
            @(negedge HCLK);                    // setup 相
            PENABLE = 1'b1;                     // access 相
            @(posedge HCLK);
            while (!PREADY) @(posedge HCLK);    // 等应答
            @(negedge HCLK);
            apb_idle;
        end
    endtask

    task apb_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(negedge HCLK);
            PADDR = addr; PWRITE = 1'b0; PSEL = 1'b1; PENABLE = 1'b0;
            @(negedge HCLK);
            PENABLE = 1'b1;
            @(posedge HCLK);
            while (!PREADY) @(posedge HCLK);
            data = PRDATA;                      // 此刻 PRDATA 有效
            @(negedge HCLK);
            apb_idle;
        end
    endtask

    // 有界 APB 读：最多等 max_cycles 个 HCLK，超时就放弃并让 got_ready 保持 0。
    //
    // 给「会不会挂死」这类负向用例用 —— 主机自己必须先能退出，不能跟着 DUT 一起
    // 卡在 while (!PREADY) 里等看门狗来收尸。
    //
    // 当前没有用例调用它，作为通用测试基础设施保留。
    task apb_read_bounded;
        input  [31:0]  addr;
        output [31:0]  data;
        input  integer max_cycles;
        output         got_ready;
        integer guard;
        begin
            data      = 32'h0;
            got_ready = 1'b0;
            guard     = 0;
            @(negedge HCLK);
            PADDR = addr; PWRITE = 1'b0; PSEL = 1'b1; PENABLE = 1'b0;
            @(negedge HCLK);
            PENABLE = 1'b1;
            @(posedge HCLK);
            while (!PREADY && (guard < max_cycles)) begin
                @(posedge HCLK);
                guard = guard + 1;
            end
            if (PREADY) begin
                data      = PRDATA;
                got_ready = 1'b1;
            end
            @(negedge HCLK);
            apb_idle;
        end
    endtask

    task apb_expect_read;
        input [31:0]     addr;
        input [31:0]     exp;
        input [8*64-1:0] label;
        reg   [31:0]     got;
        begin
            apb_read(addr, got);
            check_eq(got, exp, label);
        end
    endtask

    // ------------------------------------------------------------------
    // 复位
    // ------------------------------------------------------------------
    task reset_dut;
        begin
            apb_idle;
            HRESETn = 1'b0;
            repeat (10) @(negedge HCLK);
            HRESETn = 1'b1;
            repeat (5)  @(negedge HCLK);
        end
    endtask

    // ------------------------------------------------------------------
    // 寄存器地址（PADDR[5:2] 译码，低位被忽略）
    // ------------------------------------------------------------------
    `define A_STATUS  32'h00
    `define A_CLKDIV  32'h04
    `define A_SPICMD  32'h08
    `define A_SPIADR  32'h0C
    `define A_SPILEN  32'h10
    `define A_SPIDUM  32'h14
    `define A_TXFIFO  32'h18
    `define A_RXFIFO  32'h20
    // 保留地址：未映射，读回 0、写被忽略。用例拿它们当「保留地址不应答」的回归保护。
    `define A_RSVD24  32'h24
    `define A_RSVD28  32'h28

    // ------------------------------------------------------------------
    // STIG 事务的寄存器编程序列
    //
    // 注意两点，写错了症状都是「仿真跑完但数据全错」：
    //   1. cmd / addr 必须**高位对齐**：cmd_len=8 发的是 spi_cmd[31:24]，
    //      所以 0x0B 要写成 0x0B000000；addr_len=24 发的是 spi_addr[31:8]，
    //      所以地址要左移 8 位。
    //   2. REG_STATUS[3:0] 是单周期脉冲，**触发写必须最后做**。
    // ------------------------------------------------------------------
    // 编程除 STATUS 以外的全部寄存器
    task stig_prog;
        input [7:0]  clkdiv;
        input [31:0] cmd_msb;      // 已左对齐的命令
        input [23:0] addr;
        input [5:0]  cmd_len;      // 单位 bit
        input [5:0]  addr_len;     // 单位 bit
        input [15:0] data_len;     // 单位 bit
        input [15:0] dummy;        // 单位 SPI 时钟周期
        begin
            apb_write(`A_CLKDIV, {24'h0, clkdiv});
            apb_write(`A_SPICMD, cmd_msb);
            apb_write(`A_SPIADR, {addr, 8'h00});
            apb_write(`A_SPILEN, {data_len, 2'b00, addr_len, 2'b00, cmd_len});
            apb_write(`A_SPIDUM, {16'h0, dummy});
        end
    endtask

    // 写 STATUS 触发事务。rd / wr / qrd / qwr 互斥。
    // status = {22'b0, 2'b01, 4'b0, qwr, qrd, wr, rd}
    // [9:8] 是只读常量 2'b01，写进去的值被忽略；这里写同样的 2'b01，让这一行读起来
    // 和寄存器映射一致。
    task stig_go;
        input rd;
        input wr;
        input qrd;
        input qwr;
        begin
            apb_write(`A_STATUS, {22'h0, 2'b01, 4'b0000, qwr, qrd, wr, rd});
        end
    endtask

    // ------------------------------------------------------------------
    // 等控制器**离开** IDLE
    //
    // 这个 helper 不是可有可无的，缺了它写通路会静默跑错。
    //
    // stig_go 只是把 STATUS 写下去，FSM 要再过两三拍才真的离开 IDLE。此时立刻调
    // wait_ctrl_idle，它看到的 idle 还是 1，**while 循环一次都不进就返回了**，
    // 测试于是在事务刚刚开始时就往下跑，后面每一个断言读到的都是上一笔事务的
    // 残留值（last_seq 滞后一笔、sclk_rises 是 0 或旧值）。
    //
    // 读通路侥幸没暴露这个问题：stig_fast_read 紧接着 apb_read(A_RXFIFO) 会阻塞
    // 到有数据为止，那一下正好把 FSM 推过了 IDLE。**写通路没有 RX 数据，
    // 也就没有这个同步点** —— 所以必须显式等。
    //
    // 采样挂 negedge HCLK：最短的一笔事务（WREN，8 个 SPI 时钟）在 clk_div=0 时
    // 也有 16 个 HCLK 那么长，每拍采一次不可能漏掉。
    // ------------------------------------------------------------------
    task wait_ctrl_busy;
        input integer max_cycles;
        integer guard;
        begin
            guard = 0;
            while ((probe_ctrl_idle !== 1'b0) && (guard < max_cycles)) begin
                @(negedge HCLK);
                guard = guard + 1;
            end
            if (probe_ctrl_idle !== 1'b0) begin
                error_count = error_count + 1;
                $display("  FAIL  controller never left IDLE within %0d HCLK cycles (STIG did not start)",
                         max_cycles);
            end
        end
    endtask

    // 一笔事务的完整收尾：先确认它真的起来了，再等它回 IDLE。
    // 两个都等，缺一不可 —— 见 wait_ctrl_busy 的说明。
    task wait_ctrl_xact;
        input integer max_cycles;
        begin
            wait_ctrl_busy(max_cycles);
            wait_ctrl_idle(max_cycles);
        end
    endtask

    // ------------------------------------------------------------------
    // 等控制器回到 IDLE
    //
    // RX FIFO 一有数据，apb_read(A_RXFIFO) 就带着 PREADY 返回了；可这时候 FSM
    // 还没走完 DATA_RX -> WAIT_EDGE -> IDLE。此时：
    //   - 模型的 last_seq 探针还没锁存（它挂在 posedge cs_n 上），读到的是上一次
    //     事务的值或 0；
    //   - probe_ctrl_idle 还是 0，片选还压着。
    // 时钟分频越大，这段尾巴越长（clk_div=49 时 WAIT_EDGE 要等半个 SPI 周期），
    // 所以除了 tc_reg_rw 这种压根不跑事务的用例，**每个用例在断言前都要等这一步**。
    //
    // guard 是必要的：RTL 真卡住时要给出可读的失败，而不是让看门狗先超时。
    // ------------------------------------------------------------------
    task wait_ctrl_idle;
        input integer max_cycles;
        integer guard;
        begin

            guard = 0;
            while ((probe_ctrl_idle !== 1'b1) && (guard < max_cycles)) begin
                @(negedge HCLK);
                guard = guard + 1;
            end
            if (probe_ctrl_idle !== 1'b1) begin
                error_count = error_count + 1;
                $display("  FAIL  controller did not return to IDLE within %0d HCLK cycles",
                         max_cycles);
            end
        end
    endtask

    // 一条完整的单线 Fast Read：编程 + 触发 + 读回 RX FIFO + 等收尾
    task stig_fast_read;
        input  [7:0]  clkdiv;
        input  [31:0] cmd_msb;
        input  [23:0] addr;
        input  [15:0] dummy;
        output [31:0] data;
        begin
            stig_prog(clkdiv, cmd_msb, addr, 6'd8, 6'd24, 16'd32, dummy);
            stig_go(1'b1, 1'b0, 1'b0, 1'b0);
            // 先确认事务真的起来了再去读 FIFO。少了这一句，如果 FIFO 里恰好还有
            // 上一笔的残留，apb_read 会立刻返回，之后的 wait_ctrl_idle 同样会因为
            // 「FSM 还没离开 IDLE」而空转返回 —— 断言读到的全是上一笔的值。
            wait_ctrl_busy(4000);
            apb_read(`A_RXFIFO, data);
            // 等片选释放、FSM 回 IDLE，否则 last_seq / probe_ctrl_idle 都还没定型。
            // 4000 拍 = 40 us，按 clk_div=49（1 MHz）算也够走完一整个 WAIT_EDGE。
            wait_ctrl_idle(4000);
        end
    endtask

    // 一条完整的 Quad I/O Fast Read（0x6B）。
    // 与 stig_fast_read 的唯一区别是触发时置 qrd=1，控制器据此把 en_quad 拉起来：
    // 命令/地址/数据全部走 4 根线，各相的**时钟数**随之变成 bit 数的 1/4。
    //
    // 注意：本 RTL 的四线约定是「命令和地址也走 4 线」，与真实 NOR Flash 的 0x6B
    // （命令/地址仍是单线）不同。模型用 quad_en 输入显式跟随 RTL，所以测试必须
    // 把 harness 的 quad_mode 同步置 1，否则模型会按单线去解析 4 线上的数据。
    task stig_quad_read;
        input  [7:0]  clkdiv;
        input  [31:0] cmd_msb;
        input  [23:0] addr;
        input  [15:0] dummy;
        output [31:0] data;
        begin
            stig_prog(clkdiv, cmd_msb, addr, 6'd8, 6'd24, 16'd32, dummy);
            stig_go(1'b0, 1'b0, 1'b1, 1'b0);
            wait_ctrl_busy(4000);
            apb_read(`A_RXFIFO, data);
            wait_ctrl_idle(4000);
        end
    endtask

    // ------------------------------------------------------------------
    // 写通路
    //
    // 两条纪律，错了症状都是「跑完但什么都没写进去」：
    //   1. **TXFIFO 必须在触发之前预装。** 触发那一拍 FSM 就离开 IDLE 了，
    //      而 REG_TXFIFO 的写是「写只写」的直通口（见 flash_ctrl_apb_if.v 的
    //      spi_data_tx_valid），没有独立的装载时序 —— 数据必须在 STIG 启动前
    //      就躺在 FIFO 里。
    //   2. **写事务绝不能用 apb_read(A_RXFIFO) 收尾。** 写没有 RX 数据，FIFO
    //      永远为空，apb_read 会一直卡在 while(!PREADY) 直到看门狗超时。
    //      收尾一律用 wait_ctrl_idle。
    // ------------------------------------------------------------------

    // WREN（0x06）：只发一个 8 bit 命令，没有地址相也没有数据相。
    // RTL 里走的是 CMD -> IDLE 这条最短路径（flash_controller.v 的 CMD 状态在
    // addr_len==0 && data_len==0 时直接 eot）。产生的 SPI 时钟数是 8。
    task stig_wren;
        input [7:0] clkdiv;
        begin
            stig_prog(clkdiv, 32'h0600_0000, 24'h0, 6'd8, 6'd0, 16'd0, 16'd0);
            stig_go(1'b0, 1'b1, 1'b0, 1'b0);
            // 写通路没有 RX 数据，也就没有 apb_read 那个隐式同步点，
            // 必须自己先等 FSM 起来再等它结束。详见 wait_ctrl_busy。
            wait_ctrl_xact(4000);
        end
    endtask

    // 单线 Page Program（0x02）：8 bit 命令 + 24 bit 地址 + 32 bit 数据。
    // 共 64 个 SPI 时钟；FSM 走 CMD -> ADDR -> DATA_TX -> IDLE（**不经过
    // WAIT_EDGE**，那是读通路才有的收尾状态）。
    //
    // dummy 写死 0：真实器件的 Page Program 不插 dummy 周期，本 RTL 也靠
    // spi_dummy_wr 控制 DUMMY 相，0 即跳过。
    task stig_page_program;
        input [7:0]  clkdiv;
        input [23:0] addr;
        input [31:0] word;
        begin
            apb_write(`A_TXFIFO, word);          // 必须在 stig_go 之前，见上面第 1 条
            stig_prog(clkdiv, 32'h0200_0000, addr, 6'd8, 6'd24, 16'd32, 16'd0);
            stig_go(1'b0, 1'b1, 1'b0, 1'b0);
            wait_ctrl_xact(4000);
        end
    endtask

    // ------------------------------------------------------------------
    // 参考模型：地址 a 起 4 字节的期望值
    // 与 flash_model 用同一个 flash_mem_pattern()，期望值不会漂移。
    // 字节 0 最先被收到，落在 [31:24]。
    // ------------------------------------------------------------------
    function [31:0] exp_word;
        input [23:0] a;
        begin
            exp_word = { flash_mem_pattern(a),
                         flash_mem_pattern(a + 24'd1),
                         flash_mem_pattern(a + 24'd2),
                         flash_mem_pattern(a + 24'd3) };
        end
    endfunction
