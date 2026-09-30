// -----------------------------------------------------------------------------
// flash_model.v
//
// 行为级 SPI NOR Flash 模型，用于 flash_controller 的仿真。
//
// 支持指令
//   0x03  Read               单线，24 bit 地址，无 dummy，数据单线
//   0x0B  Fast Read          单线，24 bit 地址，8 dummy，数据单线
//   0x6B  Quad I/O Fast Read 四线，24 bit 地址，8 dummy，数据四线
//   0x9F  RDID               单线，无地址无 dummy，连续输出 ID 字节
//   0x06  WREN  写使能        单线，无地址无数据（只发 8 bit 命令）
//   0x02  Page Program       单线，24 bit 地址，无 dummy，数据由控制器发来
//
// 写通路（0x06 / 0x02）
//   - 只有发过 0x06 把 WEL 置起来之后，0x02 才会真正写存储；否则整笔丢弃。
//     这就是真实 Flash 上「忘了 WREN 所以写不进去」那个经典坑，模型如实模拟。
//   - 编程完成后 WEL 自动清零（真实器件的行为）。
//   - **存储语义是直接覆盖，不是真实器件的 `mem & data`。**
//     真实 NOR Flash 的编程只能把 1 拉成 0，而且必须先擦除。本工程不实现擦除，
//     若按 AND 语义，读回值会变成 `pattern & W`，「读回 == 写入」这个断言就不成立，
//     因此这里按覆盖实现，换取「写什么读回什么」这个干净的判据。
//     要真实语义的话，需要连 0x20 扇区擦除一起加，属于下一步。
//
//   - 写事务里**控制器是唯一的驱动方**（RTL 在 SPI_STD 下 oe0=1），模型在数据相
//     必须保持高阻、改为在上升沿采样。oe_eff 因此额外被 wr_mode 门控。
//
// 关于四线模式的约定（重要）
//   本 RTL 在 en_quad 有效时把「命令 + 地址 + 数据」全部放到 4 根线上
//   （见 flash_controller.v 中 CMD/ADDR 状态的 s_spi_mode 选择）。这与标准 NOR
//   Flash 的 0x6B（命令/地址仍为单线）不同，因此本模型用 quad_en 输入显式跟随：
//
//       quad_en = 0 -> 命令 8 个时钟、地址 24 个时钟，全部走 dq[0]
//       quad_en = 1 -> 命令 2 个时钟、地址 6 个时钟，全部走 dq[3:0]
//
//   位序（与 RTL 严格对齐，搞反会得到「看着合理但错」的结果）：
//       flash_ctrl_tx.v:119-122  sdo0=[28] sdo1=[29] sdo2=[30] sdo3=[31]
//       flash_ctrl_rx.v:121      {..., sdi3, sdi2, sdi1, sdi0}
//   => dq[0] 承载 nibble 的最低位，dq[3] 最高位。本模型接收时按
//      {dq[3],dq[2],dq[1],dq[0]} 重组，发送时把 nibble 直接放到 dq[3:0]。
//
//   单线模式下 RTL 的接收线是 sdi1（flash_ctrl_rx.v:121）、发送线是 sdo0，因此：
//       - 读事务的数据相模型只在 dq[1] 上驱动（dq[0] 仍被控制器驱动）；
//       - 写事务的数据相模型在 dq[0] 上采样、且不驱动任何一根线。
//
// 存储器
//   默认 64 KiB，地址对 MEM_BYTES 取模。这样既能验证 24 bit 地址通路的宽度，
//   又不必为 16 MiB 数组付出 64 MB 堆 + 1600 万次初始化的仿真代价。
//   需要真实 16 MiB 范围时覆盖参数 MEM_BYTES = 2**24 即可。
//   内容由 flash_mem_init.vh 的 flash_mem_pattern() 确定，测试平台用同一函数算期望值。
//
// 本模型是「保守简化」模型，不模拟：擦除、WIP 状态位、上电延时、
// tSHSL 等交流时序、保护寄存器、连续读模式。详见 doc/spec.md 的「超范围」一节。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module flash_model #(
    parameter MEM_BYTES = 65536
)(
    input  wire        cs_n,
    input  wire        sclk,
    inout  wire [3:0]  dq,
    input  wire        quad_en,       // 1 = 命令/地址/数据均走 4 线（跟随本 RTL 的约定）
    output reg  [31:0] last_seq,      // 诊断探针：最近一次事务的 {opcode, addr[23:0]}
    output wire        bus_conflict   // 1 = 控制器与 Flash 在同一根线上同时驱动
);

    `include "flash_mem_init.vh"

    localparam P_IDLE  = 3'd0;
    localparam P_CMD   = 3'd1;
    localparam P_ADDR  = 3'd2;
    localparam P_DUMMY = 3'd3;
    localparam P_DATA  = 3'd4;
    localparam P_DONE  = 3'd5;        // 命令解析完、本事务不再有后续相（WREN）

    reg [7:0] mem [0:MEM_BYTES-1];

    // ---- 仅在 CS 下降沿初始化 --------------------------------------
    reg        q_en;          // 本次事务是否四线，在 CS 下降沿锁存

    // ---- 由 sclk 双边沿块维护 --------------------------------------
    reg [2:0]  phase;
    reg [4:0]  cnt;           // 当前阶段已接收的 bit（单线）或 nibble（四线）数
    reg [4:0]  dclk;          // dummy 阶段已产生的 sclk 数
    reg [4:0]  dummy_clks;    // 本次事务需要的 dummy sclk 数
    reg [23:0] dbits;         // 数据阶段已输出（读）/已接收（写）的 bit 数
    reg [7:0]  cmd;
    reg [23:0] addr;
    reg        id_mode;       // 当前事务是否为 RDID（数据来自 ID ROM 而非存储器）
    reg [3:0]  dq_out;
    reg [3:0]  dq_oe;

    // ---- 写通路状态 ------------------------------------------------
    reg        wr_mode;       // 本次事务是 0x02：数据相采样而非驱动
    reg        wr_armed;      // wr_mode 且命令解析时 WEL 已置起 -> 才真的写
    reg        wel;           // 写使能锁存，0x06 置 1，编程结束后自动清 0
    reg [5:0]  wr_cnt;        // 写数据相已接收的 bit 数
    reg [31:0] wr_shift;      // 写数据移位寄存器（先收到的在最高位）

//------------------------------------------------------------------
// opcode 解码
//   把「这个 opcode 要几个地址位、几个 dummy、数据相是读还是写」集中成一组
//   纯函数，命令阶段的四个分支（单线/四线）共用，避免两边各写一份 case 而走样。
//------------------------------------------------------------------
    function [5:0] op_addr_bits;
        input [7:0] op;
        begin
            case (op)
                8'h9F, 8'h06: op_addr_bits = 6'd0;    // RDID / WREN：无地址
                default:      op_addr_bits = 6'd24;
            endcase
        end
    endfunction

    function [4:0] op_dummy;
        input [7:0] op;
        begin
            case (op)
                8'h03, 8'h9F, 8'h06, 8'h02: op_dummy = 5'd0;
                default:                    op_dummy = 5'd8;
            endcase
        end
    endfunction

    function op_is_wr;      input [7:0] op; begin op_is_wr   = (op == 8'h02); end endfunction
    function op_is_id;      input [7:0] op; begin op_is_id   = (op == 8'h9F); end endfunction
    function op_is_wren;    input [7:0] op; begin op_is_wren = (op == 8'h06); end endfunction

//------------------------------------------------------------------
// 三态焊盘
//   oe 额外与状态做组合门控：只要不在数据相（或 CS 已拉高、或是写事务），
//   立即释放总线。
//   wr_mode 这一项是写通路的关键：写事务的数据相由控制器驱动 DQ0，模型必须
//   全程高阻，否则两边抢线 -> dq 成 x、bus_conflict 置起。
//------------------------------------------------------------------
    wire [3:0] oe_eff = (cs_n || phase != P_DATA || wr_mode) ? 4'b0000 : dq_oe;

    assign dq[0] = oe_eff[0] ? dq_out[0] : 1'bz;
    assign dq[1] = oe_eff[1] ? dq_out[1] : 1'bz;
    assign dq[2] = oe_eff[2] ? dq_out[2] : 1'bz;
    assign dq[3] = oe_eff[3] ? dq_out[3] : 1'bz;

    // 双方同时驱动且电平相反 -> 线网解析为 x。
    //
    // 判据里「我驱动的是确定值」这一条不能省。只写 `oe_eff[i] && dq[i]===1'bx`
    // 会把两件不同的事混成一件：
    //   - 我在驱动 1、对方在驱动 0  -> 真抢线
    //   - 我自己就在驱动一个 x     -> 压根没有第二个驱动方
    // 后者出现在命令无法解析、地址被移位成 x 的时候：mem[x] 读出 x，模型再把 x
    // 驱动到线上。那不是冲突，是这次读回值本来就没有定义。
    assign bus_conflict = (oe_eff[0] && (dq_out[0] !== 1'bx) && (dq[0] === 1'bx)) |
                          (oe_eff[1] && (dq_out[1] !== 1'bx) && (dq[1] === 1'bx)) |
                          (oe_eff[2] && (dq_out[2] !== 1'bx) && (dq[2] === 1'bx)) |
                          (oe_eff[3] && (dq_out[3] !== 1'bx) && (dq[3] === 1'bx));

