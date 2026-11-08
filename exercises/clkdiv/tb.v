`timescale 1ns/1ps
module tb;
reg clk=0, rst_n=0, en=0;
reg [7:0] div=1;
wire sclk, rise_pulse, fall_pulse;
reg [7:0] doc_point=8'hff;
exercise_dut dut(.*);
initial begin $dumpfile(`VCD_FILE); $dumpvars(0,tb); end
always #5 clk=~clk;
task check(input bit ok, input [255:0] name);
begin if (!ok) begin $display("FAIL clkdiv: %0s",name); $fatal(1); end
      $display("PASS clkdiv: %0s",name); end endtask
initial begin
    #1; rst_n=1; #1; rst_n=0;
    #1; check(sclk === 0 && rise_pulse === 0 && fall_pulse === 0,"reset idle"); doc_point=0;
    rst_n=1;
    @(negedge clk); en=1;
    @(posedge clk); #1; check(sclk === 0 && rise_pulse === 0,"half period first tick"); doc_point=1;
    @(posedge clk); #1; check(sclk === 1 && rise_pulse === 1 && fall_pulse === 0,"rising tick"); doc_point=2;
    @(posedge clk); #1; check(sclk === 1 && rise_pulse === 0,"high hold"); doc_point=3;
    @(posedge clk); #1; check(sclk === 0 && fall_pulse === 1 && rise_pulse === 0,"falling tick"); doc_point=4;
    @(negedge clk); en=0;
    @(posedge clk); #1; check(sclk === 0 && rise_pulse === 0 && fall_pulse === 0,"disable clears phase"); doc_point=5;
    @(negedge clk); div=0; en=1;
    @(posedge clk); #1; check(sclk === 1 && rise_pulse === 1,"div zero toggles every clk"); doc_point=6;
    @(posedge clk); #1; check(sclk === 0 && fall_pulse === 1,"div zero falling"); doc_point=7;
    $display("RESULT: PASS clkdiv"); $finish;
end
initial begin #2000; $display("FAIL clkdiv: timeout"); $fatal(1); end
endmodule
