`timescale 1ns/1ps
// All consumer ports below remain in forward_clk's domain. Crossing into the
// main-board memory/video domains is a separate integration step, not a wire.
module db_source_sync_rx #(parameter MAX_PAYLOAD=1280,parameter GAP_TIMEOUT=4096)(
 input wire forward_clk,async_reset,input wire link_valid,input wire [7:0] link_data,
 output wire credit_out,output wire reset_active,
 output wire packet_valid,input wire packet_take,
 output wire [7:0] packet_type,flags,output wire [31:0] frame_id,
 output wire [15:0] sequence_number,payload_length,
 input wire [10:0] read_address,output wire [7:0] read_data,
 output wire [31:0] crc_errors,format_errors,timeout_errors,busy_errors
);
 (* async_reg="true" *) reg [2:0] reset_sync;
 always @(posedge forward_clk or posedge async_reset)
  if(async_reset)reset_sync<=3'b111;
  else reset_sync<={reset_sync[1:0],1'b0};
 assign reset_active=reset_sync[2];
 wire can_start;
 assign credit_out=can_start&&!reset_active;
 db_packet_rx #(.MAX_PAYLOAD(MAX_PAYLOAD),.GAP_TIMEOUT(GAP_TIMEOUT)) decoder(
  .clk(forward_clk),.rst(reset_active),.in_valid(link_valid),.in_data(link_data),
  .can_start(can_start),.packet_valid(packet_valid),.packet_take(packet_take),
  .packet_type(packet_type),.flags(flags),.frame_id(frame_id),
  .sequence_number(sequence_number),.payload_length(payload_length),
  .read_address(read_address),.read_data(read_data),
  .packet_committed(),.packet_dropped(),.crc_errors(crc_errors),
  .format_errors(format_errors),.timeout_errors(timeout_errors),.busy_errors(busy_errors));
endmodule
