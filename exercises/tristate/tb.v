`timescale 1ns/1ps
module tb;
reg [1:0] mode=0;
reg [3:0] sdo=4'b1010;
reg [3:0] ext_data=4'b0101;
reg [3:0] ext_oe=0;
wire [3:0] sdi, dq;
reg [7:0] doc_point=8'hff;
genvar i;
generate for(i=0;i<4;i=i+1) begin: pad
    assign dq[i] = ext_oe[i] ? ext_data[i] : 1'bz;
end endgenerate
exercise_dut dut(.*);
initial begin $dumpfile(`VCD_FILE); $dumpvars(0,tb); end
task check(input bit ok, input [255:0] name);
begin if (!ok) begin $display("FAIL tristate: %0s",name); $fatal(1); end
      $display("PASS tristate: %0s",name); end endtask
initial begin
    #1; check(dq === 4'bzzzz,"idle high impedance"); doc_point=0; #1;
    mode=2'b01; #1; check(dq === 4'bzzz0,"single output DQ0"); doc_point=1; #1;
    ext_oe=4'b0010; #1; check(sdi === 4'bzz00,"external DQ1 sampled"); doc_point=2; #1;
    ext_oe=0; mode=2'b10; #1; check(dq === 4'b1010 && sdi === 4'b1010,"quad output"); doc_point=3; #1;
    mode=0; ext_oe=4'b1111; #1; check(dq === 4'b0101 && sdi === 4'b0101,"external quad input"); doc_point=4;
    $display("RESULT: PASS tristate"); $finish;
end
initial begin #100; $display("FAIL tristate: timeout"); $fatal(1); end
endmodule
