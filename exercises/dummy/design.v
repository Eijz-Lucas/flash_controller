`timescale 1ns/1ps
module exercise_dut (
    input wire clk, rst_n, start, tick,
    input wire [3:0] cycles,
    output reg [3:0] remaining,
    output reg busy, done
);
endmodule
