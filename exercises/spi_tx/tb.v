`timescale 1ns/1ps
module tb;
reg clk=0, rst_n=0, start=0, fall_pulse=0;
reg [7:0] data=0;
wire sdo, busy, done;
exercise_dut dut(.*);
always #5 clk=~clk;
task check(input bit ok, input [255:0] name);
begin if (!ok) begin $display("FAIL spi_tx: %0s",name); $fatal(1); end
      $display("PASS spi_tx: %0s",name); end endtask
task tick_fall;
begin @(negedge clk); fall_pulse=1; @(posedge clk); #1;
      @(negedge clk); fall_pulse=0; end endtask
integer i;
reg [7:0] word=8'hA6;
initial begin
    #1; rst_n=1; #1; rst_n=0;
    #1; check(busy === 0 && done === 0,"reset idle"); rst_n=1;
    @(negedge clk); data=word; start=1;
    @(posedge clk); #1; check(busy === 1 && sdo === word[7],"start exposes MSB");
    @(negedge clk); start=0;
    for (i=0;i<8;i=i+1) begin
        #1; check(sdo === word[7-i],"bit order before fall");
        tick_fall();
        if (i<7) check(done === 0 && busy === 1,"intermediate bit");
    end
    #1; check(done === 1 && busy === 0,"eighth bit completes");
    @(posedge clk); #1; check(done === 0 && busy === 0,"done is one cycle");
    $display("RESULT: PASS spi_tx"); $finish;
end
initial begin #2000; $display("FAIL spi_tx: timeout"); $fatal(1); end
endmodule
