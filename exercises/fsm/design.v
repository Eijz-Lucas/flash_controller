`timescale 1ns/1ps
module exercise_dut (
    input wire clk, rst_n, start,
    input wire has_addr, has_dummy, do_read,
    input wire cmd_done, addr_done, dummy_done, data_done,
    output wire [2:0] phase,
    output wire cs_n, busy, done
);
endmodule
