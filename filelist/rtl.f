// -----------------------------------------------------------------------------
// rtl.f - 共享 RTL 文件列表
//
// iverilog 的 -c 命令文件：每行一个文件，不支持嵌套。
// 各测试的 filelist 会把本文件的内容 cat 进来，而不是 -c 本文件。
// -----------------------------------------------------------------------------
+incdir+rtl/flash_ccontroller

rtl/flash_ccontroller/define.v
rtl/flash_ccontroller/apb_flash_top.v
rtl/flash_ccontroller/flash_controller.v
rtl/flash_ccontroller/flash_ctrl_apb_if.v
rtl/flash_ccontroller/flash_ctrl_clkgen.v
rtl/flash_ccontroller/flash_ctrl_tx.v
rtl/flash_ccontroller/flash_ctrl_rx.v
rtl/flash_ccontroller/flash_ctrl_fifo.v
rtl/IP/syn_fifo.v
rtl/IP/dpram_wrap.v
