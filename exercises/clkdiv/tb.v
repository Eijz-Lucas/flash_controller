`timescale 1ns/1ps
module tb;
reg clk=0, rst_n=0, en=0;
reg [7:0] div=1;
wire sclk, rise_pulse, fall_pulse;
exercise_dut dut(.*);
initial begin $dumpfile(`VCD_FILE); $dumpvars(0,tb); end
always #5 clk=~clk;
task check(input bit ok, input [255:0] name);
begin if (!ok) begin $display("FAIL clkdiv: %0s",name); $fatal(1); end
      $display("PASS clkdiv: %0s",name); end endtask
initial begin
    #1; rst_n=1; #1; rst_n=0;
    #1; check(sclk === 0 && rise_pulse === 0 && fall_pulse === 0,"reset idle");
    rst_n=1;
    @(negedge clk); en=1;
    @(posedge clk); #1; check(sclk === 0 && rise_pulse === 0,"half period first tick");
    @(posedge clk); #1; check(sclk === 1 && rise_pulse === 1 && fall_pulse === 0,"rising tick");
    @(posedge clk); #1; check(sclk === 1 && rise_pulse === 0,"high hold");
    @(posedge clk); #1; check(sclk === 0 && fall_pulse === 1 && rise_pulse === 0,"falling tick");
    @(negedge clk); en=0;
    @(posedge clk); #1; check(sclk === 0 && rise_pulse === 0 && fall_pulse === 0,"disable clears phase");
    @(negedge clk); div=0; en=1;
    @(posedge clk); #1; check(sclk === 1 && rise_pulse === 1,"div zero toggles every clk");
    @(posedge clk); #1; check(sclk === 0 && fall_pulse === 1,"div zero falling");
    $display("RESULT: PASS clkdiv"); $finish;
end
initial begin #2000; $display("FAIL clkdiv: timeout"); $fatal(1); end
endmodule
