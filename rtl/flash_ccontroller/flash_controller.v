`timescale 1ns/1ps
`include "define.v"

module flash_controller (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [7:0]   spi_clk_div,
    input  wire         spi_clk_div_valid,
    output reg  [7:0]   spi_status,
    input  wire [31:0]  spi_addr,
    input  wire [5:0]   spi_addr_len,
    input  wire [31:0]  spi_cmd,
    input  wire [5:0]   spi_cmd_len,
    input  wire [15:0]  spi_data_len,
    input  wire [15:0]  spi_dummy_rd,
    input  wire [15:0]  spi_dummy_wr,
    input  wire         spi_rd,
    input  wire         spi_wr,
    input  wire         spi_qrd,
    input  wire         spi_qwr,
    input  wire [31:0]  spi_ctrl_data_tx,
    input  wire         spi_ctrl_data_tx_valid,
    output reg          spi_ctrl_data_tx_ready,
    output wire [31:0]  spi_ctrl_data_rx,
    output wire         spi_ctrl_data_rx_valid,
    input  wire         spi_ctrl_data_rx_ready,
    output wire         spi_clk,
    output wire         spi_csn0,
    output reg  [1:0]   spi_mode,
    output wire         spi_sdo0,
    output wire         spi_sdo1,
    output wire         spi_sdo2,
    output wire         spi_sdo3,
    input  wire         spi_sdi0,
    input  wire         spi_sdi1,
    input  wire         spi_sdi2,
    input  wire         spi_sdi3
);

    // 数据多路选择
    localparam [2:0] DATA_NULL  = 0;
    localparam [2:0] DATA_EMPTY = 1;
    localparam [2:0] DATA_CMD   = 2;
    localparam [2:0] DATA_ADDR  = 3;
    localparam [2:0] DATA_FIFO  = 4;

    // 状态编号 0..6 连续
    localparam [4:0] IDLE       = 0;
    localparam [4:0] CMD        = 1;
    localparam [4:0] ADDR       = 2;
    localparam [4:0] DUMMY      = 3;
    localparam [4:0] DATA_TX    = 4;
    localparam [4:0] DATA_RX    = 5;
    localparam [4:0] WAIT_EDGE  = 6;

//------------------------------------------------------------------
// signal define
//------------------------------------------------------------------
    wire       spi_rise;
    wire       spi_fall;
    reg        spi_clock_en;

    reg        spi_en_tx;
    reg        spi_en_rx;
    reg [15:0] counter_tx;
    reg        counter_tx_valid;
    reg [15:0] counter_rx;
    reg        counter_rx_valid;
    reg [31:0] data_to_tx;
    reg        data_to_tx_valid;
    wire       data_to_tx_ready;
    wire       en_quad;
    reg        en_quad_int;
    // 读/写方向只需要 do_rx 一个标志。
    reg        do_rx;
    wire       tx_done;
    wire       rx_done;
    reg [1:0]  s_spi_mode;
    reg        ctrl_data_valid;
    reg        spi_cs;
    // FSM 组合块的临时变量：块内先算到 temp，块尾再一次性赋给输出。
    // 直接在 always @(*) 里对 spi_cs 这类输出做多次阻塞赋值时，iverilog 会把中间值
    // （块首的默认值）也传播出去，于是每个 HCLK 边沿 spi_cs 都出现 0->1->0 的零宽毛刺；
    // Flash 模型会把它当成一次片选释放（posedge cs_n），事务永远走不完。
    // 详见 doc/spec.md「组合毛刺与 pad 输出」。
    reg        spi_cs_t;
    reg        spi_clock_en_t;
    reg        spi_en_tx_t;
    reg        spi_en_rx_t;
    wire       tx_clk_en;
    wire       rx_clk_en;
    reg [2:0]  ctrl_data_mux;
    reg [4:0]  cur_state;
    reg [4:0]  next_state;
    // en_quad_int 在语义上已覆盖 (spi_qrd|spi_qwr)：前者是后者的寄存版本。
    // 保留这个看似冗余的组合项是刻意的 —— 去掉它要重新论证一拍时序差，没有收益。
    assign en_quad = (spi_qrd | spi_qwr) | en_quad_int;
