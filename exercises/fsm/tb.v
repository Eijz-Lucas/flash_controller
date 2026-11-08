`timescale 1ns/1ps
module tb;
reg clk=0, rst_n=0, start=0, has_addr=0, has_dummy=0, do_read=0;
reg cmd_done=0, addr_done=0, dummy_done=0, data_done=0;
wire [2:0] phase;
wire cs_n, busy, done;
exercise_dut dut(.*);
always #5 clk=~clk;
task check(input bit ok, input [255:0] name);
begin if (!ok) begin $display("FAIL fsm: %0s",name); $fatal(1); end
      $display("PASS fsm: %0s",name); end endtask
task step;
begin @(posedge clk); #1; end endtask
initial begin
    #2; check(phase === 0 && cs_n === 1 && busy === 0,"reset idle"); rst_n=1;
    @(negedge clk); start=1; has_addr=1; has_dummy=1; do_read=1;
    step(); check(phase === 1 && cs_n === 0 && busy === 1,"command phase");
    @(negedge clk); start=0; has_addr=0; has_dummy=0; do_read=0;
    step(); check(phase === 1,"wait command completion");
    @(negedge clk); cmd_done=1; step(); check(phase === 2,"latched address option");
    @(negedge clk); cmd_done=0; addr_done=1; step(); check(phase === 3,"dummy phase");
    @(negedge clk); addr_done=0; dummy_done=1; step(); check(phase === 5,"read phase");
    @(negedge clk); dummy_done=0; data_done=1; step(); check(phase === 0 && done === 1 && cs_n === 1,"read completes");
    @(negedge clk); data_done=0; step(); check(done === 0,"done pulse clears");
    @(negedge clk); start=1; do_read=0; has_addr=0; has_dummy=0;
    step(); check(phase === 1,"second command");
    @(negedge clk); start=0; cmd_done=1; step(); check(phase === 4,"skip to write data");
    @(negedge clk); cmd_done=0; data_done=1; step(); check(phase === 0 && done === 1,"write completes");
    $display("RESULT: PASS fsm"); $finish;
end
initial begin #2000; $display("FAIL fsm: timeout"); $fatal(1); end
endmodule
