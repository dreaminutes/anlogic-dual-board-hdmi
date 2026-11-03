`timescale 1ns/1ps
`include "db_media_metadata.vh"
// Metadata-aware wrapper around the frozen pixel ownership guard. This is a
// memory-domain component; the future session/router must authorize its inputs.
// Slot metadata is visible only with matching committed/displayed pixel identity.
module db_full_media_frame_guard #(
 parameter IDLE_TIMEOUT_CYCLES=2500000
)(
 input wire clk,rst,session_start,session_cancel,input wire[31:0]new_epoch,
 input wire abort_frame,writes_idle,input wire[2:0]hold_slots,
 input wire metadata_valid,output wire metadata_ready,input wire[193:0]metadata,
 input wire whole_complete,write_activity,
 input wire row_valid,input wire[31:0]row_epoch,row_frame_id,
 input wire[15:0]row_index,row_bytes,input wire row_write_ok,
 input wire end_valid,output wire end_ready,input wire[31:0]end_epoch,end_frame_id,end_bytes,input wire[15:0]end_rows,
 input wire vblank_event,present_allow,
 output wire receive_active,output wire[1:0]receive_slot,output wire[31:0]receive_frame_id,output wire[15:0]expected_row,
 output wire pending_valid,output wire[1:0]pending_slot,output wire[31:0]pending_frame_id,
 output wire display_valid,output wire[1:0]display_slot,output wire[31:0]display_frame_id,display_epoch,
 output wire pending_metadata_valid,display_metadata_valid,output wire[193:0]pending_metadata,display_metadata,
 output wire[2:0]quarantine_slots,output wire begin_accepted,frame_completed,frame_presented,frame_rejected,
 output wire[31:0]rejected_count,timeout_count,
 output reg metadata_rejected,output reg[31:0]rejected_metadata_count,
 output reg asset_changed,static_transition,dynamic_continuation
);
 reg session_live;reg[31:0]authorized_epoch;reg[193:0]accepted_metadata,slot_metadata[0:2];reg[2:0]slot_valid;
 wire[1:0]kind=metadata[`DB_MEDIA_KIND];
 wire legal=session_live&&metadata[`DB_MEDIA_EPOCH]==authorized_epoch&&kind<=2&&metadata[`DB_MEDIA_DURATION]!=0&&
             (kind!=0||metadata[`DB_MEDIA_CONTENT_FRAME]==0);
 wire begin_ready;
 wire supersede=metadata_valid&&legal&&receive_active&&!session_start&&!session_cancel;
 wire guard_abort=abort_frame||session_cancel||supersede;
 assign metadata_ready=!rst&&!session_start&&!session_cancel&&(!legal||begin_ready);
 wire metadata_accept=metadata_valid&&metadata_ready&&legal;
 db_full_frame_guard #(.WIDTH(640),.HEIGHT(480),.IDLE_TIMEOUT_CYCLES(IDLE_TIMEOUT_CYCLES)) pixels(
  .clk(clk),.rst(rst),.session_start(session_start),.new_epoch(new_epoch),.abort_frame(guard_abort),.writes_idle(writes_idle),.hold_slots(hold_slots),
  .begin_valid(metadata_valid&&legal&&!session_cancel),.begin_ready(begin_ready),
  .begin_epoch(metadata[`DB_MEDIA_EPOCH]),.begin_frame_id(metadata[`DB_MEDIA_WIRE_FRAME]),.begin_width(16'd640),.begin_height(16'd480),.begin_format(8'd1),
  .whole_complete(whole_complete),.write_activity(write_activity),.row_valid(row_valid),.row_epoch(row_epoch),.row_frame_id(row_frame_id),.row_index(row_index),.row_bytes(row_bytes),.row_write_ok(row_write_ok),
  .end_valid(end_valid),.end_ready(end_ready),.end_epoch(end_epoch),.end_frame_id(end_frame_id),.end_bytes(end_bytes),.end_rows(end_rows),
  .vblank_event(vblank_event),.present_allow(present_allow&&pending_metadata_valid&&session_live&&!session_cancel),
  .receive_active(receive_active),.receive_slot(receive_slot),.receive_frame_id(receive_frame_id),.expected_row(expected_row),
  .pending_valid(pending_valid),.pending_slot(pending_slot),.pending_frame_id(pending_frame_id),
  .display_valid(display_valid),.display_slot(display_slot),.display_frame_id(display_frame_id),.display_epoch(display_epoch),
  .quarantine_slots(quarantine_slots),.begin_accepted(begin_accepted),.frame_completed(frame_completed),.frame_presented(frame_presented),.frame_rejected(frame_rejected),
  .rejected_count(rejected_count),.timeout_count(timeout_count));
 wire[193:0]pending_value=slot_metadata[pending_slot],display_value=slot_metadata[display_slot];
 assign pending_metadata_valid=pending_valid&&session_live&&!session_cancel&&slot_valid[pending_slot]&&pending_value[`DB_MEDIA_EPOCH]==authorized_epoch&&pending_value[`DB_MEDIA_WIRE_FRAME]==pending_frame_id;
 assign display_metadata_valid=display_valid&&slot_valid[display_slot]&&display_value[`DB_MEDIA_EPOCH]==display_epoch&&display_value[`DB_MEDIA_WIRE_FRAME]==display_frame_id;
 assign pending_metadata=pending_metadata_valid?pending_value:194'd0;
 assign display_metadata=display_metadata_valid?display_value:194'd0;
 wire present_event=vblank_event&&present_allow&&pending_metadata_valid&&session_live&&!session_start&&!session_cancel;
 wire different_asset=!display_metadata_valid||pending_value[`DB_MEDIA_EPOCH]!=display_value[`DB_MEDIA_EPOCH]||
  pending_value[`DB_MEDIA_KIND]!=display_value[`DB_MEDIA_KIND]||pending_value[`DB_MEDIA_ASSET]!=display_value[`DB_MEDIA_ASSET];
 integer i;
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   session_live<=0;authorized_epoch<=0;accepted_metadata<=0;slot_valid<=0;
   for(i=0;i<3;i=i+1)slot_metadata[i]<=0;
   metadata_rejected<=0;rejected_metadata_count<=0;asset_changed<=0;static_transition<=0;dynamic_continuation<=0;
  end else begin
   metadata_rejected<=0;asset_changed<=0;static_transition<=0;dynamic_continuation<=0;
   if(session_start)begin session_live<=1;authorized_epoch<=new_epoch;end
   else if(session_cancel)session_live<=0;
   if(metadata_valid&&metadata_ready)begin
    if(legal)accepted_metadata<=metadata;
    else begin metadata_rejected<=1;rejected_metadata_count<=rejected_metadata_count+1'b1;end
   end
   // Guard pulses and receive_slot are registered at the accepted BEGIN edge.
   // accepted_metadata is frozen at that same handshake, independent of input.
   if(begin_accepted)begin slot_metadata[receive_slot]<=accepted_metadata;slot_valid[receive_slot]<=1;end
   if(present_event)begin
    asset_changed<=different_asset;
    static_transition<=different_asset&&pending_value[`DB_MEDIA_KIND]==0;
    dynamic_continuation<=!different_asset&&pending_value[`DB_MEDIA_KIND]!=0;
   end
  end
 end
endmodule