//------------------------------------------------------------------
// 数据来源（读通路）
//------------------------------------------------------------------
    // 数据阶段第 off 个字节
    function [7:0] data_byte;
        input [23:0] off;
        reg   [31:0] sum;
        begin
            if (id_mode) begin
                // RDID：厂家 0x20 / 存储类型 0x18 / 容量 0x20 / 0x18，循环
                case (off[1:0])
                    2'd0:    data_byte = 8'h20;
                    2'd1:    data_byte = 8'h18;
                    2'd2:    data_byte = 8'h20;
                    default: data_byte = 8'h18;
                endcase
            end
            else begin
                sum       = {8'b0, addr} + {8'b0, off};   // 25 bit，避免地址末端的回绕
                data_byte = mem[sum % MEM_BYTES];
            end
        end
    endfunction

    // 注意：这里**不能**写成
    //     wire [7:0] cur_byte = data_byte(dbits[23:3]);
    // iverilog 对连续赋值里的函数调用只追踪「实参」依赖，不追踪函数体里读到的
    // id_mode / addr / mem。结果是 dbits[23:3] 不变时 cur_byte 不会重算，事务开头
    // 会一直用上一次的值（表现为「第一个事务的首字节是上一个地址的数据」）。
    // 因此改为在 sclk 下降沿用阻塞赋值当场求值，见下面 byte_val。
    reg [7:0]  byte_val;

    // 命令相里「新组成的」那个字节。非阻塞赋值让 cmd 在比较时还是旧值，
    // 所以解码必须对着 {cmd[6:0], dq[0]} / {cmd[3:0], dq[3:0]} 做，不能对着 cmd 做。
    reg [7:0]  op_new;

    // 写数据的中间量，同样用阻塞赋值当场求值（理由同上）
    reg [31:0] wr_shift_n;
    reg [5:0]  wr_cnt_n;
    reg [31:0] wr_idx;

