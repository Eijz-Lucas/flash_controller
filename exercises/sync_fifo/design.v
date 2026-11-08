`timescale 1ns/1ps
module exercise_dut (
    input wire clk, rst_n, wr_en, rd_en,
    input wire [7:0] din,
    output reg [7:0] dout,
    output wire full, empty,
    output wire [2:0] count
);
endmodule
