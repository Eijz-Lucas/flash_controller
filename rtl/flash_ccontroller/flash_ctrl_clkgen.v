`timescale 1ns/1ps
module flash_ctrl_clkgen (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         en,
    input  wire [7:0]   clk_div,
    input  wire         clk_div_valid,
    output reg          spi_clk,
    output reg          spi_fall,
    output reg          spi_rise
);

    reg [7:0] counter_trgt;
    reg [7:0] counter_trgt_next;
    reg [7:0] counter;
    reg [7:0] counter_next;

    reg       spi_clk_next;
    reg       running;

    always @(*) begin
        spi_rise = 1'b0;
        spi_fall = 1'b0;

        if (clk_div_valid)
            counter_trgt_next = clk_div;
        else
            counter_trgt_next = counter_trgt;

        if (counter == counter_trgt) begin
            counter_next = 0;
            spi_clk_next = ~spi_clk;

            // 两个脉冲按「本次翻转之后的那条边沿」定义：
            //   spi_clk 现在为 0 -> 即将上升 -> spi_rise（接收方在本沿采样）
            //   spi_clk 现在为 1 -> 即将下降 -> spi_fall（发送方在本沿换数据）
            // 这是 SPI Mode 0 的要求：数据在下降沿改变、在上升沿被采样，
            // 收发双方各自采到的都是已经稳定了半个周期的电平。
            //
            // 两者不能对调。若 0 时给 spi_fall、1 时给 spi_rise，发送方就在 sclk
            // 上升沿的同一时刻换数据，接收方在同一时刻采样，采到的是「恰好正在被
            // 替换」的那一位。仿真里靠 iverilog 的 delta 顺序侥幸正确，但
            // 命令->地址这种「同一拍既有移位又有寄存器装载」的边界上就会多采或少
            // 采一位（症状：地址整体错一位、时钟数多一个）。
            if (spi_clk == 1'b0)
                spi_rise = running;
            else
                spi_fall = running;

	end else begin
            counter_next = counter + 1;
            spi_clk_next = spi_clk;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (rst_n == 1'b0) begin
            counter_trgt <= 'h3;
            counter      <= 'h0;
            spi_clk      <= 1'b0;
            running      <= 1'b0;
	    end 
        else begin
            counter_trgt <= counter_trgt_next;
            if (!((spi_clk == 1'b0) && ~en)) begin
                // 起振的第一个 HCLK 周期只把 running 立起来，不翻转 spi_clk。
                // 这样从 CS 有效到第一个 SCLK 上升沿之间至少隔一个 HCLK 周期，
                // 控制器来得及把 spi_oe 和命令首位建立到 pad 上。
                // 否则第一个上升沿会落在 spi_oe 还是 0 的那一拍：Flash 在它上面
                // 采到的是高阻（命令首字节读成 Z），而控制器自己又不把这半拍计入
                // 收发位数，结果是「数据正确、命令错位、时钟数多一个」。
                if (running) begin
                    spi_clk <= spi_clk_next;
                    counter <= counter_next;
                end
                running <= 1'b1;
	    end else
                running <= 1'b0;
        end
    end
    
endmodule
