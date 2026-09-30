// -----------------------------------------------------------------------------
// dtb.f - 仿真平台文件列表
//
// dut_harness + flash_model，所有 tc_* 共用。
// 与 rtl.f 一样，本文件不嵌套；Makefile 会把 rtl.f + dtb.f + tc_<case>.f 的内容
// cat 成一个 sim/<case>.f 再交给 iverilog。
// -----------------------------------------------------------------------------
+incdir+testbench/flash_model

testbench/flash_model/flash_model.v
testbench/dut_harness.v
