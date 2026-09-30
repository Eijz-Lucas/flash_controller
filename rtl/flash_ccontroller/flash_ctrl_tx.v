`timescale 1ns/1ps
module flash_ctrl_tx (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,

    input  wire        tx_edge, //signal for sclk negedge
    output wire        tx_done, //signal to indicate the tx finished

    output wire        sdo0,
    output wire        sdo1,
    output wire        sdo2,
    output wire        sdo3,

    input  wire        en_quad_in,
    input  wire [15:0] counter_in,
    input  wire        counter_in_vld,

    input  wire [31:0] data,
    input  wire        data_valid,
    output wire        data_ready,

    output wire        clk_en_o
);


//------------------------------------------------------------------
// signal define
//------------------------------------------------------------------
    localparam  IDLE           = 0;
    localparam  TRANSMIT       = 1;

    reg     tx_cur_state    ;
    reg     tx_next_state   ;

    wire    tx_start        ;   //start to tansmit data to spi slave
    wire    tx_done_reg     ;
    reg     tx_done_d1      ;   //end data transmit to spi slave

    reg [31:0] tx_data_locked;
    reg [15:0] counter;
    reg [15:0] counter_trgt;

//------------------------------------------------------------------
// state machine 
//------------------------------------------------------------------
    always @ (posedge clk or negedge rst_n) begin   
        if(rst_n == 1'b0)
            tx_cur_state <= IDLE;
        else 
            tx_cur_state <= tx_next_state;
    end

    always @(*) begin
        case (tx_cur_state)
            IDLE: begin
                if( tx_start )
                    tx_next_state = TRANSMIT;
                else
                    tx_next_state = IDLE;
            end
            TRANSMIT: begin
                if ( tx_done_reg )
                    tx_next_state = IDLE ;
                else
                    tx_next_state = TRANSMIT; 
            end
        endcase
    end
//------------------------------------------------------------------
// state loop condition 
//------------------------------------------------------------------
    assign tx_start = ( tx_cur_state == IDLE ) & ( en ) & ( data_valid );
    assign tx_done_reg = ( tx_cur_state == TRANSMIT ) && (counter == (counter_trgt - 1 )) && tx_edge;
//------------------------------------------------------------------
// Master interface to controller 
//------------------------------------------------------------------
    // assign tx_4bytes_done = tx_4bytes_d0 & ~tx_4bytes_d1; //
    assign data_ready =  (tx_cur_state == IDLE) ;//receive data  when state is IDLE or send 4 bytes data done
    assign tx_done  = tx_done_d1;
    always @(posedge clk or negedge rst_n) begin
        if( rst_n == 1'b0 )begin
            tx_done_d1 <= 'b0;
        end
        else begin
            tx_done_d1 <= tx_done_reg ;
        end
    end
    //enable the sclk when transmit data
    assign clk_en_o = ( tx_cur_state == TRANSMIT );

    //send data bits num receive
    always @(posedge clk or negedge rst_n)begin
        if( rst_n == 1'b0 )begin
            counter_trgt <= 'd0 ;
        end
        else begin
            if( (tx_cur_state == IDLE) && counter_in_vld)begin
                if(en_quad_in)begin
                    counter_trgt <= {2'b0,counter_in[15:2]};
                end
                else begin
                    counter_trgt <= counter_in ;
                end
            end
        end
    end

//------------------------------------------------------------------
// Master interface to spi slave
//------------------------------------------------------------------
    //spi_sdo output
    assign sdo0 = (en_quad_in) ? tx_data_locked[28] : tx_data_locked[31];
    assign sdo1 = tx_data_locked[29];
    assign sdo2 = tx_data_locked[30];
    assign sdo3 = tx_data_locked[31];

    //spi_data_trans count && data shift
    always @(posedge clk or negedge rst_n) begin
        if( rst_n == 1'b0 )begin
            counter <= 'b0 ;
            tx_data_locked <= 'b0;
        end
        else begin
            if( ( tx_cur_state == IDLE ) && data_valid && data_ready)begin
                    tx_data_locked <= data ;
            end
            if( tx_edge && (tx_cur_state == TRANSMIT) && (tx_next_state != IDLE))begin
                tx_data_locked <= (en_quad_in ? {tx_data_locked[27:0], 4'b0000} : {tx_data_locked[30:0], 1'b0});
                counter <= counter + 1;
            end
            else if(tx_next_state == IDLE ) begin
                counter <= 'd0 ;
            end
        end
    end

endmodule
