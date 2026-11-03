`timescale 1ns/1ps
// One-memory-domain bounded frame ownership. Slot data lives in SDRAM;
// this module stores only leases and descriptors, never full image pixels.
// Reset requires the memory/producer/consumer pipelines to be reset/drained
// together. Use cancel, not reset, for a live asset/session change.
module db_av_frame_pool #(
 parameter SLOTS=3,
 parameter [20:0] BASE_WORD=21'd1228800,
 parameter [20:0] FRAME_WORDS=21'd153600,
 parameter [3:0] KIND_MASK=4'b0110,
 parameter [31:0] TOKEN_LIMIT=32'hffffffff
)(
 input wire clk,rst,cancel,
 input wire alloc_valid,output wire alloc_ready,input wire[1:0]alloc_kind,
 input wire[31:0]alloc_epoch,alloc_asset,alloc_frame,alloc_pts,alloc_duration,
 output wire[1:0]alloc_slot,output wire[31:0]alloc_token,output wire[20:0]alloc_base,
 input wire commit_valid,output wire commit_ready,input wire[1:0]commit_slot,input wire[31:0]commit_token,
 input wire writes_idle,
 output wire frame_valid,input wire frame_take,output wire[1:0]frame_slot,frame_kind,
 output wire[31:0]frame_token,frame_epoch,frame_asset,frame_id,frame_pts,frame_duration,
 output wire[20:0]frame_base,
 input wire release_valid,output wire release_ready,input wire[1:0]release_slot,input wire[31:0]release_token,
 input wire reads_idle,release_keep,
 input wire reuse_valid,output wire reuse_ready,input wire[1:0]reuse_slot,input wire[31:0]reuse_old_token,
 input wire[31:0]reuse_epoch,reuse_frame,reuse_pts,reuse_duration,output wire[31:0]reuse_new_token,
 input wire evict_valid,output wire evict_ready,input wire[1:0]evict_slot,input wire[31:0]evict_token,
 output wire idle,token_exhausted,output wire[2:0]queued_frames,
 output wire[SLOTS-1:0]busy_slots,quarantine_slots,resident_slots,
 output reg[31:0]rejected_events
);
 localparam FREE=0,FILL=1,QUEUED=2,SEND=3,QWRITE=4,QREAD=5,RESIDENT=6;
 reg[2:0]state[0:SLOTS-1];reg[31:0]token[0:SLOTS-1];
 // kind, epoch, asset id, frame id, PTS90k, duration90k.
 reg[161:0]metadata[0:SLOTS-1];
 reg[1:0]queue[0:SLOTS-1],head,tail;
 reg[2:0]count;reg[31:0]next_token;
 reg free_found,has_fill,has_send,has_busy;reg[1:0]free_slot;integer i,j;
 always @*begin
  free_found=0;free_slot=0;has_fill=0;has_send=0;has_busy=0;
  for(j=0;j<SLOTS;j=j+1)begin
   if(state[j]==FREE&&!free_found)begin free_found=1;free_slot=j;end
   if(state[j]==FILL||state[j]==QWRITE)has_fill=1;
   if(state[j]==SEND||state[j]==QREAD)has_send=1;
   if(state[j]!=FREE)has_busy=1;
  end
 end
 assign token_exhausted=next_token>=TOKEN_LIMIT;
 assign alloc_ready=!rst&&!cancel&&!reuse_valid&&free_found&&!has_fill&&!token_exhausted&&KIND_MASK[alloc_kind];
 assign alloc_slot=free_slot;
 assign alloc_token=next_token;
 assign alloc_base=BASE_WORD+free_slot*FRAME_WORDS;
 wire commit_owner=commit_slot<SLOTS&&state[commit_slot]==FILL&&token[commit_slot]==commit_token;
 assign commit_ready=!rst&&!cancel&&commit_owner&&writes_idle;
 assign frame_valid=!rst&&!cancel&&count!=0&&!has_send;
 wire[1:0]front=count!=0?queue[head]:2'd0;
 wire[161:0]front_metadata=frame_valid?metadata[front]:162'd0;
 assign frame_slot=front;
 assign frame_token=frame_valid?token[front]:32'd0;
 assign {frame_kind,frame_epoch,frame_asset,frame_id,frame_pts,frame_duration}=front_metadata;
 assign frame_base=BASE_WORD+front*FRAME_WORDS;
 wire release_owner=release_slot<SLOTS&&state[release_slot]==SEND&&token[release_slot]==release_token;
 wire keep_allowed=!release_keep||metadata[release_slot][161:160]==0;
 assign release_ready=!rst&&!cancel&&release_owner&&reads_idle&&keep_allowed;
 assign idle=!has_busy;assign queued_frames=count;
 generate for(genvar s=0;s<SLOTS;s=s+1)begin:slot_status
  assign busy_slots[s]=state[s]!=FREE;
  assign quarantine_slots[s]=state[s]==QREAD||state[s]==QWRITE;
  assign resident_slots[s]=state[s]==RESIDENT;
 end endgenerate
 wire allocate=alloc_valid&&alloc_ready;
 wire commit=commit_valid&&commit_ready;
 wire reuse_owner=reuse_slot<SLOTS&&state[reuse_slot]==RESIDENT&&token[reuse_slot]==reuse_old_token;
 assign reuse_ready=!rst&&!cancel&&reuse_owner&&!token_exhausted&&!commit;
 assign reuse_new_token=next_token;
 wire reuse=reuse_valid&&reuse_ready;
 wire evict_owner=evict_slot<SLOTS&&state[evict_slot]==RESIDENT&&token[evict_slot]==evict_token;
 assign evict_ready=!rst&&!cancel&&evict_owner&&!reuse_valid;
 wire evict=evict_valid&&evict_ready;
 wire take=frame_valid&&frame_take;
 wire release_event=release_valid&&release_ready;
 wire bad_commit=commit_valid&&!commit_owner;
 wire bad_release=release_valid&&(!release_owner||!keep_allowed);
 wire bad_reuse=reuse_valid&&!reuse_owner;
 wire bad_evict=evict_valid&&!evict_owner;
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   head<=0;tail<=0;count<=0;next_token<=1;rejected_events<=0;
   for(i=0;i<SLOTS;i=i+1)begin state[i]<=FREE;token[i]<=0;end
  end else begin
   // Retiring an old operation does not allow allocation until a later edge.
   for(i=0;i<SLOTS;i=i+1)begin
    if(state[i]==QWRITE&&writes_idle)state[i]<=FREE;
    if(state[i]==QREAD&&reads_idle)state[i]<=FREE;
   end
   if(cancel)begin
    head<=0;tail<=0;count<=0;
    for(i=0;i<SLOTS;i=i+1)begin
     if(state[i]==FILL)state[i]<=writes_idle?FREE:QWRITE;
     if(state[i]==SEND)state[i]<=reads_idle?FREE:QREAD;
     if(state[i]==QUEUED||state[i]==RESIDENT)state[i]<=FREE;
    end
   end else begin
    if(bad_commit||bad_release||bad_reuse||bad_evict)rejected_events<=32'd1;
    if(allocate)begin
     state[free_slot]<=FILL;token[free_slot]<=next_token;next_token<=next_token+1'b1;
     metadata[free_slot]<={alloc_kind,alloc_epoch,alloc_asset,alloc_frame,alloc_pts,alloc_duration};
    end
    if(commit)begin
     state[commit_slot]<=QUEUED;queue[tail]<=commit_slot;
     tail<=tail==SLOTS-1?2'd0:tail+1'b1;
    end
    if(reuse)begin
     // A resend is a fresh lease: late acknowledgements from the earlier
     // transmission must not release/evict this use of the same SDRAM slot.
     state[reuse_slot]<=QUEUED;token[reuse_slot]<=next_token;next_token<=next_token+1'b1;
     metadata[reuse_slot]<={metadata[reuse_slot][161:160],reuse_epoch,metadata[reuse_slot][127:96],reuse_frame,reuse_pts,reuse_duration};
     queue[tail]<=reuse_slot;tail<=tail==SLOTS-1?2'd0:tail+1'b1;
    end
    if(take)begin state[front]<=SEND;head<=head==SLOTS-1?2'd0:head+1'b1;end
    case({commit||reuse,take})
     2'b10:count<=count+1'b1;
     2'b01:count<=count-1'b1;
     default:count<=count;
    endcase
    if(release_event)state[release_slot]<=release_keep?RESIDENT:FREE;
    if(evict)state[evict_slot]<=FREE;
   end
  end
 end
endmodule
