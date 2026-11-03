`timescale 1ns/1ps
// Fully buffer and validate one packet before exposing it to the consumer.
// in_valid bytes must already be safely captured in this local clock domain.
module db_fps_packet_rx #(parameter MAX_PAYLOAD=1280,parameter GAP_TIMEOUT=4096)(
 input wire clk,rst,input wire in_valid,input wire [7:0] in_data,
 output wire can_start,
 output reg packet_valid,input wire packet_take,
 output reg [7:0] packet_type,flags,
 output reg [31:0] frame_id,output reg [15:0] sequence_number,payload_length,
 input wire [10:0] read_address,output wire [7:0] read_data,output wire[31:0]read_word,
 output reg packet_committed,packet_dropped,
 output reg [31:0] crc_errors,format_errors,timeout_errors,busy_errors
);
 localparam SEARCH_A5=0,SEARCH_5A=1,HEADER=2,HEADER_LOW=3,HEADER_HIGH=4,
            PAYLOAD=5,CRC_LOW=6,CRC_HIGH=7;
 reg [2:0] state;
 reg [3:0] header_index;
 reg [15:0] header_crc,payload_crc,payload_index;
 reg [7:0] crc_low;
 reg [7:0] saved_version,saved_type,saved_flags,saved_reserved;
 reg [31:0] saved_frame;
 reg [15:0] saved_sequence,saved_length;
 localparam TIMEOUT_BITS=(GAP_TIMEOUT<2)?1:$clog2(GAP_TIMEOUT+1);
 reg [TIMEOUT_BITS-1:0] gap_count;
 // Use a power-of-two depth and a plain registered read for native BRAM mapping.
 // Validity masking lives outside the RAM output register; no RAM reset/clear.
 localparam RAM_DEPTH=1<<$clog2(MAX_PAYLOAD);
 reg [31:0] packet_ram[0:RAM_DEPTH/4-1] /* fehdl force_ram=1, ram_style="bram" */;
 reg [31:0] ram_read_word;reg[1:0]read_lane;reg[23:0]write_low;
 reg read_allowed;
 `include "db_crc16.vh"
 assign can_start=!packet_valid&&(state==SEARCH_A5||state==SEARCH_5A);
 assign read_data=read_allowed?ram_read_word[read_lane*8+:8]:8'd0;
 assign read_word=read_allowed?ram_read_word:32'd0;
 always @(posedge clk)begin
  ram_read_word<=packet_ram[read_address[10:2]];read_lane<=read_address[1:0];
  read_allowed<=!rst&&packet_valid&&(read_address<payload_length);
  if(!rst&&!packet_valid&&state==PAYLOAD&&in_valid)begin
   case(payload_index[1:0])
    0:write_low[7:0]<=in_data;
    1:write_low[15:8]<=in_data;
    2:write_low[23:16]<=in_data;
   endcase
   // A final partial word writes only meaningful bytes and zero padding;
   // packet validity and the old byte-length mask remain unchanged.
   if(payload_index[1:0]==3||payload_index+1'b1==saved_length)
    case(payload_index[1:0])
     0:packet_ram[payload_index[10:2]]<={24'd0,in_data};
     1:packet_ram[payload_index[10:2]]<={16'd0,in_data,write_low[7:0]};
     2:packet_ram[payload_index[10:2]]<={8'd0,in_data,write_low[15:0]};
     3:packet_ram[payload_index[10:2]]<={in_data,write_low};
    endcase
  end
 end
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   state<=SEARCH_A5;header_index<=0;header_crc<=16'hFFFF;payload_crc<=16'hFFFF;
   payload_index<=0;crc_low<=0;gap_count<=0;
   saved_version<=0;saved_type<=0;saved_flags<=0;saved_reserved<=0;
   saved_frame<=0;saved_sequence<=0;saved_length<=0;
   packet_valid<=0;packet_type<=0;flags<=0;frame_id<=0;sequence_number<=0;payload_length<=0;
   packet_committed<=0;packet_dropped<=0;
   crc_errors<=0;format_errors<=0;timeout_errors<=0;busy_errors<=0;
  end else begin
   packet_committed<=0;packet_dropped<=0;
   if(packet_valid)begin
    state<=SEARCH_A5;gap_count<=0;
    if(packet_take)packet_valid<=0;
    if(in_valid)begin busy_errors<=32'd1;packet_dropped<=1;end
   end else if(in_valid)begin
    gap_count<=0;
    case(state)
     SEARCH_A5:if(in_data==8'hA5)begin
      header_crc<=db_crc16_byte(16'hFFFF,in_data);state<=SEARCH_5A;
     end
     SEARCH_5A:begin
      if(in_data==8'h5A)begin
       header_crc<=db_crc16_byte(header_crc,in_data);header_index<=2;state<=HEADER;
      end else if(in_data==8'hA5)header_crc<=db_crc16_byte(16'hFFFF,in_data);
      else state<=SEARCH_A5;
     end
     HEADER:begin
      header_crc<=db_crc16_byte(header_crc,in_data);
      case(header_index)
       2:saved_version<=in_data;3:saved_type<=in_data;
       4:saved_frame[7:0]<=in_data;5:saved_frame[15:8]<=in_data;
       6:saved_frame[23:16]<=in_data;7:saved_frame[31:24]<=in_data;
       8:saved_sequence[7:0]<=in_data;9:saved_sequence[15:8]<=in_data;
       10:saved_length[7:0]<=in_data;11:saved_length[15:8]<=in_data;
       12:saved_flags<=in_data;13:saved_reserved<=in_data;
      endcase
      if(header_index==13)state<=HEADER_LOW;
      else header_index<=header_index+1'b1;
     end
     HEADER_LOW:begin crc_low<=in_data;state<=HEADER_HIGH;end
     HEADER_HIGH:begin
      if({in_data,crc_low}!=header_crc)begin
       crc_errors<=32'd1;packet_dropped<=1;state<=SEARCH_A5;
      end else if(saved_version!=1||saved_reserved!=0||saved_length>MAX_PAYLOAD)begin
       format_errors<=32'd1;packet_dropped<=1;state<=SEARCH_A5;
      end else begin
       payload_crc<=16'hFFFF;payload_index<=0;
       state<=(saved_length==0)?CRC_LOW:PAYLOAD;
      end
     end
     PAYLOAD:begin
      payload_crc<=db_crc16_byte(payload_crc,in_data);
      if(payload_index+1'b1==saved_length)state<=CRC_LOW;
      else payload_index<=payload_index+1'b1;
     end
     CRC_LOW:begin crc_low<=in_data;state<=CRC_HIGH;end
     CRC_HIGH:begin
      state<=SEARCH_A5;
      if({in_data,crc_low}!=payload_crc)begin crc_errors<=32'd1;packet_dropped<=1;end
      else begin
       packet_type<=saved_type;flags<=saved_flags;frame_id<=saved_frame;
       sequence_number<=saved_sequence;payload_length<=saved_length;
       packet_valid<=1;packet_committed<=1;
      end
     end
    endcase
   end else if(state!=SEARCH_A5)begin
    if(gap_count==GAP_TIMEOUT-1)begin
     state<=SEARCH_A5;gap_count<=0;timeout_errors<=32'd1;packet_dropped<=1;
    end else gap_count<=gap_count+1'b1;
   end else gap_count<=0;
  end
 end
endmodule
