// -----------------------------------------------------------------------------
// flash_mem_init.vh
//
// Flash 模型的「已知存储内容」定义。Flash 模型和测试平台 include 同一个文件、
// 调用同一个函数来产生/预测字节值，因此期望值与模型内容永远一致。
//
// 用法：在**每个** module 内部 `include 本文件：
//
//     module foo;
//         `include "flash_mem_init.vh"
//         ...
//     endmodule
//
// 故意不写 include guard：guard 是全局宏，会让第二个 module 的 include 变成空操作，
// 于是那个 module 里就没有这个函数了。函数定义在 module 作用域内，各 module 各有一份，
// 同名互不冲突。
// -----------------------------------------------------------------------------

// 地址 a 处的字节值：
//
//     pattern(a) = a[7:0] ^ a[15:8] ^ 8'h5A
//
// 低 16 位都参与运算，所以任何只丢掉高位地址的译码错误都会让读回值不同 —— 这正是
// 我们想要的：一个「地址错但数据看着合理」的 bug 会被抓住，而不是蒙混过关。
//
// 示例：
//     addr 0x000000 -> 字节 5A 5B 58 59 -> PRDATA = 0x5A5B5859
//     addr 0x000020 -> 字节 7A 7B 78 79 -> PRDATA = 0x7A7B7879
//     addr 0xFFFFFC -> 字节 59 58 5B 5A -> PRDATA = 0x5958 5B5A
//                      （地址对 MEM_BYTES 取模后落在 0xFFFC，见 flash_model.v）
function [7:0] flash_mem_pattern;
    input [23:0] a;
    begin
        flash_mem_pattern = a[7:0] ^ a[15:8] ^ 8'h5A;
    end
endfunction
