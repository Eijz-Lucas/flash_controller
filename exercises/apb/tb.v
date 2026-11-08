`timescale 1ns/1ps
module tb;
reg clk=0, rst_n=0, psel=0, penable=0, pwrite=0;
reg [7:0] paddr=0;
reg [31:0] pwdata=0, status=32'h12345678;
wire [31:0] prdata;
wire pready, pslverr, command_pulse;
wire [7:0] clk_div;
exercise_dut dut(.*);
initial begin $dumpfile(`VCD_FILE); $dumpvars(0,tb); end
always #5 clk=~clk;
task check(input bit ok, input [255:0] name);
begin
    if (!ok) begin $display("FAIL apb: %0s",name); $fatal(1); end
    $display("PASS apb: %0s",name);
end endtask
initial begin
    #1; rst_n=1; #1; rst_n=0;
    #1; check(clk_div === 8'd3 && command_pulse === 1'b0,"reset"); rst_n=1;
    @(negedge clk); psel=1; pwrite=1; paddr=8'h00; pwdata=32'h0000002a;
    #1; check(pready === 1'b0 && clk_div === 8'd3,"setup has no ready or write");
    @(negedge clk); penable=1;
    #1; check(pready === 1'b1 && pslverr === 1'b0,"write access response");
    @(negedge clk); psel=0; penable=0; pwrite=0;
    #1; check(clk_div === 8'h2a,"write only in access");
    @(negedge clk); psel=1; paddr=8'h00;
    #1; check(pready === 1'b0 && prdata === 32'h2a,"read setup");
    @(negedge clk); penable=1;
    #1; check(pready === 1'b1 && prdata === 32'h2a,"readback");
    @(negedge clk); paddr=8'h04;
    #1; check(prdata === status,"read only status");
    @(negedge clk); paddr=8'h0c;
    #1; check(prdata === 32'b0,"unmapped returns zero");
    @(negedge clk); pwrite=1; paddr=8'h08; pwdata=1;
    #1; check(command_pulse === 1'b1,"command pulse on access");
    @(negedge clk); psel=0; penable=0;
    #1; check(command_pulse === 1'b0,"command pulse ends");
    $display("RESULT: PASS apb"); $finish;
end
initial begin #2000; $display("FAIL apb: timeout"); $fatal(1); end
endmodule
