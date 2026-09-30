//
`ifndef FLASH_CTRL_DEFINE_V
`define FLASH_CTRL_DEFINE_V

// SPI 线宽模式：每次事务的传输宽度
`define SPI_STD     2'b00
`define SPI_QUAD_TX 2'b01
`define SPI_QUAD_RX 2'b10




`define REG_STATUS 4'b0000 // BASEREG + 0x00
`define REG_CLKDIV 4'b0001 // BASEREG + 0x04
`define REG_SPICMD 4'b0010 // BASEREG + 0x08
`define REG_SPIADR 4'b0011 // BASEREG + 0x0C
`define REG_SPILEN 4'b0100 // BASEREG + 0x10
`define REG_SPIDUM 4'b0101 // BASEREG + 0x14
`define REG_TXFIFO 4'b0110 // BASEREG + 0x18
`define REG_RXFIFO 4'b1000 // BASEREG + 0x20
// 0x24 / 0x28 是保留地址：未映射，读回 0、写被忽略。没有对应的 REG_ 定义。




// WORK MODE
//
// 本控制器只支持 STIG 模式。
//
// 这个宏只有一个用途：apb_flash_top.v 里 STATUS 的 [9:8] 位域恒读这个值。该位域
// 只读，写 PWDATA[9:8] 无效；位号保留是为了不动已经定下来的寄存器映射
// （复位值仍是 0x0000_0101）。
`define  STIG_MODE      2'b01

`endif // FLASH_CTRL_DEFINE_V
