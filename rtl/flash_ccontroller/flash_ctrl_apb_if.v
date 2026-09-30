`timescale 1ns/1ps
`include "define.v"
module flash_ctrl_apb_if
#(
    parameter BUFFER_DEPTH   = 16,
    parameter APB_ADDR_WIDTH = 32, 
    parameter LOG_BUFFER_DEPTH = $clog2(BUFFER_DEPTH)
)
(
    input  wire                        HCLK,
    input  wire                        HRESETn,
    input  wire [APB_ADDR_WIDTH - 1:0] PADDR,
    input  wire [31:0]                 PWDATA,
    input  wire                        PWRITE,
    input  wire                        PSEL,
    input  wire                        PENABLE,
    output reg  [31:0]                 PRDATA,
    output wire                        PREADY,
    output wire                        PSLVERR,

    output reg  [7:0]                  spi_clk_div,
    output reg                         spi_clk_div_valid,

    input  wire [31:0]                 spi_status,

    output reg  [31:0]                 spi_addr,
    output reg  [31:0]                 spi_cmd,
    output reg  [5:0]                  spi_addr_len,
    output reg  [5:0]                  spi_cmd_len,
    output reg  [15:0]                 spi_data_len,
    output reg  [15:0]                 spi_dummy_rd,
    output reg  [15:0]                 spi_dummy_wr,

    output reg                         spi_rd      ,          //standard spi read enable
    output reg                         spi_wr      ,            //standard spi wirte  enable
    output reg                         spi_qrd     ,         //quad spi read  enable
    output reg                         spi_qwr     ,         //quad spi wirte enable

    output wire [31:0]                 spi_data_tx,
    output wire                        spi_data_tx_valid,
    input  wire [31:0]                 spi_data_rx,
    input  wire                        spi_data_rx_valid,
    output wire                        spi_data_rx_ready
);
//------------------------------------------------------------------
// signal define
//------------------------------------------------------------------
    wire [3:0] write_address;
    wire [3:0] read_address ;
    wire        wr_ready     ;
    wire        rd_ready     ;

    assign write_address = PADDR[5:2];
    assign read_address  = PADDR[5:2];
    assign PREADY  =    wr_ready || rd_ready;
    assign PSLVERR = 1'b0 ;

