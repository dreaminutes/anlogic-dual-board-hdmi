`timescale 1ns/1ps
`include "db_frame_descriptor.vh"
// One complete frame owns the physical sender. A one-descriptor skid buffer
// acquires the pool lease before exposing it to a stalled sender. Arbitration
// is round-robin at frame boundaries; rows of two channels never interleave.
module db_av_frame_dispatch(
 input wire clk,rst,cancel,transport_drained,
 input wire still_valid,stream_valid,output wire still_take,stream_take,
 input wire[`DB_FRAME_DESCRIPTOR_WIDTH-1:0]still_descriptor,stream_descriptor,
 output wire frame_valid,input wire frame_take,output wire frame_is_still,
 output wire[`DB_FRAME_DESCRIPTOR_WIDTH-1:0]frame_descriptor,
 input wire finish_valid,output wire finish_ready,
 output wire still_release,stream_release,input wire still_release_ready,stream_release_ready,
 output wire[1:0]release_slot,output wire[31:0]release_token,
 output wire busy,quarantined
);
 reg held,launched,selected_still,prefer_still,drain_wait;
 reg[`DB_FRAME_DESCRIPTOR_WIDTH-1:0]descriptor;
 wire choose_still=still_valid&&(!stream_valid||prefer_still);
 wire acquire=!rst&&!cancel&&!held&&!drain_wait&&(still_valid||stream_valid);
 assign still_take=acquire&&choose_still;
 assign stream_take=acquire&&!choose_still;
 assign frame_valid=!rst&&!cancel&&held&&!launched&&!drain_wait;
 assign frame_is_still=selected_still;assign frame_descriptor=descriptor;
 assign still_release=!rst&&!cancel&&held&&launched&&selected_still&&finish_valid;
 assign stream_release=!rst&&!cancel&&held&&launched&&!selected_still&&finish_valid;
 assign finish_ready=!rst&&!cancel&&held&&launched&&(selected_still?still_release_ready:stream_release_ready);
 assign release_slot=descriptor[`DB_FRAME_DESCRIPTOR_SLOT];assign release_token=descriptor[`DB_FRAME_DESCRIPTOR_TOKEN];
 assign busy=held||drain_wait;assign quarantined=drain_wait;
 always @(posedge clk or posedge rst)begin
  if(rst)begin held<=0;launched<=0;selected_still<=0;prefer_still<=1;drain_wait<=0;descriptor<=0;end
  else if(cancel)begin held<=0;launched<=0;drain_wait<=!transport_drained;end
  else begin
   if(drain_wait&&transport_drained)drain_wait<=0;
   if(acquire)begin
    held<=1;launched<=0;selected_still<=choose_still;prefer_still<=!choose_still;
    descriptor<=choose_still?still_descriptor:stream_descriptor;
   end
   if(frame_valid&&frame_take)launched<=1;
   if(finish_valid&&finish_ready)begin held<=0;launched<=0;end
  end
 end
endmodule
