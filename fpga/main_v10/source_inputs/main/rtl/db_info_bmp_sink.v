`timescale 1ns/1ps
`include "db_media_metadata.vh"
// Stream from committed file packets into the original BMP decoder/scaler.
// Arbitrary addressed writes remain in the allocated, non-displayed slot.
// END and actual decoder+scaler+write retirement authorize whole-frame commit.
module db_info_bmp_sink(
 output wire[31:0] source_size,
 input clk,rst,input[33:0]fifo_data,input fifo_empty,output fifo_read,
 output metadata_valid,input metadata_ready,output[193:0]metadata,
 input[20:0]target_base,input[1:0]target_slot,
 output mem_req,mem_write,output[20:0]mem_address,output[31:0]mem_data,
 input mem_ready,writes_idle,output whole_complete,end_valid,input end_ready,
 output[31:0]end_frame,end_epoch,output busy,output reg failed
);
 localparam IDLE=0,META=1,BEGIN=2,START=3,BYTES=4,WAIT=5,COMPLETE=6,END=7;
 reg[2:0]state,mi;reg[255:0]held;reg[31:0]frame,position,word_hold;
 reg[1:0]lane;reg word_valid,producer_done;
 wire producer_ready,producer_busy,producer_failed,done,alloc_valid,commit_valid,drained;
 wire byte_valid=state==BYTES&&word_valid&&position<held[95:64];
 assign fifo_read=!rst&&!fifo_empty&&(state==IDLE||state==META||(state==BYTES&&!word_valid));
 assign source_size={held[111:96],held[127:112]};
 assign metadata_valid=state==BEGIN;
 assign metadata={2'd0,held[31:0],frame,held[63:32],32'd0,32'd0,held[255:224]};
 assign whole_complete=state==COMPLETE&&drained;
 assign end_valid=state==END&&drained;
 assign end_frame=frame;assign end_epoch=held[31:0];assign busy=state!=IDLE;
 // One register entry separates scaler control from SDRAM/row admission.
 // Completion waits for the queue and all physical writes to drain.
 wire dec_req,dec_write;wire[20:0]dec_address;wire[31:0]dec_data;
 reg queued;reg[20:0]queued_address;reg[31:0]queued_data;
 wire dec_ready=!queued;assign drained=writes_idle&&!queued;
 assign mem_req=queued;assign mem_write=1'b1;
 assign mem_address=queued_address;assign mem_data=queued_data;
 always@(posedge clk or posedge rst)
  if(rst)begin queued<=0;queued_address<=0;queued_data<=0;end
  else begin
   if(queued&&mem_ready)queued<=0;
   if(dec_req&&dec_ready)begin queued<=1;queued_address<=dec_address;queued_data<=dec_data;end
  end
 wire[31:0]aepoch,aasset,aframe,apts,aduration,ctoken;wire[1:0]akind,cs;
 db_opt_bmp_producer decoder(.clk(clk),.rst(rst),.cancel(1'b0),.start(state==START),.epoch(held[31:0]),.asset(held[63:32]),
  .width(held[111:96]),.height(held[127:112]),.top_down(held[192]),.file_size(held[95:64]),.pixel_offset(held[159:128]),.row_stride(held[191:160]),
  .byte_valid(byte_valid),.byte_data(word_hold[lane*8+:8]),.byte_ready(producer_ready),
  .alloc_valid(alloc_valid),.alloc_static(),.alloc_kind(akind),.alloc_epoch(aepoch),.alloc_asset(aasset),.alloc_frame(aframe),.alloc_pts(apts),.alloc_duration(aduration),
  .alloc_ready(1'b1),.alloc_slot(target_slot),.alloc_token(32'd1),.alloc_base(target_base),
  .commit_valid(commit_valid),.commit_static(),.commit_slot(cs),.commit_token(ctoken),.commit_ready(1'b1),
  .mem_req(dec_req),.mem_write(dec_write),.mem_address(dec_address),.mem_data(dec_data),.mem_ready(dec_ready),.writes_idle(drained),
  .busy(producer_busy),.done(done),.failed(producer_failed),.error_code());
 always@(posedge clk or posedge rst)
 if(rst)begin state<=IDLE;mi<=0;held<=0;frame<=0;position<=0;word_hold<=0;lane<=0;word_valid<=0;producer_done<=0;failed<=0;end
 else begin
  if(producer_failed)failed<=1;
  if(done)producer_done<=1;
  case(state)
   IDLE:if(fifo_read)begin
    if(fifo_data[33:32]!=1)failed<=1;
    else begin frame<=fifo_data[31:0];mi<=0;position<=0;lane<=0;word_valid<=0;producer_done<=0;state<=META;end
   end
   META:if(fifo_read)begin
    if(fifo_data[33:32]!=3)failed<=1;
    held[mi*32+:32]<=fifo_data[31:0];if(mi==7)state<=BEGIN;else mi<=mi+1'b1;
   end
   BEGIN:if(metadata_ready)state<=START;
   START:state<=BYTES;
   BYTES:begin
    if(fifo_read)begin
     if(fifo_data[33:32]==0&&position<held[95:64])begin word_hold<=fifo_data[31:0];lane<=0;word_valid<=1;end
     else if(fifo_data[33:32]==2&&position==held[95:64]&&fifo_data[31:0]==position)state<=WAIT;
     else failed<=1;
    end
    if(byte_valid&&producer_ready)begin
     position<=position+1'b1;
     if(lane==3||position+1==held[95:64])word_valid<=0;else lane<=lane+1'b1;
    end
   end
   WAIT:if(producer_done&&drained)state<=COMPLETE;
   COMPLETE:if(drained)state<=END;
   END:if(end_ready)state<=IDLE;
  endcase
 end
endmodule
