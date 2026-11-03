`timescale 1ns/1ps
// Versioned media diagnostic with four queued words overlapping read latency. Acquire a
// lease, read its immutable 32-byte metadata, HELLO03/BEGIN13/LINE11/END12 flags81,
// then release only after END+CRC has physically launched and settled.
module db_start24_media_sender #(parameter[15:0]FRAME_GAP_CYCLES=16)(
 input wire link_clk,rst,session_confirmed,output reg hello_retry,output reg[31:0]frame_id,output reg failed,
 output wire descriptor_valid,input wire descriptor_ready,output wire[7:0]kind,
 output wire[15:0]length,sequence_number,output wire[31:0]wire_frame,
 output wire payload_valid,input wire payload_ready,output reg[7:0]payload,input wire done,
 output wire read_req,input wire read_ready,read_done,output wire[20:0]read_address,input wire[31:0]read_data
);
 localparam HELLO=0,BEGIN_FRAME=1,LINE=2,END_FRAME=3,FRAME_GAP=4,SNAPSHOT=5,RELEASE_FRAME=6,METADATA=7,HALT=8,HELLO_WAIT=9;
 reg[3:0]phase;reg active,snapshot_ready,release_ready,metadata_ready;reg[1:0]end_settle;
 reg[10:0]byte_index;reg[15:0]row_index,gap;reg[3:0]meta_index;reg[255:0]metadata;
 assign kind=phase==HELLO?8'h03:phase==BEGIN_FRAME?8'h13:phase==LINE?8'h11:8'h12;
 assign length=phase==LINE?16'd1284:phase==BEGIN_FRAME?16'd32:16'd12;
 reg[2:0]queue_count;reg[8:0]words_requested;

 assign descriptor_valid=!active&&(phase==HELLO||phase==BEGIN_FRAME||(phase==LINE&&queue_count!=0)||phase==END_FRAME);
 wire[10:0]pixel_offset=byte_index-11'd4;
 reg read_active,queue_error;
 reg[31:0]word_queue[0:3];reg[1:0]read_pointer,write_pointer;
 wire[31:0]word_buffer=word_queue[read_pointer];
 wire payload_available=active&&(phase!=LINE||byte_index<4||queue_count!=0);
 wire pop_word=payload_available&&payload_ready&&phase==LINE&&byte_index>=4&&pixel_offset[1:0]==3;
 wire push_word=read_done&&read_active&&phase==LINE;
 assign read_req=(phase==SNAPSHOT&&!snapshot_ready&&!read_active)||
  (phase==METADATA&&!metadata_ready&&!read_active)||
  (phase==RELEASE_FRAME&&end_settle==0&&!release_ready&&!read_active)||
  (phase==LINE&&words_requested<320&&queue_count<4&&!read_active);
 assign read_address=phase==SNAPSHOT?21'h100000:phase==RELEASE_FRAME?21'h080000:
  phase==METADATA?{17'h04000,meta_index}:{3'd0,row_index[8:0],words_requested};
 always @(posedge link_clk or posedge rst)begin
  if(rst)begin
   read_active<=0;queue_error<=0;snapshot_ready<=0;release_ready<=0;metadata_ready<=0;meta_index<=0;metadata<=0;
   read_pointer<=0;write_pointer<=0;queue_count<=0;words_requested<=0;
  end else begin
   if(read_req&&read_ready)begin read_active<=1;if(phase==LINE)words_requested<=words_requested+1'b1;end
   if(read_done)begin
    read_active<=0;
    if(!read_active)queue_error<=1;
    if(phase==SNAPSHOT)snapshot_ready<=1;
    else if(phase==RELEASE_FRAME)release_ready<=1;
    else if(phase==METADATA)begin metadata[meta_index*32+:32]<=read_data;if(meta_index==7)metadata_ready<=1;else meta_index<=meta_index+1'b1;end
    else if(phase!=LINE)queue_error<=1;
   end
   if(push_word)begin
    if(queue_count==4&&!pop_word)queue_error<=1;
    word_queue[write_pointer]<=read_data;write_pointer<=write_pointer+1'b1;
   end
   if(pop_word)read_pointer<=read_pointer+1'b1;
   case({push_word,pop_word})
    2'b10:queue_count<=queue_count+1'b1;
    2'b01:queue_count<=queue_count-1'b1;
   endcase
   if(done&&phase==LINE)begin
    if(queue_count!=0||read_active||words_requested!=320)queue_error<=1;
    read_pointer<=0;write_pointer<=0;queue_count<=0;words_requested<=0;
   end
   if(phase==FRAME_GAP)begin snapshot_ready<=0;release_ready<=0;metadata_ready<=0;meta_index<=0;end
  end
 end
 always @*begin
  payload=0;
  if(phase==BEGIN_FRAME)payload=metadata[byte_index*8+:8];
  else if(byte_index<4)payload=phase==HELLO?(byte_index==0?8'd1:8'd0):metadata[byte_index*8+:8];
  else if(phase==LINE)case(pixel_offset[1:0])
   0:payload=word_buffer[7:0];1:payload=word_buffer[15:8];2:payload=word_buffer[23:16];3:payload=word_buffer[31:24];
  endcase
  else if(phase==HELLO)case(byte_index)
   4:payload=8'h80;5:payload=2;6:payload=8'he0;7:payload=1;8:payload=1;9:payload=4;10:payload=15;default:payload=0;
  endcase
  else if(phase==END_FRAME)case(byte_index)
   4:payload=8'he0;5:payload=1;9:payload=8'h60;10:payload=9;default:payload=0;
  endcase
 end
 assign payload_valid=payload_available;
 assign wire_frame=phase==HELLO?32'd0:frame_id;assign sequence_number=phase==LINE?row_index:16'd0;
 always @(posedge link_clk or posedge rst)begin
  if(rst)begin phase<=HELLO;active<=0;byte_index<=0;row_index<=0;frame_id<=1;gap<=0;end_settle<=0;failed<=0;hello_retry<=0;end
  else begin
   hello_retry<=0;


   if(phase==RELEASE_FRAME&&end_settle!=0)end_settle<=end_settle-1'b1;
   if(descriptor_valid&&descriptor_ready)begin active<=1;byte_index<=0;end
   if(payload_available&&payload_ready)byte_index<=byte_index+1'b1;
   if(done)begin active<=0;
    case(phase)
     HELLO:begin phase<=HELLO_WAIT;gap<=16'hffff;end
     BEGIN_FRAME:begin row_index<=0;phase<=LINE;end
     LINE:if(row_index==479)phase<=END_FRAME;else row_index<=row_index+1'b1;
     END_FRAME:begin phase<=RELEASE_FRAME;end_settle<=2;end
    endcase
   end
   // No lease acquisition or PCM before the main's existing return wire
   // confirms semantic HELLO acceptance. Reuse the existing16-bit gap timer.
   if(phase==HELLO_WAIT)begin
    if(session_confirmed)phase<=SNAPSHOT;
    else if(gap==0)begin hello_retry<=1;phase<=HELLO;end
    else gap<=gap-1'b1;
   end
   if(phase==SNAPSHOT&&snapshot_ready)phase<=METADATA;
   if(phase==METADATA&&metadata_ready)begin
    if(metadata[31:0]!=1||metadata[47:32]!=640||metadata[63:48]!=480||metadata[71:64]!=1||metadata[79:72]>2||metadata[95:80]!=0||metadata[223:192]==0||metadata[255:224]!=614400)begin failed<=1;phase<=HALT;end
    else phase<=BEGIN_FRAME;
   end
   if(phase==RELEASE_FRAME&&release_ready)begin gap<=FRAME_GAP_CYCLES;phase<=FRAME_GAP;end
   if(phase==FRAME_GAP)begin if(gap==0)begin frame_id<=frame_id+1'b1;phase<=SNAPSHOT;end else gap<=gap-1'b1;end
   if(queue_error)begin failed<=1;phase<=HALT;active<=0;end
  end
 end
endmodule
