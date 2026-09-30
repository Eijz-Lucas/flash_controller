`timescale 1ns/1ps
module flash_ctrl_rx (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         en,

    input  wire         rx_edge, //posedge of sclk start to receive the data from flash
    output wire         rx_done, //recevied the given number of rdata bits  from flash  

    input  wire         sdi0,
    input  wire         sdi1,
    input  wire         sdi2,
    input  wire         sdi3,

    input  wire         en_quad_in,
    
    input  wire [15:0]  counter_in,
    input  wire         counter_in_vld,

    output wire [31:0]  data,
    input  wire         data_ready,     //fifo ready to send in 
    output wire         data_valid,
    output wire         clk_en_o
);

//------------------------------------------------------------------
// signal define
//------------------------------------------------------------------
    localparam      IDLE           = 0;
    localparam      RECEIVE        = 1;
    localparam      WAIT_FIFO      = 2;

    reg     [1:0]   rx_cur_state    ;
    reg     [1:0]   rx_next_state   ;

    reg     [31:0]  rx_data_locked  ;

    reg             rx_4bytes_d0    ;
    reg             rx_4bytes_d1    ;
    wire            rx_4bytes_done  ;

    reg     [15:0]  counter_trgt    ;
    reg     [15:0]  counter         ;

    wire            rx_start        ;
    wire            rx_wr_done      ;
    

//------------------------------------------------------------------
// state machine 
//------------------------------------------------------------------
    always @ (posedge clk or negedge rst_n) begin   
        if(rst_n == 1'b0)
            rx_cur_state <= IDLE;
        else 
            rx_cur_state <= rx_next_state;
    end

    always @(*) begin

        case (rx_cur_state)

            IDLE: begin
                if( rx_start ) 
                    rx_next_state = RECEIVE ;
                else
                    rx_next_state = IDLE ;
            end

            RECEIVE: begin
                if ( rx_done )
                    rx_next_state = WAIT_FIFO ;
                else 
                    rx_next_state = RECEIVE ; 
            end

            WAIT_FIFO: begin
                if ( rx_wr_done)
                    rx_next_state = IDLE;
                else
                    rx_next_state = WAIT_FIFO ; 
            end

        endcase
    end
//------------------------------------------------------------------
// state loop condition 
//------------------------------------------------------------------
    assign rx_start        = ( rx_cur_state == IDLE ) && en ;

    // rx_go 比「状态已经是 RECEIVE」多包含一种情形：本拍刚好被使能。
    // 控制器从 DUMMY 跳到 DATA_RX 的那一拍，正是第一个数据位的采样沿（Flash 在
    // 上一个下降沿已经把它放到 pad 上）。如果非要等状态寄存器更新到 RECEIVE 才
    // 允许移位，这一位就会被丢掉，读回值整体左移一位、末位补一个垃圾位。
    wire rx_go = ( rx_cur_state == RECEIVE ) || rx_start ;
    assign rx_done         = ( rx_cur_state == RECEIVE ) && ( counter == counter_trgt );
    assign rx_wr_done      = ( rx_cur_state == WAIT_FIFO ) && data_ready; 
//------------------------------------------------------------------
// Master interface to controller 
//------------------------------------------------------------------
    assign clk_en_o = (rx_cur_state == RECEIVE);
    //read data bits num received 
    always @(posedge clk or negedge rst_n) begin
        if ( rst_n == 1'b0 )begin
            counter_trgt <= 'b0;
        end
        else begin
            if ( ( rx_cur_state == IDLE ) && counter_in_vld )begin
                if(en_quad_in)begin
                    counter_trgt <= {2'b0,counter_in[15:2]};
                end
                else begin
                    counter_trgt <= counter_in ;
                end
            end
        end
    end


    //spi_data_transfer count && data shift
    always @(posedge clk or negedge rst_n) begin
        if( rst_n == 1'b0 )begin
            counter <= 'b0 ;
            rx_data_locked <= 'b0;
        end
        else begin
            if( rx_edge && rx_go  )begin
                rx_data_locked <= (en_quad_in ? {rx_data_locked[27:0], sdi3, sdi2, sdi1, sdi0} : {rx_data_locked[30:0], sdi1});
                counter <= counter + 1;
            end
            else if(rx_next_state == IDLE ) begin
                counter <= 'd0 ;
            end
        end
    end


    always @(posedge clk or negedge rst_n) begin
        if ( rst_n == 1'b0 ) begin
            rx_4bytes_d0 <= 1'b0;
            rx_4bytes_d1 <= 1'b0;
        end
        else begin
            rx_4bytes_d1 <= rx_4bytes_d0;
            if (  (rx_cur_state == RECEIVE) && (en_quad_in && (counter[2:0] ==3'b0) && (counter != 'd0)) ) begin
                rx_4bytes_d0 <= 1'b1;
            end
            else if (  (rx_cur_state == RECEIVE) && (~en_quad_in && counter[4:0] ==5'b0) && (counter != 'd0)) begin
                rx_4bytes_d0 <= 1'b1;
            end
            else begin
                rx_4bytes_d0 <= 1'b0;
            end
        end
        
    end

    assign rx_4bytes_done =  rx_4bytes_d0 && (~rx_4bytes_d1);
    assign data_valid = (rx_cur_state == WAIT_FIFO ) || rx_4bytes_done;
    assign data = rx_data_locked;

endmodule
