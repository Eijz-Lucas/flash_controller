`timescale 1ns/1ps

module flash_ctrl_fifo
#(
    parameter DATA_WIDTH =  32,
    parameter BUFFER_DEPTH = 16,
    parameter LOG_BUFFER_DEPTH = $clog2(BUFFER_DEPTH)
)
(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      valid_i,
    input  wire [DATA_WIDTH - 1:0]   data_i,
    output wire                      ready_o,
    output wire [LOG_BUFFER_DEPTH:0] elements_o,
    output wire [DATA_WIDTH - 1:0]   data_o,
    input  wire                      ready_i,
    output wire                      valid_o
);


//------------------------------------------------------------------
// signal define
//------------------------------------------------------------------
wire                            empty   ;        // fifo empty
wire                            full    ;        // fifo full
reg     [LOG_BUFFER_DEPTH:0]    elements;        // number of elements in the buffer

//------------------------------------------------------------------
// signal define
//------------------------------------------------------------------
// level 接一个定值：它只喂 SYN_FIFO 的 almost_full 输出，本可以不接，但悬空的
// 输入是 z，iverilog 也会为它报 dangling 警告。声明成 [LOG_BUFFER_DEPTH:0] 是
// 为了让实参宽度和端口一致 —— 写成 32 bit 会被裁成 5 bit 并报位宽警告。
wire [LOG_BUFFER_DEPTH:0] almost_full_level = BUFFER_DEPTH - 1;

SYN_FIFO #(
    .   DLY             (1               )     ,
    .   DATA_WIDTH      (DATA_WIDTH      )     ,
    .   ADDR_WIDTH      (LOG_BUFFER_DEPTH)
)ip_fifo(
    .   clk             (clk             )     ,
    .   rst_n           (rst_n           )     ,
    .   wen             (valid_i&ready_o )     ,
    .   ren             (valid_o&ready_i )     ,
    .   level           (almost_full_level)    ,
    .   din             (data_i          )     ,
    .   dout            (data_o          )     ,
    .   empty           (empty           )     ,
    .   full            (full            )
);

//------------------------------------------------------------------
// elements number update
//------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (rst_n == 1'b0)
            elements <= 0;
        else if ((ready_i && valid_o) && (!valid_i || full))
            elements <= elements - 1;
        else if (((!valid_o || !ready_i) && valid_i) && !full)
            elements <= elements + 1;
    end

// //------------------------------------------------------------------
// // output signal define
// //------------------------------------------------------------------
    assign elements_o = elements;
    // data_o 由 ip_fifo 的 .dout(data_o) 直接驱动，这里不能再 assign。
    assign valid_o = ~empty;   //if not empty the fifo is read enable
    assign ready_o = ~full;             //if not full the fifo is write enable


endmodule
