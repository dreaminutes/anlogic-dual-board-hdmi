`timescale 1ns/1ps
// Local clock-domain ready/valid packet encoder. Not a physical CDC adapter.
module db_packet_tx #(parameter MAX_PAYLOAD=1280)(
 input wire clk,rst,
 input wire descriptor_valid,output wire descriptor_ready,
 input wire [7:0] packet_type,flags,
 input wire [31:0] frame_id,
 input wire [15:0] sequence_number,payload_length,
 input wire payload_valid,output wire payload_ready,input wire [7:0] payload_data,
 output reg out_valid,input wire out_ready,output reg [7:0] out_data,
 output reg packet_done
);
 localparam IDLE=0,HEADER=1,PAYLOAD=2,CRC_LOW=3,CRC_HIGH=4;
 reg [2:0] state;
 reg [7:0] saved_type,saved_flags;
 reg [31:0] saved_frame;
 reg [15:0] saved_sequence,saved_length,payload_index,header_crc,payload_crc;
 reg [3:0] header_index;
 `include "db_crc16.vh"
 assign descriptor_ready=(state==IDLE)&&(payload_length<=MAX_PAYLOAD);
 assign payload_ready=(state==PAYLOAD)&&out_ready;
 always @* begin
  out_valid=1'b1;out_data=0;
  case(state)
   HEADER:case(header_index)
    0:out_data=8'hA5;1:out_data=8'h5A;2:out_data=8'h01;
    3:out_data=saved_type;
    4:out_data=saved_frame[7:0];5:out_data=saved_frame[15:8];
    6:out_data=saved_frame[23:16];7:out_data=saved_frame[31:24];
    8:out_data=saved_sequence[7:0];9:out_data=saved_sequence[15:8];
    10:out_data=saved_length[7:0];11:out_data=saved_length[15:8];
    12:out_data=saved_flags;13:out_data=0;
    14:out_data=header_crc[7:0];15:out_data=header_crc[15:8];
   endcase
   PAYLOAD:begin out_valid=payload_valid;out_data=payload_data;end
   CRC_LOW:out_data=payload_crc[7:0];
   CRC_HIGH:out_data=payload_crc[15:8];
   default:out_valid=0;
  endcase
 end
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   state<=IDLE;header_index<=0;payload_index<=0;
   header_crc<=16'hFFFF;payload_crc<=16'hFFFF;packet_done<=0;
   saved_type<=0;saved_flags<=0;saved_frame<=0;saved_sequence<=0;saved_length<=0;
  end else begin
   packet_done<=0;
   if(state==IDLE)begin
    if(descriptor_valid&&descriptor_ready)begin
     saved_type<=packet_type;saved_flags<=flags;saved_frame<=frame_id;
     saved_sequence<=sequence_number;saved_length<=payload_length;
     header_index<=0;payload_index<=0;header_crc<=16'hFFFF;payload_crc<=16'hFFFF;
     state<=HEADER;
    end
   end else if(out_valid&&out_ready)begin
    case(state)
     HEADER:begin
      if(header_index<14)header_crc<=db_crc16_byte(header_crc,out_data);
      if(header_index==15)state<=(saved_length==0)?CRC_LOW:PAYLOAD;
      else header_index<=header_index+1'b1;
     end
     PAYLOAD:begin
      payload_crc<=db_crc16_byte(payload_crc,payload_data);
      if(payload_index+1'b1==saved_length)state<=CRC_LOW;
      else payload_index<=payload_index+1'b1;
     end
     CRC_LOW:state<=CRC_HIGH;
     CRC_HIGH:begin state<=IDLE;packet_done<=1;end
    endcase
   end
  end
 end
endmodule
