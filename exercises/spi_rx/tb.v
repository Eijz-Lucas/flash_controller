`timescale 1ns/1ps
module tb;
reg clk=0, rst_n=0, start=0, rise_pulse=0, sdi=0;
wire [7:0] data;
wire busy, done;
reg [7:0] expected=0;
reg [7:0] word=8'hA6;
integer i;
exercise_dut dut(.*);
always #5 clk=~clk;
initial begin $dumpfile(`VCD_FILE); $dumpvars(0,tb); end
task check(input bit ok, input [255:0] name);
begin if (!ok) begin $display("FAIL spi_rx: %0s",name); $fatal(1); end
      $display("PASS spi_rx: %0s",name); end endtask
initial begin
    @(posedge clk); #1; check(data === 0 && busy === 0 && done === 0,"reset"); rst_n=1;
    @(negedge clk); start=1;
    @(posedge clk); #1; check(busy === 1 && data === 0,"start");
    for (i=7; i>=0; i=i-1) begin
        @(negedge clk); start=0; rise_pulse=1; sdi=word[i];
        @(posedge clk); #1;
        expected={expected[6:0],word[i]};
        check(data === expected,"MSB first shift");
        if (i>0) check(busy === 1 && done === 0,"receiving");
        else check(busy === 0 && done === 1 && data === word,"eighth bit completes");
        @(negedge clk); rise_pulse=0;
        @(posedge clk); #1; check(data === expected && done === 0,"hold between pulses");
    end
    @(negedge clk); rise_pulse=1; sdi=1;
    @(posedge clk); #1; check(data === word && busy === 0,"idle ignores input");
    $display("RESULT: PASS spi_rx"); $finish;
end
initial begin #2000; $display("FAIL spi_rx: timeout"); $fatal(1); end
endmodule
