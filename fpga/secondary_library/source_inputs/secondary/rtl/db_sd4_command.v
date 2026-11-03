// Native SD command channel; clk50 clock enables, no fabric-generated FF clocks.
// Command/short response CRC7 covers40 bits; R2 internal CRC covers120 bits.
module db_sd4_command(
 input wire clk,rst,rise_tick,fall_tick,start,
 input wire[5:0]index,input wire[31:0]argument,
 input wire[1:0]response_type, //0:none,1:short CRC,2:R2,3:R3 no CRC
 input wire cmd_in,output reg cmd_out,cmd_oe,
 output wire busy,output reg done,failed,output reg[3:0]error_code,
 output reg[135:0]response
);
 function[6:0]crc7(input[127:0]bits,input integer count);
  integer k;reg[6:0]c;reg fb;begin c=0;
   for(k=count-1;k>=0;k=k-1)begin fb=c[6]^bits[k];c={c[5:0],1'b0};if(fb)c=c^7'h09;end
   crc7=c;
  end
 endfunction
 localparam IDLE=0,SEND=1,RELEASE=2,WAIT_START=3,RECEIVE=4,CHECK=5,GAP=6;
 reg[2:0]state;reg[47:0]tx;reg[7:0]remaining;reg[7:0]wait_count;
 reg[1:0]kind;reg[5:0]held_index;
 wire[39:0]prefix={2'b01,index,argument};
 assign busy=(state!=IDLE);
 always@(posedge clk or posedge rst)begin
  if(rst)begin state<=IDLE;tx<=0;remaining<=0;wait_count<=0;kind<=0;held_index<=0;cmd_out<=1;cmd_oe<=0;done<=0;failed<=0;error_code<=0;response<=0;end
  else begin
   done<=0;
   case(state)
    IDLE:if(start)begin tx<={prefix,crc7({88'd0,prefix},40),1'b1};remaining<=47;kind<=response_type;held_index<=index;failed<=0;error_code<=0;response<=0;state<=SEND;end
    SEND:if(fall_tick)begin cmd_oe<=1;cmd_out<=tx[47];tx<={tx[46:0],1'b1};if(remaining==0)state<=RELEASE;else remaining<=remaining-1'b1;end
    RELEASE:if(fall_tick)begin cmd_oe<=0;cmd_out<=1;wait_count<=0;if(kind==0)state<=GAP;else state<=WAIT_START;end
    WAIT_START:if(rise_tick)begin
     if(!cmd_in)begin response<=0;remaining<=(kind==2)?135:47;state<=RECEIVE;end
     else if(wait_count==127)begin failed<=1;error_code<=1;wait_count<=0;state<=GAP;end
     else wait_count<=wait_count+1'b1;
    end
    RECEIVE:if(rise_tick)begin response<={response[134:0],cmd_in};if(remaining==1)state<=CHECK;else remaining<=remaining-1'b1;end
    CHECK:begin
     if(!response[0]||(kind==2?response[135:128]!=8'h3f:response[47:46]!=0))begin failed<=1;error_code<=2;end
     else if(kind!=2&&kind!=3&&response[45:40]!=held_index)begin failed<=1;error_code<=3;end
     else if(kind==3&&(response[45:40]!=6'h3f||response[7:1]!=7'h7f))begin failed<=1;error_code<=2;end
     else if(kind!=3&&response[7:1]!=(kind==2?crc7({8'd0,response[127:8]},120):crc7({88'd0,response[47:8]},40)))begin failed<=1;error_code<=4;end
     wait_count<=0;state<=GAP;
    end
    GAP:if(rise_tick)begin if(wait_count==7)begin done<=1;state<=IDLE;end else wait_count<=wait_count+1'b1;end
    default:begin state<=IDLE;cmd_oe<=0;end
   endcase
  end
 end
endmodule
