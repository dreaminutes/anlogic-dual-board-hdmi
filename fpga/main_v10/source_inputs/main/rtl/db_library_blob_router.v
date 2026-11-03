`timescale 1ns/1ps
// Consumes only already-CRC-committed file packets. An accepted BEGIN owns
// a file stream until exact size/offset END; partial files never publish.
module db_library_blob_router(
 input clk,rst,session_ready,input[31:0]armed_epoch,
 input packet_valid,input[7:0]packet_type,packet_flags,input[31:0]packet_frame,
 input[15:0]packet_sequence,packet_length,output reg packet_take,
 output reg[10:0]read_address,input[7:0]read_data,
 output fifo_write,output[33:0]fifo_data,input fifo_full,output reg failed
);
 localparam IDLE=0,PRIME=1,READ=2,CHECK=3,BEGIN=4,META=5,DATA_PRIME=6,DATA_READ=7,WORD=8,END=9,RELEASE=10;
 reg[3:0]state;reg[7:0]kind;reg[31:0]frame,held_frame,size,offset;
 reg[255:0]header;reg[5:0]at,limit;reg[2:0]mi;
 reg[10:0]data_index,data_length;reg[1:0]lane;reg[31:0]word_hold;reg live,audio_live,audio_packet;
 assign fifo_write=!rst&&!fifo_full&&(state==BEGIN||state==META||state==WORD||state==END);
 assign fifo_data=state==BEGIN?{2'b01,frame}:state==META?{2'b11,header[mi*32+:32]}:state==END?{2'b10,offset}:{2'b00,word_hold};
 task reject;begin failed<=1;live<=0;packet_take<=1;state<=RELEASE;end endtask
 always@(posedge clk or posedge rst)
 if(rst)begin state<=IDLE;kind<=0;frame<=0;held_frame<=0;size<=0;offset<=0;header<=0;at<=0;limit<=0;mi<=0;data_index<=0;data_length<=0;lane<=0;word_hold<=0;live<=0;audio_live<=0;audio_packet<=0;packet_take<=0;read_address<=0;failed<=0;end
 else begin
  packet_take<=0;
  case(state)
   IDLE:if(packet_valid)begin
    if(!session_ready||packet_flags!=8'h81||packet_sequence!=0||
      !(((packet_type==8'h30||packet_type==8'h33)&&packet_length==32)||((packet_type==8'h31||packet_type==8'h34)&&packet_length>8&&packet_length<=1032)||((packet_type==8'h32||packet_type==8'h35)&&packet_length==12)))reject;
    else begin kind<=packet_type>=8'h33 ?packet_type-8'd3:packet_type;audio_packet<=packet_type>=8'h33;frame<=packet_frame;header<=0;at<=0;limit<=(packet_type==8'h30||packet_type==8'h33)?32:(packet_type==8'h31||packet_type==8'h34)?8:12;read_address<=0;state<=PRIME;end
   end
   PRIME:begin read_address<=1;state<=READ;end
   READ:begin
    header[at*8+:8]<=read_data;
    if(at+1==limit)state<=CHECK;else begin at<=at+1'b1;read_address<=at+2;end
   end
   CHECK:if(header[31:0]!=armed_epoch)reject;
    else if(kind==8'h30)begin
     if(live||!frame[31]||(audio_packet?(header[223:192]!=32'h31445541||header[95:64]<4||header[95:64]>4063232||header[65:64]!=0):(header[95:64]<54||header[127:112]==0||header[111:96]==0||header[255:224]==0||header[223:193]!=0||header[223:192]==32'h31445541)))reject;
     else begin live<=1;audio_live<=audio_packet;held_frame<=frame;size<=header[95:64];offset<=0;mi<=0;state<=BEGIN;end
    end else if(!live||frame!=held_frame||audio_live!=audio_packet)reject;
    else if(kind==8'h31)begin
     if(header[63:32]!=offset||packet_length-8>size-offset||(packet_length-8)%4!=0&&packet_length-8!=size-offset)reject;
     else begin data_length<=packet_length-8;data_index<=0;lane<=0;word_hold<=0;read_address<=8;state<=DATA_PRIME;end
    end else if(offset!=size||header[63:32]!=size||header[95:64]!=0)reject;
    else state<=END;
   BEGIN:if(fifo_write)state<=META;
   META:if(fifo_write)begin if(mi==7)begin packet_take<=1;state<=RELEASE;end else mi<=mi+1'b1;end
   DATA_PRIME:begin read_address<=data_index+9;state<=DATA_READ;end
   DATA_READ:begin
    word_hold[lane*8+:8]<=read_data;
    if(lane==3||data_index+1==data_length)begin data_index<=data_index+1'b1;state<=WORD;end
    else begin data_index<=data_index+1'b1;lane<=lane+1'b1;read_address<=data_index+10;end
   end
   WORD:if(fifo_write)begin
    lane<=0;word_hold<=0;
    if(data_index==data_length)begin offset<=offset+data_length;packet_take<=1;state<=RELEASE;end
    else begin read_address<=data_index+8;state<=DATA_PRIME;end
   end
   END:if(fifo_write)begin live<=0;packet_take<=1;state<=RELEASE;end
   RELEASE:if(!packet_valid)state<=IDLE;
   default:reject;
  endcase
 end
endmodule
