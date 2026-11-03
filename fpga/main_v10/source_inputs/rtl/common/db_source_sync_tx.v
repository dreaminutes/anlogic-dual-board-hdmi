`timescale 1ns/1ps
// Source-domain packet-credit adapter. The forwarded clock is never gated.
// Board integration must constrain the forwarded clock and DDR half-cycle IO.
module db_source_sync_tx #(parameter MAX_PAYLOAD=1280)(
 input wire link_clk,rst,input wire credit_in,
 input wire descriptor_valid,output wire descriptor_ready,
 input wire [7:0] packet_type,flags,input wire [31:0] frame_id,
 input wire [15:0] sequence_number,payload_length,
 input wire payload_valid,output wire payload_ready,input wire [7:0] payload_data,
 output wire forward_clk,output reg link_valid,output reg [7:0] link_data,
 output wire packet_done,output wire waiting_for_credit
);
 localparam IDLE=0,ACTIVE=1,WAIT_RETURN=2;
 reg [1:0] state;
 (* async_reg="true" *) reg [2:0] credit_sync;
 reg saw_credit_low;
 reg launch_valid;
 reg [7:0] launch_data;
 wire core_descriptor_ready,core_out_valid;
 wire [7:0] core_out_data;
 wire permitted=(state==IDLE)&&credit_sync[2];
 wire core_out_ready=(state==ACTIVE);
 assign forward_clk=link_clk;
 assign descriptor_ready=permitted&&core_descriptor_ready;
 assign waiting_for_credit=(state==WAIT_RETURN)||((state==IDLE)&&!credit_sync[2]);
 db_packet_tx #(.MAX_PAYLOAD(MAX_PAYLOAD)) encoder(
  .clk(link_clk),.rst(rst),.descriptor_valid(descriptor_valid&&permitted),
  .descriptor_ready(core_descriptor_ready),.packet_type(packet_type),.flags(flags),
  .frame_id(frame_id),.sequence_number(sequence_number),.payload_length(payload_length),
  .payload_valid(payload_valid),.payload_ready(payload_ready),.payload_data(payload_data),
  .out_valid(core_out_valid),.out_ready(core_out_ready),.out_data(core_out_data),.packet_done(packet_done));
 always @(posedge link_clk or posedge rst)begin
  if(rst)begin credit_sync<=0;state<=IDLE;saw_credit_low<=0;end
  else begin
   credit_sync<={credit_sync[1:0],credit_in};
   case(state)
    IDLE:if(descriptor_valid&&descriptor_ready)begin state<=ACTIVE;saw_credit_low<=0;end
    ACTIVE:begin
     if(!credit_sync[2])saw_credit_low<=1;
     if(packet_done)state<=WAIT_RETURN;
    end
    WAIT_RETURN:begin
     if(!credit_sync[2])saw_credit_low<=1;
     if(saw_credit_low&&credit_sync[2])state<=IDLE;
    end
    default:state<=IDLE;
   endcase
  end
 end
 // Consume the local ready/valid stream on its positive clock edge first.
 // This register keeps the pad-launch edge independent of source update time.
 always @(posedge link_clk or posedge rst)begin
  if(rst)begin launch_valid<=0;launch_data<=0;end
  else begin
   launch_valid<=core_out_valid&&core_out_ready;
   if(core_out_valid&&core_out_ready)launch_data<=core_out_data;
  end
 end
 // Receiver samples at the next rising edge, after a nominal half-cycle.
 always @(negedge link_clk or posedge rst)begin
  if(rst)begin link_valid<=0;link_data<=0;end
  else begin
   link_valid<=launch_valid;
   if(launch_valid)link_data<=launch_data;
  end
 end
endmodule
