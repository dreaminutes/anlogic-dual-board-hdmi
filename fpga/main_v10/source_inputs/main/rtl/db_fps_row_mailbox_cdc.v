`timescale 1ns/1ps
// Two ordered row mailboxes. Each request/ack bit is an independent toggle,
// not a binary counter. Payload RAM and bundled descriptors remain immutable
// from request publication until that bank's acknowledgement returns.
// arst is a SHARED flush: assert into both domains and the upstream packet RX.
module db_fps_row_mailbox_cdc #(parameter WIDTH=640,HEIGHT=480)(
 input wire src_clk,dst_clk,arst,
 output wire src_reset_active,dst_reset_active,
 input wire row_packet_valid,output reg row_packet_take,
 input wire [31:0] packet_epoch,packet_frame_id,
 input wire [15:0] packet_row,packet_length,
 output reg [10:0] packet_read_address,input wire [7:0] packet_read_data,input wire[31:0]packet_word_data,
 output wire src_idle,output reg [31:0] discarded_packets,
 output reg row_valid,input wire row_take,
 output reg [31:0] row_epoch,row_frame_id,
 output reg [15:0] row_index,row_length,
 input wire [8:0] row_read_address,output reg [31:0] row_read_data
);
 localparam ROW_BYTES=WIDTH*2;
 localparam IDLE=0,PRIME=1,COPY=2,RELEASE=3;
 (* async_reg="true" *) reg [2:0] src_release,dst_release;
 always @(posedge src_clk or posedge arst)
  if(arst)src_release<=3'b111;else src_release<={src_release[1:0],1'b0};
 always @(posedge dst_clk or posedge arst)
  if(arst)dst_release<=3'b111;else dst_release<={dst_release[1:0],1'b0};
 assign src_reset_active=src_release[2];
 assign dst_reset_active=dst_release[2];
 reg [1:0] requests,acks;
 (* async_reg="true" *) reg [1:0] ack0,ack1,ack2,req0,req1,req2;
 always @(posedge src_clk or posedge src_reset_active)
  if(src_reset_active)begin ack0<=0;ack1<=0;ack2<=0;end
  else begin ack0<=acks;ack1<=ack0;ack2<=ack1;end
 always @(posedge dst_clk or posedge dst_reset_active)
  if(dst_reset_active)begin req0<=0;req1<=0;req2<=0;end
  else begin req0<=requests;req1<=req0;req2<=req1;end
 reg [1:0] state;
 reg src_bank,dst_bank;
 reg [10:0] byte_index;
 reg [23:0] low_bytes;
 reg [95:0] held0,held1;
 reg [31:0] row_ram[0:1023] /* fehdl force_ram=1, ram_style="bram" */;
 // Plain dual-clock, registered-read RAM. No reset/clear on the memory array.
 always @(posedge src_clk)
  if(!src_reset_active&&state==COPY&&row_packet_valid)
   row_ram[{src_bank,byte_index[10:2]}]<=packet_word_data;
 always @(posedge dst_clk)
  row_read_data<=row_ram[{dst_bank,row_read_address}];
 assign src_idle=!src_reset_active&&(state==IDLE)&&(requests==ack2)&&!row_packet_valid;
 always @(posedge src_clk or posedge src_reset_active)begin
  if(src_reset_active)begin
   state<=IDLE;src_bank<=0;requests<=0;byte_index<=0;low_bytes<=0;
   held0<=0;held1<=0;packet_read_address<=0;row_packet_take<=0;discarded_packets<=0;
  end else begin
   row_packet_take<=0;
   case(state)
    IDLE:if(row_packet_valid)begin
     if(packet_length!=ROW_BYTES||packet_row>=HEIGHT)begin
      row_packet_take<=1;discarded_packets<=discarded_packets+1'b1;state<=RELEASE;
     end else if(requests[src_bank]==ack2[src_bank])begin
      if(src_bank)held1<={packet_epoch,packet_frame_id,packet_row,packet_length};
      else held0<={packet_epoch,packet_frame_id,packet_row,packet_length};
      byte_index<=0;packet_read_address<=0;state<=PRIME;
     end
    end
    PRIME:begin packet_read_address<=4;state<=COPY;end
    COPY:if(!row_packet_valid)begin
     discarded_packets<=discarded_packets+1'b1;state<=IDLE;
    end else begin
     if(byte_index==ROW_BYTES-4)begin
      requests[src_bank]<=~requests[src_bank];src_bank<=~src_bank;
      row_packet_take<=1;state<=RELEASE;
     end else begin byte_index<=byte_index+4;packet_read_address<=byte_index+8;end
    end
    RELEASE:if(!row_packet_valid)state<=IDLE;
   endcase
  end
 end
 always @(posedge dst_clk or posedge dst_reset_active)begin
  if(dst_reset_active)begin
   acks<=0;dst_bank<=0;row_valid<=0;
   row_epoch<=0;row_frame_id<=0;row_index<=0;row_length<=0;
  end else if(row_valid)begin
   if(row_take)begin
    acks[dst_bank]<=req2[dst_bank];dst_bank<=~dst_bank;row_valid<=0;
   end
  end else if(req2[dst_bank]!=acks[dst_bank])begin
   if(dst_bank){row_epoch,row_frame_id,row_index,row_length}<=held1;
   else {row_epoch,row_frame_id,row_index,row_length}<=held0;
   row_valid<=1;
  end
 end
endmodule
