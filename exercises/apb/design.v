`timescale 1ns/1ps
module exercise_dut (
    input wire clk, rst_n,
    input wire [7:0] paddr,
    input wire [31:0] pwdata,
    input wire psel, penable, pwrite,
    input wire [31:0] status,
    output wire [31:0] prdata,
    output wire pready, pslverr,
    output wire [7:0] clk_div,
    output wire command_pulse
);
endmodule