//------------------------------------------------------------------
// interface  connect
//------------------------------------------------------------------
    flash_ctrl_clkgen u_clkgen
    (
      .clk           ( clk               ),
      .rst_n         ( rst_n             ),
      .en            ( spi_clock_en      ),
      .clk_div       ( spi_clk_div       ),
      .clk_div_valid ( spi_clk_div_valid ),
      .spi_clk       ( spi_clk           ),
      .spi_fall      ( spi_fall          ),
      .spi_rise      ( spi_rise          )
    );

    flash_ctrl_tx u_txreg
    (
      .clk            ( clk              ),
      .rst_n          ( rst_n            ),
      .en             ( spi_en_tx        ),
      .tx_edge        ( spi_fall         ),
      .tx_done        ( tx_done          ),
      .sdo0           ( spi_sdo0         ),
      .sdo1           ( spi_sdo1         ),
      .sdo2           ( spi_sdo2         ),
      .sdo3           ( spi_sdo3         ),
      .en_quad_in     ( en_quad          ),
      .counter_in     ( counter_tx       ),
      .counter_in_vld ( counter_tx_valid ),
      .data           ( data_to_tx       ),
      .data_valid     ( data_to_tx_valid ),
      .data_ready     ( data_to_tx_ready ),
      .clk_en_o       ( tx_clk_en        )
    );

    flash_ctrl_rx u_rxreg
    (
      .clk            ( clk                    ),
      .rst_n          ( rst_n                  ),
      .en             ( spi_en_rx              ),
      .rx_edge        ( spi_rise               ),
      .rx_done        ( rx_done                ),
      .sdi0           ( spi_sdi0               ),
      .sdi1           ( spi_sdi1               ),
      .sdi2           ( spi_sdi2               ),
      .sdi3           ( spi_sdi3               ),
      .en_quad_in     ( en_quad                ),
      .counter_in     ( counter_rx             ),
      .counter_in_vld ( counter_rx_valid       ),
      .data           ( spi_ctrl_data_rx       ),
      .data_valid     ( spi_ctrl_data_rx_valid ),
      .data_ready     ( spi_ctrl_data_rx_ready ),
      .clk_en_o       ( rx_clk_en              )
    );

    always @(*) begin
        data_to_tx             = 'h0;
        data_to_tx_valid       = 1'b0;
        spi_ctrl_data_tx_ready = 1'b0;

        case (ctrl_data_mux)
            DATA_NULL: begin
                data_to_tx             = 'b0;
                data_to_tx_valid       = 1'b0;
                spi_ctrl_data_tx_ready = 1'b0;
            end
            DATA_EMPTY: begin
                data_to_tx       = 'b0;
                data_to_tx_valid = 1'b1;
            end
            DATA_CMD: begin
                data_to_tx             = spi_cmd;
                data_to_tx_valid       = ctrl_data_valid;
                spi_ctrl_data_tx_ready = 1'b0;
            end
            DATA_ADDR: begin
                data_to_tx             = spi_addr;
                data_to_tx_valid       = ctrl_data_valid;
                spi_ctrl_data_tx_ready = 1'b0;
            end
            DATA_FIFO: begin
                data_to_tx             = spi_ctrl_data_tx;
                data_to_tx_valid       = spi_ctrl_data_tx_valid;
                spi_ctrl_data_tx_ready = data_to_tx_ready;
            end
        endcase
    end
