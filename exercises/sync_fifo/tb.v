`timescale 1ns/1ps
module tb;
reg clk=0, rst_n=0, wr_en=0, rd_en=0;
reg [7:0] din=0;
wire [7:0] dout;
wire full, empty;
wire [2:0] count;
exercise_dut dut(.*);
always #5 clk=~clk;
initial begin $dumpfile(`VCD_FILE); $dumpvars(0,tb); end
task check(input bit ok, input [255:0] name);
begin if (!ok) begin $display("FAIL sync_fifo: %0s",name); $fatal(1); end
      $display("PASS sync_fifo: %0s",name); end endtask
task step(input bit wr, input bit rd, input [7:0] value);
begin @(negedge clk); wr_en=wr; rd_en=rd; din=value;
      @(posedge clk); #1; end endtask
initial begin
    @(posedge clk); #1;
    check(empty === 1 && full === 0 && count === 0 && dout === 0,"reset"); rst_n=1;
    step(1,0,8'h11); check(count === 1 && empty === 0,"push 11");
    step(1,0,8'h22); check(count === 2,"push 22");
    step(1,0,8'h33); check(count === 3,"push 33");
    step(1,0,8'h44); check(count === 4 && full === 1,"full at four entries");
    step(1,0,8'h99); check(count === 4 && full === 1,"overflow ignored");
    step(1,1,8'h55); check(count === 4 && full === 1 && dout === 8'h11,"full exchange reads oldest");
    step(0,1,0); check(count === 3 && dout === 8'h22,"pop 22");
    step(0,1,0); check(count === 2 && dout === 8'h33,"pop 33");
    step(0,1,0); check(count === 1 && dout === 8'h44,"pop 44");
    step(0,1,0); check(count === 0 && empty === 1 && dout === 8'h55,"pop exchanged 55");
    step(0,1,0); check(count === 0 && dout === 8'h55,"underflow ignored");
    step(1,1,8'h66); check(count === 1 && dout === 8'h55,"empty simultaneous only writes");
    step(0,1,0); check(count === 0 && dout === 8'h66,"read after empty simultaneous");
    step(1,0,8'h77); check(count === 1,"push 77");
    step(1,1,8'h88); check(count === 1 && dout === 8'h77,"ordinary simultaneous exchange");
    step(0,1,0); check(count === 0 && dout === 8'h88,"read exchanged 88");
    $display("RESULT: PASS sync_fifo"); $finish;
end
initial begin #2000; $display("FAIL sync_fifo: timeout"); $fatal(1); end
endmodule