//------------------------------------------------------------------
// signals to apb_bus (write transfer)
//------------------------------------------------------------------
    //implement slave model register write mux
    always @(posedge HCLK or negedge HRESETn) begin
        if (HRESETn == 1'b0) begin
            spi_rd            <= 1'b0;
            spi_wr            <= 1'b0;
            spi_qrd           <= 1'b0;
            spi_qwr           <= 1'b0;
            spi_clk_div_valid <= 1'b0;
            spi_clk_div       <= 'd3;
            spi_cmd           <= 'b0;
            spi_addr          <= 'b0;
            spi_cmd_len       <= 'b0;
            spi_addr_len      <= 'b0;
            spi_data_len      <= 'b0;
            spi_dummy_rd      <= 'd0;
            spi_dummy_wr      <= 'b0;
	    end
        else if (PSEL && PENABLE && PWRITE & PREADY ) begin
            case (write_address)
                // PWDATA[9:8] 不写入：STATUS[9:8] 是只读常量。
                `REG_STATUS: begin
                    spi_rd     <= PWDATA[0];
                    spi_wr     <= PWDATA[1];
                    spi_qrd    <= PWDATA[2];
                    spi_qwr    <= PWDATA[3];
                end
                `REG_CLKDIV: begin
                    spi_clk_div       <= PWDATA[7:0];
                    spi_clk_div_valid <= 1'b1;
                end
                `REG_SPICMD: spi_cmd  <= PWDATA;
                `REG_SPIADR: spi_addr <= PWDATA;
                `REG_SPILEN: begin
                    spi_cmd_len        <= PWDATA[7:0];
                    spi_addr_len       <= PWDATA[15:8];
                    spi_data_len[7:0]  <= PWDATA[23:16];
                    spi_data_len[15:8] <= PWDATA[31:24];
                end
                `REG_SPIDUM: begin
                    spi_dummy_rd[7:0]  <= PWDATA[7:0];
                    spi_dummy_rd[15:8] <= PWDATA[15:8];
                    spi_dummy_wr[7:0]  <= PWDATA[23:16];
                    spi_dummy_wr[15:8] <= PWDATA[31:24];
                end
                // 0x24 / 0x28 没有分支：落到 default，写被忽略、读回 0。
            endcase
	    end

        else begin
            spi_rd            <= 1'b0;
            spi_wr            <= 1'b0;
            spi_qrd           <= 1'b0;
            spi_qwr           <= 1'b0;
            spi_clk_div_valid <= 1'b0;
        end
    end 

    //logic for wr_ready 
    assign wr_ready = (PENABLE & PWRITE)?1'b1:1'b0;
//------------------------------------------------------------------
// signals to apb_bus (read transfer)
//------------------------------------------------------------------ 
  // default 必须保留：它是「未映射地址读回 0」与「不推断 latch」两个断言的依靠
  // （tc_apb_proto 会读 0x24 / 0x28 / 0x30 并检查读回 0，而不是 X）。
  always @(*) begin
    case (read_address)
        `REG_STATUS: PRDATA = spi_status;
        `REG_CLKDIV: PRDATA = {24'h0, spi_clk_div};
        `REG_SPICMD: PRDATA = spi_cmd;
        `REG_SPIADR: PRDATA = spi_addr;
        `REG_SPILEN: PRDATA = {spi_data_len, 2'b00, spi_addr_len, 2'b00, spi_cmd_len};
        `REG_SPIDUM: PRDATA = {spi_dummy_wr, spi_dummy_rd};
        `REG_RXFIFO: PRDATA = spi_data_rx;
        default: PRDATA = 'b0;      // 未映射地址（含原 0x24 / 0x28）
    endcase
  end

    //--------------------------------------------------------------
    // APB 应答（PREADY）与 RX FIFO 弹出
    //
    // 这两件事必须解耦：
    //   rd_ready          -> 只决定 PREADY，即「本次读传输何时完成」
    //   spi_data_rx_ready -> 只决定是否弹出 RX FIFO
    //
    // 修复前 spi_data_rx_ready 同时承担两者，且在 setup 相（~PENABLE）就拉高、
    // 在任何读地址的 access 相也拉高，导致：① 主机在 setup 相就把 FIFO 弹空，
    // access 相读到 X；② 读任何寄存器都会消费 RX 数据；③ PREADY 在 PENABLE=0
    // 时即为高，违反 APB 协议且主机从不等 SPI 传输完成。
    //--------------------------------------------------------------
    wire rd_access  = ~PWRITE && PSEL && PENABLE;
    wire rxfifo_sel = (write_address == `REG_RXFIFO);

    assign rd_ready          = rd_access && (rxfifo_sel ? spi_data_rx_valid : 1'b1);
    assign spi_data_rx_ready = rd_ready && rxfifo_sel;


//------------------------------------------------------------------
// signals to  RX/TX FIFO
//------------------------------------------------------------------
    assign spi_data_tx       = PWDATA;
    assign spi_data_tx_valid = ((PSEL & PENABLE) & PWRITE) & (write_address == `REG_TXFIFO);

    // spi_data_rx_ready 的赋值见上方「APB 应答（PREADY）与 RX FIFO 弹出」一节。

    // 注意 spi_data_tx_valid 不看 TX FIFO 满（FIFO 的 ready_o 没有接进来）：满时
    // 这次推入会静默丢失。深度 16，每笔事务只取一个字，软件也可以先读
    // STATUS[28:24]（elements_tx）确认。



endmodule
