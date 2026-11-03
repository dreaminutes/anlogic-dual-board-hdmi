`timescale 1ns/1ps
// Arbitrary-length BMP byte stream into a bounded asynchronous word FIFO.
// Metadata: epoch,asset,size,{height,width},offset,stride,top_down,duration.
// Frame IDs use the separate high-bit namespace; no whole-file RAM exists.
module db_full_file_source(
 input clk,rst,start,input[255:0]metadata,input byte_valid,input[7:0]byte_data,
 output byte_ready,output reg busy,done,failed,
 output fifo_write,output[33:0]fifo_data,input fifo_full,
 input finish_toggle
);
 localparam IDLE=0,BEGIN=1,META=2,DATA=3,FLUSH=4,END=5,WAIT=6;
 reg[2:0]state,index;reg[255:0]held;reg[31:0]position,word_hold,frame_number;
 reg[1:0]lane;reg finish_seen;(* async_reg="true" *)reg[2:0]finish_sync;
 assign fifo_write=!rst&&!fifo_full&&(state==BEGIN||state==META||state==FLUSH||state==END);
 assign fifo_data=state==BEGIN?{2'b01,1'b1,frame_number[30:0]}:
  state==META?{2'b11,held[index*32+:32]}:state==END?{2'b10,position}:{2'b00,word_hold};
 assign byte_ready=!rst&&state==DATA&&position<held[95:64];
 always@(posedge clk or posedge rst)
 if(rst)begin state<=IDLE;index<=0;held<=0;position<=0;word_hold<=0;frame_number<=0;lane<=0;busy<=0;done<=0;failed<=0;finish_seen<=0;finish_sync<=0;end
 else begin
  finish_sync<={finish_sync[1:0],finish_toggle};done<=0;
  case(state)
   IDLE:if(start)begin held<=metadata;position<=0;word_hold<=0;lane<=0;index<=0;busy<=1;failed<=0;finish_seen<=finish_sync[2];state<=BEGIN;end
   BEGIN:if(fifo_write)state<=META;
   META:if(fifo_write)begin if(index==7)state<=DATA;else index<=index+1'b1;end
   DATA:if(byte_valid&&byte_ready)begin
    word_hold[lane*8+:8]<=byte_data;position<=position+1'b1;
    if(lane==3||position+1==held[95:64])state<=FLUSH;else lane<=lane+1'b1;
   end
   FLUSH:if(fifo_write)begin lane<=0;word_hold<=0;state<=position==held[95:64]?END:DATA;end
   END:if(fifo_write)state<=WAIT;
   WAIT:if(finish_sync[2]!=finish_seen)begin busy<=0;done<=1;frame_number<=frame_number+1'b1;state<=IDLE;end
   default:begin failed<=1;busy<=0;state<=IDLE;end
  endcase
 end
endmodule

// FIFO tokens become CRC-protected BEGIN30 / DATA31 / END32 records. DATA
// carries epoch+32bit byte offset; each chunk is <=1024 bytes and can stall.
module db_full_file_sender(
 input clk,rst,input[33:0]fifo_data,input fifo_empty,output fifo_read,
 output descriptor_valid,input descriptor_ready,output[7:0]packet_type,
 output[31:0]frame_id,output[15:0]payload_length,
 output payload_valid,input payload_ready,output[7:0]payload_data,input packet_done,
 output reg finish_toggle,failed
);
 localparam IDLE=0,META=1,DESC=2,PAYLOAD=3,DONE=4,FILL=5,FETCH=6,LATCH=7,BYTE=8,ENDTOKEN=9;
 reg[3:0]state;reg[2:0]mi;reg[255:0]metadata;
 reg[31:0]frame,offset,size;reg[10:0]amount,index;
 reg[8:0]words;reg[1:0]kind;reg[31:0]ram[0:255],q;
 wire[31:0]remaining=size-offset;
 assign fifo_read=!rst&&!fifo_empty&&(state==IDLE||state==META||state==FILL||state==ENDTOKEN);
 always@(posedge clk)begin
  if(state==FILL&&fifo_read)ram[words[7:0]]<=fifo_data[31:0];
  q<=ram[(index-11'd8)>>2];
 end
 assign descriptor_valid=state==DESC;
 assign packet_type=kind==0?8'h30:kind==1?8'h31:8'h32;
 assign frame_id=frame;
 assign payload_length=kind==0?16'd32:kind==1?amount+16'd8:16'd12;
 assign payload_valid=state==PAYLOAD||state==BYTE;
 wire[95:0]ending={32'd0,size,metadata[31:0]};
 wire[63:0]prefix={offset,metadata[31:0]};
 assign payload_data=kind==0?metadata[index*8+:8]:kind==2?ending[index*8+:8]:index<8?prefix[index*8+:8]:q[((index-8)&3)*8+:8];
 always@(posedge clk or posedge rst)
 if(rst)begin state<=IDLE;mi<=0;metadata<=0;frame<=0;offset<=0;size<=0;amount<=0;index<=0;words<=0;kind<=0;finish_toggle<=0;failed<=0;end
 else case(state)
  IDLE:if(fifo_read)begin if(fifo_data[33:32]!=1)failed<=1;else begin frame<=fifo_data[31:0];mi<=0;offset<=0;state<=META;end end
  META:if(fifo_read)begin
   if(fifo_data[33:32]!=3)failed<=1;
   metadata[mi*32+:32]<=fifo_data[31:0];if(mi==2)size<=fifo_data[31:0];
   if(mi==7)begin kind<=0;index<=0;state<=DESC;end else mi<=mi+1'b1;
  end
  DESC:if(descriptor_ready)begin index<=0;state<=PAYLOAD;end
  PAYLOAD:if(payload_valid&&payload_ready)begin
   if(index+1==payload_length)state<=DONE;
   else begin index<=index+1'b1;if(kind==1&&index==7)state<=FETCH;end
  end
  FETCH:state<=LATCH;
  LATCH:state<=BYTE;
  BYTE:if(payload_ready)begin if(index+1==payload_length)state<=DONE;else begin index<=index+1'b1;state<=FETCH;end end
  DONE:if(packet_done)begin
   if(kind==2)begin finish_toggle<=~finish_toggle;state<=IDLE;end
   else if(kind==1)begin offset<=offset+amount;state<=offset+amount==size?ENDTOKEN:FILL;words<=0;end
   else begin words<=0;state<=size==0?ENDTOKEN:FILL;end
  end
  FILL:if(fifo_read)begin
   if(fifo_data[33:32]!=0)failed<=1;
   if((words+1)*4>=remaining||words==255)begin amount<=remaining<1024?remaining[10:0]:11'd1024;index<=0;kind<=1;state<=DESC;end
   else words<=words+1'b1;
  end
  ENDTOKEN:if(fifo_read)begin if(fifo_data[33:32]!=2||fifo_data[31:0]!=size)failed<=1;kind<=2;index<=0;state<=DESC;end
  default:state<=IDLE;
 endcase
endmodule
