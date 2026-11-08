`timescale 1ns/1ps
module tb;
reg clk=0, rst_n=0, start=0, tick=0;
reg [3:0] cycles=0;
wire [3:0] remaining;
wire busy, done;
exercise_dut dut(.*);
always #5 clk=~clk;
initial begin $dumpfile(`VCD_FILE); $dumpvars(0,tb); end
task check(input bit ok, input [511:0] name);
begin if (!ok) begin $display("FAIL dummy: %0s",name); $fatal(1); end
      $display("PASS dummy: %0s",name); end endtask
initial begin
    @(posedge clk); #1; check(remaining === 0 && busy === 0 && done === 0,"reset"); rst_n=1;
    @(negedge clk); start=1; cycles=3;
    @(posedge clk); #1; check(remaining === 3 && busy === 1 && done === 0,"load three");
    @(negedge clk); start=0;
    @(posedge clk); #1; check(remaining === 3,"wait without tick");
    @(negedge clk); tick=1;
    @(posedge clk); #1; check(remaining === 2 && busy === 1,"first tick");
    @(negedge clk); tick=0; start=1; cycles=7;
    @(posedge clk); #1; check(remaining === 2 && busy === 1,"busy start ignored");
    @(negedge clk); tick=1; start=0;
    @(posedge clk); #1; check(remaining === 1 && busy === 1,"second tick");
    @(negedge clk); tick=0;
    @(posedge clk); #1; check(remaining === 1,"hold at one");
    @(negedge clk); tick=1;
    @(posedge clk); #1; check(remaining === 0 && busy === 0 && done === 1,"third tick completes");
    @(negedge clk); tick=0;
    @(posedge clk); #1; check(done === 0,"done clears");
    @(negedge clk); start=1; cycles=0;
    @(posedge clk); #1; check(remaining === 0 && busy === 0 && done === 1,"zero cycles completes immediately");
    @(negedge clk); start=0;
    @(posedge clk); #1; check(done === 0,"zero completion is one cycle");
    $display("RESULT: PASS dummy"); $finish;
end
initial begin #2000; $display("FAIL dummy: timeout"); $fatal(1); end
endmodule
