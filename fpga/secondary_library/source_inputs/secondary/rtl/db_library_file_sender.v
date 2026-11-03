`timescale 1ns/1ps
module db_library_file_sender(
 input clk,rst,input[33:0]fifo_data,input fifo_empty,output fifo_read,
 output descriptor_valid,input descriptor_ready,output[7:0]packet_type,
 output[31:0]frame_id,output[15:0]payload_length,
 output payload_valid,input payload_ready,output[7:0]payload_data,input packet_done,
 output reg finish_toggle,failed
);
 localparam IDLE=0,META=1,DESC=2,PAYLOAD=3,DONE=4,FILL=5,FETCH=6,LATCH=7,BYTE=8,ENDTOKEN=9;
 reg[3:0]state;reg[2:0]mi;reg[31:0]epoch;reg is_audio;
 reg[31:0]frame,offset,size;reg[10:0]amount,index;
 reg[8:0]words;reg[1:0]kind;reg[31:0]ram[0:255],q;
 wire[31:0]remaining=size-offset;
 assign fifo_read=!rst&&!fifo_empty&&(state==IDLE||state==META||state==FILL||state==ENDTOKEN);
 wire[10:0]data_index=index-11'd8;
 wire[7:0]ram_read_address=kind==0?{5'd0,index[4:2]}:data_index[9:2];
 // BEGIN metadata and later DATA chunks never coexist: reuse the same BRAM.
 always@(posedge clk)begin
  if((state==META||state==FILL)&&fifo_read)ram[state==META?{5'd0,mi}:words[7:0]]<=fifo_data[31:0];
  q<=ram[ram_read_address];
 end
 assign descriptor_valid=state==DESC;
 assign packet_type=kind==0?(is_audio?8'h33:8'h30):kind==1?(is_audio?8'h34:8'h31):(is_audio?8'h35:8'h32);
 assign frame_id=frame;
 assign payload_length=kind==0?16'd32:kind==1?amount+16'd8:16'd12;
 assign payload_valid=state==PAYLOAD||state==BYTE;
 wire[95:0]ending={32'd0,size,epoch};
 wire[63:0]prefix={offset,epoch};
 assign payload_data=kind==0?q[index[1:0]*8+:8]:kind==2?ending[index*8+:8]:index<8?prefix[index*8+:8]:q[((index-8)&3)*8+:8];
 always@(posedge clk or posedge rst)
 if(rst)begin state<=IDLE;mi<=0;epoch<=0;is_audio<=0;frame<=0;offset<=0;size<=0;amount<=0;index<=0;words<=0;kind<=0;finish_toggle<=0;failed<=0;end
 else case(state)
  IDLE:if(fifo_read)begin if(fifo_data[33:32]!=1)failed<=1;else begin frame<=fifo_data[31:0];mi<=0;offset<=0;state<=META;end end
  META:if(fifo_read)begin
   if(fifo_data[33:32]!=3)failed<=1;
   if(mi==0)epoch<=fifo_data[31:0];if(mi==2)size<=fifo_data[31:0];if(mi==6)is_audio<=fifo_data[31:0]==32'h31445541;
   if(mi==7)begin kind<=0;index<=0;state<=DESC;end else mi<=mi+1'b1;
  end
  DESC:if(descriptor_ready)begin index<=0;state<=kind==0?FETCH:PAYLOAD;end
  PAYLOAD:if(payload_valid&&payload_ready)begin
   if(index+1==payload_length)state<=DONE;
   else begin index<=index+1'b1;if(kind==1&&index==7)state<=FETCH;end
  end
  FETCH:state<=LATCH;
  LATCH:state<=BYTE;
  // RAM q holds all four bytes. Only fetch again at a word boundary;
  // stalls within a word retain q/index and preserve exact packet bytes.
  BYTE:if(payload_ready)begin if(index+1==payload_length)state<=DONE;else begin index<=index+1'b1;if(index[1:0]==3)state<=FETCH;end end
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