//------------------------------------------------------------------
// sclk 双边沿
//   模式 0：控制器在上升沿采样、下降沿改变输出。这里与之镜像 ——
//     读事务：模型在下降沿（换数据）驱动总线、控制器的上升沿采样；
//     写事务：控制器在下降沿换数据，模型在上升沿采样。
//------------------------------------------------------------------
    always @(posedge sclk or negedge sclk) begin
        if (!cs_n) begin
            if (sclk) begin
                //================= 上升沿 =================
                case (phase)

                    P_CMD: begin
                        // 先移位（含最后一位），再判断本阶段是否结束。
                        // 非阻塞赋值意味着此刻 cmd 还是旧值，故比较「新组成的」字节。
                        if (q_en) begin
                            cmd <= {cmd[3:0], dq[3:0]};
                            if (cnt == 5'd1) begin
                                cnt <= 5'd0;
                                op_new = {cmd[3:0], dq[3:0]};
                                dummy_clks <= op_dummy(op_new);
                                wr_mode    <= op_is_wr(op_new);
                                id_mode    <= op_is_id(op_new);
                                wr_armed   <= op_is_wr(op_new) & wel;
                                wr_cnt     <= 6'd0;
                                if (op_is_wren(op_new)) begin
                                    // WREN 只发命令：没有地址相也没有数据相
                                    wel   <= 1'b1;
                                    phase <= P_DONE;
                                end
                                else if (op_addr_bits(op_new) == 6'd0) begin
                                    // 无地址、有数据（RDID）
                                    phase <= P_DATA;
                                    dbits <= 24'd0;
                                end
                                else begin
                                    phase <= P_ADDR;
                                end
                            end
                            else cnt <= cnt + 5'd1;
                        end
                        else begin
                            cmd <= {cmd[6:0], dq[0]};
                            if (cnt == 5'd7) begin
                                cnt <= 5'd0;
                                op_new = {cmd[6:0], dq[0]};
                                dummy_clks <= op_dummy(op_new);
                                wr_mode    <= op_is_wr(op_new);
                                id_mode    <= op_is_id(op_new);
                                wr_armed   <= op_is_wr(op_new) & wel;
                                wr_cnt     <= 6'd0;
                                if (op_is_wren(op_new)) begin
                                    wel   <= 1'b1;
                                    phase <= P_DONE;
                                end
                                else if (op_addr_bits(op_new) == 6'd0) begin
                                    phase <= P_DATA;
                                    dbits <= 24'd0;
                                end
                                else begin
                                    phase <= P_ADDR;
                                end
                            end
                            else cnt <= cnt + 5'd1;
                        end
                    end

                    P_ADDR: begin
                        // 同样先移位（含最后一个 nibble/bit），再判断阶段是否结束
                        if (q_en) begin
                            addr <= {addr[19:0], dq[3:0]};
                            if (cnt == 5'd5) begin
                                cnt  <= 5'd0;
                                dclk <= 5'd0;
                                if (dummy_clks == 5'd0) begin
                                    phase <= P_DATA;
                                    dbits <= 24'd0;
                                end
                                else phase <= P_DUMMY;
                            end
                            else cnt <= cnt + 5'd1;
                        end
                        else begin
                            addr <= {addr[22:0], dq[0]};
                            if (cnt == 5'd23) begin
                                cnt  <= 5'd0;
                                dclk <= 5'd0;
                                if (dummy_clks == 5'd0) begin
                                    phase <= P_DATA;
                                    dbits <= 24'd0;
                                end
                                else phase <= P_DUMMY;
                            end
                            else cnt <= cnt + 5'd1;
                        end
                    end

                    P_DUMMY: begin
                        // dclk 记的是「已产生的 dummy 时钟数」，本拍是第 dclk+1 个
                        if (dclk == dummy_clks - 5'd1) begin
                            phase <= P_DATA;
                            dbits <= 24'd0;
                        end
                        dclk <= dclk + 5'd1;
                    end

                    P_DATA: begin
                        // 只有写事务在这一拍动作：控制器在下降沿换数据，模型在上升沿采。
                        // 读事务的数据相由模型在下降沿驱动，上升沿不做事。
                        if (wr_mode) begin
                            wr_cnt_n   = wr_cnt + (q_en ? 6'd4 : 6'd1);
                            wr_shift_n = q_en ? {wr_shift[27:0], dq[3], dq[2], dq[1], dq[0]}
                                              : {wr_shift[30:0], dq[0]};
                            wr_shift <= wr_shift_n;
                            wr_cnt   <= wr_cnt_n;
                            // 每凑满 8 bit 落一个字节。字节 0 落在 addr+0，
                            // 与读通路「字节 0 在 [31:24]」的约定一致，于是
                            // 写进去的字读回来逐位相等。
                            if (wr_armed && (wr_cnt_n[2:0] == 3'd0)) begin
                                wr_idx = ({26'd0, wr_cnt_n} >> 3) - 32'd1;
                                mem[(addr + wr_idx) % MEM_BYTES] <= wr_shift_n[7:0];
                            end
                        end
                    end

                    default: ;   // P_DONE / P_IDLE：无事可做
                endcase
            end
            else begin
                //================= 下降沿 =================
                // 写事务的数据相控制器在驱动，模型全程高阻（oe_eff 已被 wr_mode 门控），
                // 这里连 dq_out/dq_oe 都不必更新。
                if ((phase == P_DATA) && !wr_mode) begin
                    byte_val = data_byte(dbits[23:3]);   // 阻塞赋值：此刻求值

                    if (q_en) begin
                        // 四线：高 nibble 先发，dq[0] 是 nibble 最低位
                        dq_out <= dbits[2] ? byte_val[3:0] : byte_val[7:4];
                        dq_oe  <= 4'b1111;
                        dbits  <= dbits + 24'd4;
                    end
                    else begin
                        // 单线：MSB first，且只在 dq[1]（RTL 的 sdi1）上驱动。
                        // 数据位必须落在 dq_out[1]，与 oe=4'b0010 对齐。
                        // dq[0] 上控制器仍在驱动（SPI_STD -> oe0=1），碰了就冲突。
                        dq_out <= {2'b00, byte_val[3'd7 - dbits[2:0]], 1'b0};
                        dq_oe  <= 4'b0010;
                        dbits  <= dbits + 24'd1;
                    end
                end
            end
        end
    end

//------------------------------------------------------------------
// CS 边沿：事务开始 / 结束
//------------------------------------------------------------------
    always @(negedge cs_n) begin
        phase <= P_CMD;
        cnt   <= 5'd0;
        q_en  <= quad_en;
        // cmd / addr 也要清：否则一个「只发命令」的事务（WREN）结束时会用上一次
        // 事务残留的地址去填 last_seq，探针值不确定。
        cmd      <= 8'h00;
        addr     <= 24'h0;
        wr_mode  <= 1'b0;
        wr_armed <= 1'b0;
        wr_cnt   <= 6'd0;
        wr_shift <= 32'h0;
        // dq_oe / dq_out 也必须清。
        //
        // 它们是「数据相的方向和值」，由数据相的**下降沿**写入。而 phase 是在
        // 上一个上升沿就跳到 P_DATA 的 —— 从进入数据相到第一个下降沿之间隔着
        // 半个 SPI 周期，这半个周期里 oe_eff 用的还是**上一笔事务**留下的 dq_oe。
        //
        // 症状：一笔四线事务（dq_oe=1111）后面紧跟一笔单线事务时，单线事务的
        // 数据相开头会带着 1111 去驱动全部四根线，而控制器此刻是 SPI_STD、
        // 正在驱动 DQ0 —— 抢线。这个组合由 tc_quad_read 的第 4 段守着
        // （四线读 -> 紧跟一笔单线读）。
        //
        // 清 0 之后，数据相在第一个下降沿之前不驱动任何线，方向由下降沿统一建立。
        // 数据本身不受影响：第一个数据位在下降沿就位，控制器的采样上升沿在它之后。
        dq_oe    <= 4'b0000;
        dq_out   <= 4'b0000;
    end

    always @(posedge cs_n) begin
        phase    <= P_IDLE;
        last_seq <= {cmd, addr};
        // 编程结束后 WEL 自动清零（真实器件的行为）。只有真的走了写事务才清，
        // 所以「WREN 之后不编程」时 WEL 会一直保持到下一笔事务。
        if (wr_mode) wel <= 1'b0;
    end

//------------------------------------------------------------------
// 初始化
//------------------------------------------------------------------
    integer i;
    initial begin
`ifdef FLASH_MEM_HEX
        $readmemh(`FLASH_MEM_HEX, mem);
`else
        for (i = 0; i < MEM_BYTES; i = i + 1)
            mem[i] = flash_mem_pattern(i);
`endif
        phase      = P_IDLE;
        cnt        = 5'd0;
        dclk       = 5'd0;
        dummy_clks = 5'd0;
        dbits      = 24'd0;
        cmd        = 8'h00;
        addr       = 24'h0;
        id_mode    = 1'b0;
        q_en       = 1'b0;
        dq_out     = 4'b0000;
        dq_oe      = 4'b0000;
        last_seq   = 32'h0;
        // 写通路
        wr_mode    = 1'b0;
        wr_armed   = 1'b0;
        wel        = 1'b0;
        wr_cnt     = 6'd0;
        wr_shift   = 32'h0;
    end

endmodule
