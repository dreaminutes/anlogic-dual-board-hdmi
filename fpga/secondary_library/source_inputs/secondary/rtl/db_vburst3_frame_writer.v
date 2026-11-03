`timescale 1ns/1ps
// Common complete-raster producer port for GIF scaler, raw-video reader or BMP.
// One word = two RGB565 pixels, lower half-word is the earlier raster pixel.
// last must accompany exactly word 153599. Malformed frames are NEVER committed;
// the supervisor must cancel the ownership core and this writer together.
module db_vburst3_frame_writer #(
 parameter[17:0]FRAME_WORDS=18'd153600
)(
 input wire clk,rst,cancel,
 input wire start_valid,output wire start_ready,input wire start_static,input wire[1:0]start_kind,
 input wire[31:0]start_epoch,start_asset,start_frame,start_pts,start_duration,
 input wire word_valid,output wire word_ready,input wire[31:0]word_data,input wire word_last,
 output wire alloc_valid,output wire alloc_static,output wire[1:0]alloc_kind,
 output wire[31:0]alloc_epoch,alloc_asset,alloc_frame,alloc_pts,alloc_duration,
 input wire alloc_ready,input wire[1:0]alloc_slot,input wire[31:0]alloc_token,input wire[20:0]alloc_base,
 output wire commit_valid,output wire commit_static,output wire[1:0]commit_slot,output wire[31:0]commit_token,input wire commit_ready,
 output wire mem_req,mem_write,output wire[20:0]mem_address,output wire[31:0]mem_data,input wire mem_ready,writes_idle,
 output reg done,failed,output wire busy
);

 localparam IDLE=0,ALLOC=1,DATA=2,DRAIN=3,COMMIT=4,FAULT=5;
 reg[2:0]state;reg is_static;reg[1:0]kind,slot;reg[31:0]epoch,asset,frame,pts,duration,token;
 reg[20:0]base;reg[17:0]index,write_index;
 reg[3:0]head,tail;reg[4:0]count;reg[31:0]words[0:15];
 wire buffered=count!=0;wire[31:0]buffer_data=words[head];wire[20:0]held_address=base+write_index;
 wire[21:0]end_address={1'b0,alloc_base}+FRAME_WORDS;
 assign start_ready=!rst&&!cancel&&state==IDLE;
 assign busy=state!=IDLE;
 assign alloc_valid=!rst&&!cancel&&state==ALLOC;
 assign alloc_static=is_static;assign alloc_kind=kind;
 assign alloc_epoch=epoch;assign alloc_asset=asset;assign alloc_frame=frame;assign alloc_pts=pts;assign alloc_duration=duration;
 assign commit_valid=!rst&&!cancel&&state==COMMIT;
 assign commit_static=is_static;assign commit_slot=slot;assign commit_token=token;
 assign mem_req=!rst&&!cancel&&buffered&&(state==DATA||state==DRAIN);
 assign mem_write=1'b1;assign mem_address=held_address;assign mem_data=buffer_data;
 // Conservative full handling cuts memory-ready feedback into input CRC/header logic.
 wire pop=mem_req&&mem_ready;
 assign word_ready=!rst&&!cancel&&state==DATA&&count<16;
 wire word_ok=(word_last==(index==FRAME_WORDS-1'b1));
 wire push=word_valid&&word_ready&&word_ok;
 // RAM contents are never reset; only valid count/pointers grant access.
 always@(posedge clk)if(push)words[tail]<=word_data;
 always@(posedge clk or posedge rst)begin
  if(rst)begin
   state<=IDLE;is_static<=0;kind<=0;slot<=0;epoch<=0;asset<=0;frame<=0;pts<=0;duration<=0;token<=0;base<=0;
   index<=0;write_index<=0;head<=0;tail<=0;count<=0;done<=0;failed<=0;
  end else begin
   done<=0;
   if(cancel)begin state<=IDLE;head<=0;tail<=0;count<=0;index<=0;write_index<=0;failed<=0;end
   else begin
    if(push)tail<=tail+1'b1;
    if(pop)begin head<=head+1'b1;write_index<=write_index+1'b1;end
    case({push,pop})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;endcase
    case(state)
     IDLE:if(start_valid&&start_ready)begin
      is_static<=start_static;kind<=start_kind;epoch<=start_epoch;asset<=start_asset;frame<=start_frame;pts<=start_pts;duration<=start_duration;failed<=0;state<=ALLOC;
     end
     ALLOC:if(alloc_valid&&alloc_ready)begin
      slot<=alloc_slot;token<=alloc_token;base<=alloc_base;index<=0;write_index<=0;head<=0;tail<=0;count<=0;
      if(FRAME_WORDS==0||end_address>22'd2097152)begin failed<=1;state<=FAULT;end else state<=DATA;
     end
     DATA:if(word_valid&&word_ready)begin
      if(!word_ok)begin failed<=1;count<=0;head<=0;tail<=0;state<=FAULT;end
      else if(word_last)state<=DRAIN;else index<=index+1'b1;
     end
     DRAIN:if(count==0&&writes_idle)state<=COMMIT;
     COMMIT:if(commit_valid&&commit_ready)begin done<=1;state<=IDLE;end
     FAULT:state<=FAULT;
     default:begin state<=FAULT;failed<=1;end
    endcase
   end
  end
 end
endmodule
