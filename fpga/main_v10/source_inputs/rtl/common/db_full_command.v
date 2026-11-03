`timescale 1ns/1ps
// Existing return wire, 500kbaud8N1 at50MHz. Nine bytes: A5 5A 11,
// little-endian32bit absolute control word, CRC16lo/high over11+word.
// Includes song,play/menu,next event counter,frame permit,file-buffer room.
module db_full_command_tx #(parameter DIV=100,REPEAT_CYCLES=50000)(
 input clk,rst,enable,input[31:0]control_word,output wire serial_out
);
 `include "db_crc16.vh"
 reg[22:0]period_count;reg[15:0]timer,crc;reg[9:0]shift;
 reg[3:0]bit_index;reg[3:0]byte_index;reg busy;reg[31:0]held_word,sent_word;
 reg pending;reg[7:0]next_byte;
 assign serial_out=busy&&bit_index<10?shift[0]:1'b1;
 always@*case(byte_index)
  0:next_byte=8'ha5;1:next_byte=8'h5a;2:next_byte=8'h11;
  3,4,5,6:next_byte=held_word[(byte_index-3)*8+:8];7:next_byte=crc[7:0];default:next_byte=crc[15:8];
 endcase
 always@(posedge clk or posedge rst)
 if(rst)begin period_count<=0;timer<=0;crc<=16'hffff;shift<=10'h3ff;bit_index<=0;byte_index<=0;busy<=0;held_word<=0;sent_word<=0;pending<=1;end
 else if(!enable)begin busy<=0;period_count<=0;pending<=1;end
 else if(!busy)begin
  if(pending||control_word!=sent_word||period_count==REPEAT_CYCLES-1)begin
   held_word<=control_word;sent_word<=control_word;pending<=0;period_count<=0;
   byte_index<=0;bit_index<=0;timer<=DIV-1;shift<={1'b1,8'ha5,1'b0};busy<=1;crc<=16'hffff;
  end else period_count<=period_count+1'b1;
 end else if(bit_index==10)begin
  shift<={1'b1,next_byte,1'b0};bit_index<=0;timer<=DIV-1;
  if(byte_index>=2&&byte_index<=6)crc<=db_crc16_byte(crc,next_byte);
 end else if(timer!=0)timer<=timer-1'b1;
 else begin
  timer<=DIV-1;
  if(bit_index!=9)begin shift<={1'b1,shift[9:1]};bit_index<=bit_index+1'b1;end
  else if(byte_index==8)busy<=0;
  else begin
   // Advance byte separately so the next-byte mux sees the new index.
   bit_index<=10;byte_index<=byte_index+1'b1;
  end
 end
endmodule

module db_full_command_rx #(parameter DIV=100)(
 input clk,rst,serial_in,output reg[31:0]control_word,output reg command_valid
);
 `include "db_crc16.vh"
 (* async_reg="true" *)reg[2:0]sync;
 reg[15:0]timer;reg[3:0]bit_index;reg[7:0]shift,byte_data;
 reg busy,byte_valid;reg[3:0]index;reg[15:0]crc;reg[31:0]selection;reg[7:0]crc_low;
 reg[13:0]age;
 always@(posedge clk or posedge rst)
 if(rst)begin sync<=7;timer<=0;bit_index<=0;shift<=0;byte_data<=0;busy<=0;byte_valid<=0;end
 else begin
  sync<={sync[1:0],serial_in};byte_valid<=0;
  if(!busy)begin if(!sync[2])begin busy<=1;timer<=DIV/2-1;bit_index<=0;end end
  else if(timer!=0)timer<=timer-1'b1;
  else begin
   timer<=DIV-1;
   if(bit_index==0)begin if(sync[2])busy<=0;else bit_index<=1;end
   else if(bit_index<=8)begin shift<={sync[2],shift[7:1]};bit_index<=bit_index+1'b1;end
   else begin busy<=0;if(sync[2])begin byte_data<=shift;byte_valid<=1;end end
  end
 end
 always@(posedge clk or posedge rst)
 if(rst)begin index<=0;crc<=16'hffff;selection<=0;crc_low<=0;control_word<=0;command_valid<=0;age<=0;end
 else begin
  command_valid<=0;
  if(byte_valid)begin
   age<=0;
   case(index)
    0:if(byte_data==8'ha5)index<=1;
    1:if(byte_data==8'h5a)begin index<=2;crc<=16'hffff;end else index<=byte_data==8'ha5 ? 1 : 0;
    2:if(byte_data==8'h11)begin crc<=db_crc16_byte(16'hffff,byte_data);index<=3;end else index<=0;
    3,4,5,6:begin selection[(index-3)*8+:8]<=byte_data;crc<=db_crc16_byte(crc,byte_data);index<=index+1'b1;end
    7:begin crc_low<=byte_data;index<=8;end
    8:begin index<=0;if({byte_data,crc_low}==crc)begin control_word<=selection;command_valid<=1;end end
    default:index<=0;
   endcase
  end else if(index!=0)begin if(age==DIV*30)begin index<=0;age<=0;end else age<=age+1'b1;end
 end
endmodule
