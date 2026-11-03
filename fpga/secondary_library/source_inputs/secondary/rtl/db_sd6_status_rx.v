// Read-only native four-lane SD data receiver. Bytes are provisional until
// block_done with !failed; future media integration must buffer the whole sector.
module db_sd6_status_rx #(parameter TIMEOUT_CYCLES=15000000)(
 input wire clk,rst,rise_tick,arm,input wire[3:0]dat,
 output reg[7:0]byte_data,output reg byte_valid,block_done,failed,
 output reg[3:0]error_code,output wire busy
);
 localparam IDLE=0,TOKEN=1,DATA=2,CRC=3,END_BIT=4;
 reg[2:0]state;reg[9:0]nibbles;reg[3:0]high_nibble,crc_index;
 reg[15:0]c0,c1,c2,c3;reg[24:0]watchdog;
 function[15:0]step_crc(input[15:0]c,input b);begin step_crc={c[14:0],1'b0}^((c[15]^b)?16'h1021:16'd0);end endfunction
 assign busy=state!=IDLE;
 always@(posedge clk or posedge rst)begin
  if(rst)begin state<=IDLE;nibbles<=0;high_nibble<=0;crc_index<=0;c0<=0;c1<=0;c2<=0;c3<=0;watchdog<=0;byte_data<=0;byte_valid<=0;block_done<=0;failed<=0;error_code<=0;end
  else begin
   byte_valid<=0;block_done<=0;
   if(state!=IDLE&&watchdog==TIMEOUT_CYCLES-1)begin failed<=1;error_code<=1;state<=IDLE;block_done<=1;end
   else begin
    if(state!=IDLE)watchdog<=watchdog+1'b1;
    case(state)
     IDLE:if(arm)begin state<=TOKEN;watchdog<=0;failed<=0;error_code<=0;c0<=0;c1<=0;c2<=0;c3<=0;nibbles<=0;crc_index<=0;end
     TOKEN:if(rise_tick&&!dat[0])begin
      if(dat!=0)begin failed<=1;error_code<=2;state<=IDLE;block_done<=1;end else state<=DATA;
     end
     DATA:if(rise_tick)begin
      c0<=step_crc(c0,dat[0]);c1<=step_crc(c1,dat[1]);c2<=step_crc(c2,dat[2]);c3<=step_crc(c3,dat[3]);
      if(!nibbles[0])high_nibble<=dat;else begin byte_data<={high_nibble,dat};byte_valid<=1;end
      if(nibbles==127)begin state<=CRC;crc_index<=15;end else nibbles<=nibbles+1'b1;
     end
     CRC:if(rise_tick)begin
      if(dat!={c3[crc_index],c2[crc_index],c1[crc_index],c0[crc_index]})begin failed<=1;error_code<=3;end
      if(crc_index==0)state<=END_BIT;else crc_index<=crc_index-1'b1;
     end
     END_BIT:if(rise_tick)begin if(dat!=15)begin failed<=1;error_code<=4;end state<=IDLE;block_done<=1;end
     default:state<=IDLE;
    endcase
   end
  end
 end
endmodule