//------------------------------------------------------------------
// FSM  
//------------------------------------------------------------------
    always @(*) begin
        spi_cs_t           = 1'b1;
        spi_clock_en_t     = 1'b0;
        counter_tx       = 'b0;
        counter_tx_valid = 1'b0;
        counter_rx       = 'b0;
        counter_rx_valid = 1'b0;
        next_state       = cur_state;
        ctrl_data_mux    = DATA_NULL;
        ctrl_data_valid  = 1'b0;
        spi_en_rx_t        = 1'b0;
        spi_en_tx_t        = 1'b0;
        spi_status       = 'b0;
        s_spi_mode       = `SPI_QUAD_RX;
        case (cur_state)
            IDLE: begin
                spi_status[0] = 1'b1;
                s_spi_mode    = `SPI_QUAD_RX;

                // 唯一的入口条件：任一触发位置起就开始一笔事务。
                if (spi_rd || spi_wr || spi_qrd || spi_qwr) begin
                    spi_cs_t       = 1'b0;
                    spi_clock_en_t = 1'b1;

                    if (spi_cmd_len != 0) begin
                        s_spi_mode       = (spi_qrd | spi_qwr) ? `SPI_QUAD_TX : `SPI_STD;
                        counter_tx       = {8'h00, spi_cmd_len};
                        counter_tx_valid = 1'b1;
                        ctrl_data_mux    = DATA_CMD;
                        ctrl_data_valid  = 1'b1;
                        spi_en_tx_t        = 1'b1;
                        next_state       = CMD;
		            end 
                    else if (spi_addr_len != 0) begin
                    	s_spi_mode       = (spi_qrd | spi_qwr) ? `SPI_QUAD_TX : `SPI_STD;
                    	counter_tx       = {8'h00, spi_addr_len};
                    	counter_tx_valid = 1'b1;
                    	ctrl_data_mux    = DATA_ADDR;
                    	ctrl_data_valid  = 1'b1;
                    	spi_en_tx_t        = 1'b1;
                    	next_state       = ADDR;
		            end 
                    else if (spi_data_len != 0) begin
                        if (spi_rd || spi_qrd) begin
                            s_spi_mode = (spi_qrd) ? `SPI_QUAD_RX : `SPI_STD;

                            if (spi_dummy_rd != 0) begin
                                counter_tx       = (en_quad) ? {spi_dummy_rd[13:0], 2'b00} : spi_dummy_rd;
                                counter_tx_valid = 1'b1;
                                spi_en_tx_t        = 1'b1;
                                ctrl_data_mux    = DATA_EMPTY;
                                next_state       = DUMMY;
			                end 
                            else begin
                            	counter_rx       = spi_data_len;
                            	counter_rx_valid = 1'b1;
                            	spi_en_rx_t        = 1'b1;
                            	next_state       = DATA_RX;
                            end
			            end 
                        else begin
                            s_spi_mode = (spi_qwr) ? `SPI_QUAD_TX : `SPI_STD;

                            if (spi_dummy_wr != 0) begin
                                counter_tx       = (en_quad) ? {spi_dummy_wr[13:0], 2'b00} : spi_dummy_wr;
                                counter_tx_valid = 1'b1;
                                ctrl_data_mux    = DATA_EMPTY;
                                spi_en_tx_t        = 1'b1;
                                next_state       = DUMMY;
			                end 
                            else begin
                                counter_tx       = spi_data_len;
                                counter_tx_valid = 1'b1;
                                ctrl_data_mux    = DATA_FIFO;
                                ctrl_data_valid  = 1'b0;
                                spi_en_tx_t        = 1'b1;
                                next_state       = DATA_TX;
                            end
                        end
		            end 
                    else begin
                        // 只发命令、不带地址也不带数据（例如 WREN 0x06）：
                        // 片选直接释放，回 IDLE
                        spi_cs_t     = 1'b1;
                        next_state = IDLE;
                    end
                end
            end
            CMD: begin
                spi_status[1] = 1'b1;
                spi_cs_t        = 1'b0;
                // 时钟跟着发送器走，理由见 ADDR 状态里的说明。
                spi_clock_en_t  = tx_clk_en;
                s_spi_mode    = (en_quad) ? `SPI_QUAD_TX : `SPI_STD;

                if (tx_done) begin
                    if (spi_addr_len != 0) begin
                        s_spi_mode       = (en_quad) ? `SPI_QUAD_TX : `SPI_STD;
                        counter_tx       = {8'h00, spi_addr_len};
                        counter_tx_valid = 1'b1;
                        ctrl_data_mux    = DATA_ADDR;
                        ctrl_data_valid  = 1'b1;
                        spi_en_tx_t        = 1'b1;
                        next_state       = ADDR;
		            end 
                    else if (spi_data_len != 0) begin
                        if (do_rx) begin
                            s_spi_mode = (en_quad) ? `SPI_QUAD_RX : `SPI_STD;
                            if (spi_dummy_rd != 0) begin
                                counter_tx       = (en_quad) ? {spi_dummy_rd[13:0], 2'b00} : spi_dummy_rd;
                                counter_tx_valid = 1'b1;
                                spi_en_tx_t        = 1'b1;
                                ctrl_data_mux    = DATA_EMPTY;
                                next_state       = DUMMY;
			                end 
                            else begin
                                counter_rx       = spi_data_len;
                                counter_rx_valid = 1'b1;
                                spi_en_rx_t        = 1'b1;
                                next_state       = DATA_RX;
                            end
			            end 

                        else begin
                            s_spi_mode = (en_quad) ? `SPI_QUAD_TX : `SPI_STD;
                            if (spi_dummy_wr != 0) begin
                                counter_tx       = (en_quad) ? {spi_dummy_wr[13:0], 2'b00} : spi_dummy_wr;
                                counter_tx_valid = 1'b1;
                                ctrl_data_mux    = DATA_EMPTY;
                                spi_en_tx_t        = 1'b1;
                                next_state       = DUMMY;
			                end 
                            else begin
                            	counter_tx       = spi_data_len;
                            	counter_tx_valid = 1'b1;
                            	ctrl_data_mux    = DATA_FIFO;
                            	ctrl_data_valid  = 1'b1;
                            	spi_en_tx_t        = 1'b1;
                            	next_state       = DATA_TX;
                            end
                        end
	                end 

                    else begin
                    	next_state = IDLE;
                    end
		        end

	       end

            ADDR: begin
                spi_en_tx_t     = 1'b1;
                spi_status[2] = 1'b1;
                spi_cs_t        = 1'b0;
                // 这里用发送器自己的使能（tx_cur_state == TRANSMIT）而不是常数 1，
                // 是为了在换字的那一拍停掉 SCLK。
                //
                // 每个字（命令 / 地址 / dummy / 数据）发完，flash_ctrl_tx 都要先回到
                // IDLE 才能装载下一个字，而 tx_data_locked 只在 IDLE 且 (data_valid &&
                // data_ready) 时装载：从「最后一个 tx_edge」到「真正装上下一个字」中间
                // 必然隔着一拍 HCLK。这一拍里 sdo* 上还是上一个字的最后一位。
                //
                // 如果让 SCLK 一直跑，这一拍就会多出一个上升沿：从机把它当成一位数据
                // 采走，于是地址在最高位多出一个 1（这位其实是上一条命令的最低位），
                // 整个事务的时钟数也多一个。更要命的是新字的装载恰好发生在那个上升沿
                // 上——数据与时钟同沿翻转，从机保持时间不够，真实器件会采到旧值。
                //
                // 停一拍时钟，新字就在 SCLK 为低的时候建立好，等到下一个上升沿已经稳定
                // 了一个 HCLK 周期。这正是 SSI 在数据没准备好时插入时钟间隙的做法。
                spi_clock_en_t  = tx_clk_en;
                s_spi_mode    = (en_quad) ? `SPI_QUAD_TX : `SPI_STD;
		        if (tx_done) begin
                    if ((spi_data_len != 0)) begin
                        if (do_rx ) begin
                            s_spi_mode = (en_quad) ? `SPI_QUAD_RX : `SPI_STD;
                            if (spi_dummy_rd != 0) begin
                                counter_tx       = (en_quad) ? {spi_dummy_rd[13:0], 2'b00} : spi_dummy_rd;
                                counter_tx_valid = 1'b1;
                                spi_en_tx_t        = 1'b1;
                                ctrl_data_mux    = DATA_EMPTY;
                                next_state       = DUMMY;
			                end 
                            else begin
                                counter_rx       = spi_data_len;
                                counter_rx_valid = 1'b1;
                                spi_en_rx_t        = 1'b1;
                                next_state       = DATA_RX;
                            end
			            end 
                        else begin
                            s_spi_mode = (en_quad) ? `SPI_QUAD_TX : `SPI_STD;
                            spi_en_tx_t  = 1'b1;

                            if (spi_dummy_wr != 0) begin
                                counter_tx       = (en_quad) ? {spi_dummy_wr[13:0], 2'b00} : spi_dummy_wr;
                                counter_tx_valid = 1'b1;
                                ctrl_data_mux    = DATA_EMPTY;
                                next_state       = DUMMY;
			                end
                            else begin
                                counter_tx       = spi_data_len;
                                counter_tx_valid = 1'b1;
                                ctrl_data_mux    = DATA_FIFO;
                                ctrl_data_valid  = 1'b1;
                                next_state       = DATA_TX;
                            end
                        end
	                end
                    else begin
                        next_state = IDLE;
		            end
		        end
            end
            DUMMY: begin
                spi_en_tx_t     = 1'b1;
                spi_status[4] = 1'b1;
                spi_cs_t        = 1'b0;
                // 这里**不**用 tx_clk_en：dummy 相是最后一个发送相，紧接着就要切到
                // 接收相。收相靠 rx_clk_en 起振，如果这里再插一个时钟间隙，dummy 结束
                // 到数据开始之间会出现一段被拉长的 SCLK 低电平，接收端在同一个低电平
                // 里会采样两次（低位重复一次、整体右移一位）。发送相之间的换字间隙
                // （CMD->ADDR、ADDR->DUMMY）仍由前一个状态的 tx_clk_en 产生。
                spi_clock_en_t  = 1'b1;
                s_spi_mode    = (en_quad ) ? `SPI_QUAD_RX : `SPI_STD;
                    if (tx_done) begin
                        if (spi_data_len != 0 ) begin
                            if (do_rx) begin
                                counter_rx       = spi_data_len;
                                counter_rx_valid = 1'b1;
                                spi_en_rx_t        = 1'b1;
                                next_state       = DATA_RX;
                            end 
                            else begin
                                counter_tx       = spi_data_len;
                                counter_tx_valid = 1'b1;
                                s_spi_mode       = (en_quad) ? `SPI_QUAD_TX : `SPI_STD;
                                spi_clock_en_t     = tx_clk_en;
                                spi_en_tx_t        = 1'b1;
                                next_state       = DATA_TX;
                            end
                        end
                        else begin
                                next_state = IDLE;
                        end
                    end
            end
            DATA_TX: begin
                spi_status[5]   = 1'b1;
                spi_cs_t          = 1'b0;
                spi_clock_en_t    = tx_clk_en;
                ctrl_data_mux   = DATA_FIFO;
                ctrl_data_valid = 1'b1;
                spi_en_tx_t       = 1'b1;
                s_spi_mode      = (en_quad) ? `SPI_QUAD_TX : `SPI_STD;

                if (tx_done) begin
                    next_state   = IDLE;
                    spi_clock_en_t = 1'b0;
	            end
            end
            DATA_RX: begin
                spi_status[6] = 1'b1;
                spi_cs_t        = 1'b0;
                spi_clock_en_t  = rx_clk_en;
                s_spi_mode    = (en_quad) ? `SPI_QUAD_RX : `SPI_STD; 
                if (rx_done) begin
                    next_state = WAIT_EDGE;
                end 
            end
            WAIT_EDGE: begin
                spi_status[6]  = 1'b1;
                spi_cs_t         = 1'b0;
                // 收尾：把时钟停掉，等 SCLK 回到低电平再释放片选。
                //
                // 这里有两个坑：
                // 1) 停时钟不能靠「等 spi_fall」。en 拉低后 clkgen 停在 spi_clk==0，
                //    不会再产生任何沿；如果退出条件还是 spi_fall，FSM 就卡死在
                //    WAIT_EDGE，spi_cs 一直不释放（片选不放，下一次事务起不来）。
                // 2) 也不能让时钟继续跑。最后一个数据位已经采完，时钟再跑就会多出
                //    一个上升沿，从机把它当成第 33 个数据时钟（症状：一次事务
                //    sclk_rises 是 73 而不是 72）。
                //
                // 停 en 之后 clkgen 会自己把剩下半个周期走完（SCLK 高时先翻到低），
                // 所以这里只要等 spi_clk 落地就说明最后那个下降沿已经发出去了。
                spi_clock_en_t   = 1'b0;
                s_spi_mode     = (en_quad) ? `SPI_QUAD_RX : `SPI_STD;
                if (~spi_clk) begin
                    next_state = IDLE;
	            end
            end
        endcase
        // 组合块唯一出口：上面所有毛刺在这里被吸收
        spi_cs         = spi_cs_t;
        spi_clock_en   = spi_clock_en_t;
        spi_en_tx      = spi_en_tx_t;
        spi_en_rx      = spi_en_rx_t;
    end


    // 方向标志是**锁存**的：spi_rd/spi_wr 这些脉冲在 apb_if 里下一拍就被清掉，
    // 而 FSM 要到事务后段（CMD 的后继）才用 do_rx 判断读还是写，所以必须记住
    // 触发那一刻的方向。
    always @(posedge clk or negedge rst_n) begin
        if (rst_n == 1'b0) begin
            cur_state       <= IDLE;
            en_quad_int <= 1'b0;
            do_rx       <= 1'b0;
            spi_mode    <= `SPI_QUAD_RX;
	    end
        else begin
            cur_state    <= next_state;
            spi_mode <= s_spi_mode;

            if (spi_qrd || spi_qwr)
                en_quad_int <= 1'b1;
            else if (next_state == IDLE)
                en_quad_int <= 1'b0;

            // 读优先：同时置起读和写时按读处理。
            if (spi_rd || spi_qrd)
                do_rx <= 1'b1;
            else if (spi_wr || spi_qwr || next_state == IDLE)
                do_rx <= 1'b0;
        end
    end

    assign spi_csn0 = spi_cs;


endmodule
