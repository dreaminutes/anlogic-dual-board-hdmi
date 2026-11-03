`timescale 1ns/1ps
// Descriptor/ownership guard in ONE memory clock domain. Events must be emitted
// by the future packet + SDRAM writer only after validated writes complete.
// This module does not write pixels, cross clocks or drive the video reader.
module db_full_frame_guard #(
 parameter WIDTH=640,HEIGHT=480,IDLE_TIMEOUT_CYCLES=2500000
)(
 input wire clk,rst,
 input wire session_start,input wire [31:0] new_epoch,
 input wire abort_frame,input wire writes_idle,
 input wire [2:0] hold_slots,
 input wire begin_valid,output wire begin_ready,
 input wire [31:0] begin_epoch,begin_frame_id,
 input wire [15:0] begin_width,begin_height,input wire [7:0] begin_format,
 input wire whole_complete,write_activity,
 input wire row_valid,
 input wire [31:0] row_epoch,row_frame_id,
 input wire [15:0] row_index,row_bytes,input wire row_write_ok,
 input wire end_valid,output wire end_ready,
 input wire [31:0] end_epoch,end_frame_id,end_bytes,
 input wire [15:0] end_rows,
 input wire vblank_event,present_allow,
 output reg receive_active,output reg [1:0] receive_slot,
 output reg [31:0] receive_frame_id,
 output reg [15:0] expected_row,
 output reg pending_valid,output reg [1:0] pending_slot,
 output reg [31:0] pending_frame_id,
 output reg display_valid,output reg [1:0] display_slot,
 output reg [31:0] display_frame_id,display_epoch,
 output reg [2:0] quarantine_slots,
 output reg begin_accepted,frame_completed,frame_presented,frame_rejected,
 output reg [31:0] rejected_count,timeout_count
);
 localparam [15:0] ROW_BYTES=WIDTH*2;
 localparam [31:0] FRAME_BYTES=WIDTH*HEIGHT*2;
 localparam TIMER_BITS=(IDLE_TIMEOUT_CYCLES<2)?1:$clog2(IDLE_TIMEOUT_CYCLES+1);
 reg [TIMER_BITS-1:0] idle_timer;
 reg session_valid;
 reg [31:0] epoch,received_bytes,pending_epoch;
 reg free_found;reg [1:0] free_slot;
 reg [2:0] occupied;
 integer slot_index;
 always @* begin
  occupied=hold_slots|quarantine_slots;
  if(display_valid)occupied[display_slot]=1;
  if(pending_valid)occupied[pending_slot]=1;
  if(receive_active)occupied[receive_slot]=1;
  free_found=0;free_slot=0;
  for(slot_index=0;slot_index<3;slot_index=slot_index+1)
   if(!occupied[slot_index]&&!free_found)begin free_found=1;free_slot=slot_index;end
 end
 assign begin_ready=session_valid&&!receive_active&&free_found&&writes_idle&&!session_start&&!abort_frame;
 assign end_ready=!pending_valid&&writes_idle&&!session_start&&!abort_frame;
 wire begin_event=begin_valid&&begin_ready;
 wire end_event=end_valid&&end_ready;
 wire event_collision=(begin_event&&row_valid)||(begin_event&&end_event)||(row_valid&&end_event);
 wire idle_expired=receive_active&&!write_activity&&!whole_complete&&!row_valid&&!end_valid&&!abort_frame&&
                   idle_timer==IDLE_TIMEOUT_CYCLES-1;
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   session_valid<=0;epoch<=0;idle_timer<=0;received_bytes<=0;pending_epoch<=0;
   receive_active<=0;receive_slot<=0;receive_frame_id<=0;expected_row<=0;
   pending_valid<=0;pending_slot<=0;pending_frame_id<=0;
   display_valid<=0;display_slot<=0;display_frame_id<=0;display_epoch<=0;
   quarantine_slots<=0;begin_accepted<=0;frame_completed<=0;frame_presented<=0;frame_rejected<=0;
   rejected_count<=0;timeout_count<=0;
  end else begin
   begin_accepted<=0;frame_completed<=0;frame_presented<=0;frame_rejected<=0;
   if(writes_idle)quarantine_slots<=0;
   if(receive_active)begin
    if(row_valid||end_event||write_activity||whole_complete)idle_timer<=0;
    else if(idle_timer<IDLE_TIMEOUT_CYCLES-1)idle_timer<=idle_timer+1'b1;
   end else idle_timer<=0;
   // Present only complete, retired writes; source/session control remains in
   // this domain. The future video-domain descriptor handshake must preserve it.
   if(vblank_event&&present_allow&&pending_valid&&!session_start)begin
    display_valid<=1;display_slot<=pending_slot;display_frame_id<=pending_frame_id;
    display_epoch<=pending_epoch;pending_valid<=0;frame_presented<=1;
   end
   if(session_start)begin
    session_valid<=1;epoch<=new_epoch;receive_active<=0;pending_valid<=0;
    expected_row<=0;received_bytes<=0;idle_timer<=0;
    if(receive_active&&!writes_idle)quarantine_slots[receive_slot]<=1;
   end else if(abort_frame||event_collision||idle_expired)begin
    receive_active<=0;expected_row<=0;received_bytes<=0;idle_timer<=0;
    if(receive_active)begin
     frame_rejected<=1;rejected_count<=rejected_count+1'b1;
     if(!writes_idle)quarantine_slots[receive_slot]<=1;
    end
    if(idle_expired)timeout_count<=timeout_count+1'b1;
   end else if(begin_event)begin
    if(begin_epoch!=epoch||begin_width!=WIDTH||begin_height!=HEIGHT||begin_format!=1)begin
     rejected_count<=rejected_count+1'b1;frame_rejected<=1;
    end else begin
     receive_slot<=free_slot;receive_frame_id<=begin_frame_id;
     receive_active<=1;expected_row<=0;received_bytes<=0;idle_timer<=0;begin_accepted<=1;
    end
   end else if(whole_complete&&receive_active&&writes_idle)begin
    expected_row<=HEIGHT;received_bytes<=FRAME_BYTES;
   end else if(row_valid)begin
    if(!receive_active||row_epoch!=epoch||row_frame_id!=receive_frame_id||
       row_index!=expected_row||expected_row>=HEIGHT||row_bytes!=ROW_BYTES||!row_write_ok)begin
     receive_active<=0;expected_row<=0;received_bytes<=0;
     rejected_count<=rejected_count+1'b1;frame_rejected<=1;
     if(receive_active&&!writes_idle)quarantine_slots[receive_slot]<=1;
    end else begin
     expected_row<=expected_row+1'b1;received_bytes<=received_bytes+ROW_BYTES;
    end
   end else if(end_event)begin
    if(!receive_active||end_epoch!=epoch||end_frame_id!=receive_frame_id||
       expected_row!=HEIGHT||received_bytes!=FRAME_BYTES||end_rows!=HEIGHT||end_bytes!=FRAME_BYTES)begin
     receive_active<=0;expected_row<=0;received_bytes<=0;
     rejected_count<=rejected_count+1'b1;frame_rejected<=1;
    end else begin
     pending_valid<=1;pending_slot<=receive_slot;pending_frame_id<=receive_frame_id;
     pending_epoch<=epoch;receive_active<=0;frame_completed<=1;
    end
   end
  end
 end
endmodule
