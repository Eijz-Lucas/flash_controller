`timescale 1ns/1ps
`include "define.v"
module apb_flash_top
#(
    parameter BUFFER_DEPTH   = 16,
    parameter APB_ADDR_WIDTH = 32 
)
(
    input  wire                        HCLK ,
    input  wire                        HRESETn,
    input  wire [APB_ADDR_WIDTH - 1:0] PADDR,
    input  wire [31:0]                 PWDATA,
    input  wire                        PWRITE,
    input  wire                        PSEL,
    input  wire                        PENABLE,
    output wire [31:0]                 PRDATA,
    output wire                        PREADY,
    output wire                        PSLVERR,

    output wire                        spi_clk,
    output wire                        spi_csn0,

    // SPI 数据线：一根四位的双向总线，三态只在这一层做。
    // 控制器内部仍然是分开的 sdo/sdi/oe（见下面 spi_sdo*/spi_sdi*/spi_oe* 的声明）。
    inout  wire [3:0]                  spi_dq
);

    localparam LOG_BUFFER_DEPTH = $clog2(BUFFER_DEPTH);
    wire [7:0]                  spi_clk_div;
    wire                        spi_clk_div_valid;
    wire [31:0]                 spi_status;
    wire [31:0]                 spi_addr;
    wire [5:0]                  spi_addr_len;
    wire [31:0]                 spi_cmd;
    wire [5:0]                  spi_cmd_len;
    wire [15:0]                 spi_data_len;
    wire [15:0]                 spi_dummy_rd;
    wire [15:0]                 spi_dummy_wr;
    wire                        spi_rd;
    wire                        spi_wr;
    wire                        spi_qrd;
    wire                        spi_qwr;

    wire [31:0]                 spi_data_tx;
    wire                        spi_data_tx_valid;
    wire [31:0]                 spi_data_rx;
    wire                        spi_data_rx_valid;
    wire                        spi_data_rx_ready;
    wire [7:0]                  spi_ctrl_status;
    wire [31:0]                 spi_ctrl_data_tx;
    wire                        spi_ctrl_data_tx_valid;
    wire                        spi_ctrl_data_tx_ready;
    wire [31:0]                 spi_ctrl_data_rx;
    wire                        spi_ctrl_data_rx_valid;
    wire                        spi_ctrl_data_rx_ready;
    wire [1:0]                  spi_mode;
    wire [LOG_BUFFER_DEPTH:0]   elements_tx;
    wire [LOG_BUFFER_DEPTH:0]   elements_rx;

    localparam FILL_BITS = 7 - LOG_BUFFER_DEPTH;
    // STATUS 是个打包字，不是寄存器影子：
    //   [31:29]=0  [28:24]=elements_tx  [23:21]=0  [20:16]=elements_rx
    //   [15:10]=0  [9:8]=STIG 恒 2'b01  [7:0]=spi_ctrl_status
    // [9:8] 恒读 `STIG_MODE，只读。位号保留不重新分配，寄存器映射和复位值
    // 0x0000_0101 都不变。
    assign spi_status = {{FILL_BITS {1'b0}}, elements_tx, {FILL_BITS {1'b0}}, elements_rx, 6'b0, `STIG_MODE, spi_ctrl_status};


    // ------------------------------------------------------------------
    // SPI pad 的三态
    //
    // 控制器内部一路到底都是分开的 sdo / sdi / oe，双向只在顶层这一个地方合成：
    //     spi_dq[n] = spi_oe[n] ? spi_sdo[n] : 1'bz;
    //     spi_sdi[n] = spi_dq[n];
    // 于是：
    //   - oe=1 时控制器驱动该位，Flash 必须高阻（它在上升沿采样）；
    //   - oe=0 时该位高阻，由 Flash 驱动，控制器从同一根线上读回来。
    //
    // 方向由 spi_mode 决定（见下面的真值表）：
    //   SPI_STD     4'b0001  只有 DQ0 是输出
    //   SPI_QUAD_TX 4'b1111  四根全输出
    //   SPI_QUAD_RX 4'b0000  四根全高阻
    //
    // 两个必须知道的细节（spec 里也写了）：
    //   1. 单线读（SPI_STD）时 oe0=1，控制器在**数据相也一直驱动 DQ0**。Flash 单线
    //      读只在 DQ1 上回数据、根本不看 DQ0，所以不会冲突 —— 但 Flash 模型必须
    //      守这个约定（本工程的模型只在数据相驱动 DQ1）。这是 RTL 的实际行为，
    //      不是「未用方向一律高阻」。
    //   2. spi_mode 是寄存过的，方向翻转比 FSM 状态晚一个 HCLK。这个窗口落在 dummy
    //      相里，对功能无害，但 Flash 模型不得据此报总线冲突。
    // ------------------------------------------------------------------
    wire       spi_sdo0, spi_sdo1, spi_sdo2, spi_sdo3;
    wire       spi_sdi0, spi_sdi1, spi_sdi2, spi_sdi3;
    reg        spi_oe0,  spi_oe1,  spi_oe2,  spi_oe3;

    assign spi_dq[0] = spi_oe0 ? spi_sdo0 : 1'bz;
    assign spi_dq[1] = spi_oe1 ? spi_sdo1 : 1'bz;
    assign spi_dq[2] = spi_oe2 ? spi_sdo2 : 1'bz;
    assign spi_dq[3] = spi_oe3 ? spi_sdo3 : 1'bz;

    assign spi_sdi0 = spi_dq[0];
    assign spi_sdi1 = spi_dq[1];
    assign spi_sdi2 = spi_dq[2];
    assign spi_sdi3 = spi_dq[3];

    // 方向控制。与 flash_controller 的 FSM 一样，块内只对临时变量赋值，最后一次性
    // 落到输出上：直接对 spi_oe0..3 做「先给默认值、再按分支改写」的阻塞赋值时，
    // iverilog 会把块首的默认值也传播出去，于是每次 spi_mode 变化都会在 pad 上产生
    // 一段 oe=0000 的零宽窗口，把命令的第一位驱动成高阻（读回的命令首字节带 Z）。
    reg [3:0] spi_oe_t;
    always @(*) begin
        spi_oe_t = 4'b0000;
        case (spi_mode)
            `SPI_STD:     spi_oe_t = 4'b0001;
            `SPI_QUAD_TX: spi_oe_t = 4'b1111;
            `SPI_QUAD_RX: spi_oe_t = 4'b0000;
            default:      spi_oe_t = 4'b0000;
        endcase
        {spi_oe3, spi_oe2, spi_oe1, spi_oe0} = spi_oe_t;
    end


    flash_ctrl_apb_if
    #(
        .BUFFER_DEPTH   ( BUFFER_DEPTH   ),
        .APB_ADDR_WIDTH ( APB_ADDR_WIDTH )
    )
    u_apbregs
    (
        .HCLK              ( HCLK              ),
        .HRESETn           ( HRESETn           ),
        .PADDR             ( PADDR             ),
        .PWDATA            ( PWDATA            ),
        .PWRITE            ( PWRITE            ),
        .PSEL              ( PSEL              ),
        .PENABLE           ( PENABLE           ),
        .PRDATA            ( PRDATA            ),
        .PREADY            ( PREADY            ),
        .PSLVERR           ( PSLVERR           ),

        .spi_clk_div       ( spi_clk_div       ),
        .spi_clk_div_valid ( spi_clk_div_valid ),
        .spi_status        ( spi_status        ),
        .spi_addr          ( spi_addr          ),
        .spi_addr_len      ( spi_addr_len      ),
        .spi_cmd           ( spi_cmd           ),
        .spi_cmd_len       ( spi_cmd_len       ),
        .spi_data_len      ( spi_data_len      ),
        .spi_dummy_rd      ( spi_dummy_rd      ),
        .spi_dummy_wr      ( spi_dummy_wr      ),
        .spi_rd            ( spi_rd            ),
        .spi_wr            ( spi_wr            ),
        .spi_qrd           ( spi_qrd           ),
        .spi_qwr           ( spi_qwr           ),
        .spi_data_tx       ( spi_data_tx       ),
        .spi_data_tx_valid ( spi_data_tx_valid ),
        .spi_data_rx       ( spi_data_rx       ),
        .spi_data_rx_valid ( spi_data_rx_valid ),
        .spi_data_rx_ready ( spi_data_rx_ready )
    );


    flash_ctrl_fifo
    #(
        .DATA_WIDTH   ( 32           ),
        .BUFFER_DEPTH ( BUFFER_DEPTH )
    )
    u_txfifo
    (
        .clk        ( HCLK                   ),
        .rst_n      ( HRESETn                ),

        .elements_o ( elements_tx            ),

        .data_o     ( spi_ctrl_data_tx       ),
        .valid_o    ( spi_ctrl_data_tx_valid ),
        .ready_i    ( spi_ctrl_data_tx_ready ),

        // ready_o（非满）没有消费者，不接。注意 push 因此是无条件的：
        // FIFO 满时这次推入会丢，见 flash_ctrl_apb_if.v 末尾的说明。
        .valid_i    ( spi_data_tx_valid      ),
        .data_i     ( spi_data_tx            )
    );


    flash_ctrl_fifo
    #(
        .DATA_WIDTH   ( 32           ),
        .BUFFER_DEPTH ( BUFFER_DEPTH )
    )
    u_rxfifo
    (
        .clk        ( HCLK                   ),
        .rst_n      ( HRESETn                ),

        .elements_o ( elements_rx            ),

        .data_o     ( spi_data_rx            ),
        .valid_o    ( spi_data_rx_valid      ),
        .ready_i    ( spi_data_rx_ready      ),

        .valid_i    ( spi_ctrl_data_rx_valid ),
        .data_i     ( spi_ctrl_data_rx       ),
        .ready_o    ( spi_ctrl_data_rx_ready )
    );

    flash_controller u_spictrl
    (
        .clk                    ( HCLK                   ),
        .rst_n                  ( HRESETn                ),
        .spi_clk_div            ( spi_clk_div            ),
        .spi_clk_div_valid      ( spi_clk_div_valid      ),
        .spi_status             ( spi_ctrl_status        ),
        .spi_addr               ( spi_addr               ),
        .spi_addr_len           ( spi_addr_len           ),
        .spi_cmd                ( spi_cmd                ),
        .spi_cmd_len            ( spi_cmd_len            ),
        .spi_data_len           ( spi_data_len           ),
        .spi_dummy_rd           ( spi_dummy_rd           ),
        .spi_dummy_wr           ( spi_dummy_wr           ),
        .spi_rd                 ( spi_rd                 ),
        .spi_wr                 ( spi_wr                 ),
        .spi_qrd                ( spi_qrd                ),
        .spi_qwr                ( spi_qwr                ),

        .spi_ctrl_data_tx       ( spi_ctrl_data_tx       ),
        .spi_ctrl_data_tx_valid ( spi_ctrl_data_tx_valid ),
        .spi_ctrl_data_tx_ready ( spi_ctrl_data_tx_ready ),
        .spi_ctrl_data_rx       ( spi_ctrl_data_rx       ),
        .spi_ctrl_data_rx_valid ( spi_ctrl_data_rx_valid ),
        .spi_ctrl_data_rx_ready ( spi_ctrl_data_rx_ready ),
        .spi_clk                ( spi_clk                ),
        .spi_csn0               ( spi_csn0               ),
        .spi_mode               ( spi_mode               ),
        .spi_sdo0               ( spi_sdo0               ),
        .spi_sdo1               ( spi_sdo1               ),
        .spi_sdo2               ( spi_sdo2               ),
        .spi_sdo3               ( spi_sdo3               ),
        .spi_sdi0               ( spi_sdi0               ),
        .spi_sdi1               ( spi_sdi1               ),
        .spi_sdi2               ( spi_sdi2               ),
        .spi_sdi3               ( spi_sdi3               )
    );

endmodule
