`timescale 1ns/1ps
module exercise_dut (
    input wire clk, rst_n, start, rise_pulse, sdi,
    output reg [7:0] data,
    output reg busy, done
);
endmodule
