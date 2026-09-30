`timescale 1ns/1ps
module DPRAM_WRAP (
wclk               ,
rclk               ,
waddr              ,
raddr              ,
din                ,
wen                ,
ren                ,
dout
);
parameter        DLY        = 1                  ;
parameter        ADDR_WIDTH = 4                  ;
parameter        DATA_WIDTH = 32                 ;
parameter        MEM_DEPTH  = 2 ** ADDR_WIDTH    ;

input                                    wclk    ;
input                                    rclk    ;
input            [ADDR_WIDTH - 1:0]      waddr   ;
input            [ADDR_WIDTH - 1:0]      raddr   ;
input            [DATA_WIDTH - 1:0]      din     ;
input                                    wen     ;
input                                    ren     ;
output           [DATA_WIDTH - 1:0]      dout    ;

reg   [DATA_WIDTH - 1:0]   mem   [0:MEM_DEPTH-1] ;
wire             [DATA_WIDTH - 1:0]      dout    ;


always @(posedge wclk) begin
    if(wen == 1'b1) begin
        mem[waddr] <= #DLY din ;
    end
end

// 写成 always @(*) if (ren) dout <= mem[raddr]; 会在 ren=0 时不给 dout 赋值，
// 推断出 latch，且读出的是上一次的残留值。这里用显式组合赋值：ren=0 时输出 0，
// 行为确定且无 latch。
assign dout = ren ? mem[raddr] : {DATA_WIDTH{1'b0}};

endmodule


