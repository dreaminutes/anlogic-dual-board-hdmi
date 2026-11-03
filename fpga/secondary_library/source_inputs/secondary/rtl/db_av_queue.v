`timescale 1ns/1ps
`include "db_frame_descriptor.vh"
// Two logical channels, one sender lease. Entire block is in mem_clk.
// GIF/video share the three stream slots; BMP uses two resident-capable slots.
// Pixel IO, decoder, SD controller, packet formatter and CDC remain external.
module db_av_queue(
 input wire clk,rst,cancel,transport_drained,writes_idle,reads_idle,
 input wire alloc_valid,alloc_static,input wire[1:0]alloc_kind,
 input wire[31:0]alloc_epoch,alloc_asset,alloc_frame,alloc_pts,alloc_duration,
 output wire alloc_ready,output wire[1:0]alloc_slot,output wire[31:0]alloc_token,output wire[20:0]alloc_base,
 input wire commit_valid,commit_static,input wire[1:0]commit_slot,input wire[31:0]commit_token,output wire commit_ready,
 input wire reuse_valid,input wire[1:0]reuse_slot,input wire[31:0]reuse_old_token,reuse_epoch,reuse_frame,reuse_pts,reuse_duration,
 output wire reuse_ready,output wire[31:0]reuse_new_token,
 input wire evict_valid,input wire[1:0]evict_slot,input wire[31:0]evict_token,output wire evict_ready,
 output wire frame_valid,frame_is_still,input wire frame_take,
 output wire[`DB_FRAME_DESCRIPTOR_WIDTH-1:0]frame_descriptor,
 input wire finish_valid,output wire finish_ready,
 output wire[4:0]busy_slots,quarantine_slots,output wire[1:0]resident_slots,
 output wire sender_busy,sender_quarantined,output wire[31:0]rejected_events
);
 wire sv,dv,st,dt,sr,dr,srr,drr;wire[1:0]release_slot;wire[31:0]release_token;
 wire sa,da,sc,dc;wire[1:0]ss,ds;wire[31:0]stok,dtok;wire[20:0]sb,db;
 wire[`DB_FRAME_DESCRIPTOR_WIDTH-1:0]sdesc,ddesc;
 wire[31:0]serrors,derrors;
 db_av_frame_pool #(.SLOTS(2),.BASE_WORD(21'd1689600),.KIND_MASK(4'b0001)) still_pool(
  .clk(clk),.rst(rst),.cancel(cancel),.alloc_valid(alloc_valid&&alloc_static),.alloc_ready(sa),.alloc_kind(2'd0),
  .alloc_epoch(alloc_epoch),.alloc_asset(alloc_asset),.alloc_frame(alloc_frame),.alloc_pts(alloc_pts),.alloc_duration(alloc_duration),
  .alloc_slot(ss),.alloc_token(stok),.alloc_base(sb),.commit_valid(commit_valid&&commit_static),.commit_ready(sc),.commit_slot(commit_slot),.commit_token(commit_token),.writes_idle(writes_idle),
  .frame_valid(sv),.frame_take(st),.frame_kind(sdesc[`DB_FRAME_DESCRIPTOR_KIND]),.frame_epoch(sdesc[`DB_FRAME_DESCRIPTOR_EPOCH]),
  .frame_asset(sdesc[`DB_FRAME_DESCRIPTOR_ASSET]),.frame_id(sdesc[`DB_FRAME_DESCRIPTOR_ID]),.frame_pts(sdesc[`DB_FRAME_DESCRIPTOR_PTS]),.frame_duration(sdesc[`DB_FRAME_DESCRIPTOR_DURATION]),
  .frame_base(sdesc[`DB_FRAME_DESCRIPTOR_BASE]),.frame_token(sdesc[`DB_FRAME_DESCRIPTOR_TOKEN]),.frame_slot(sdesc[`DB_FRAME_DESCRIPTOR_SLOT]),
  .release_valid(sr),.release_ready(srr),.release_slot(release_slot),.release_token(release_token),.reads_idle(reads_idle),.release_keep(1'b1),
  .reuse_valid(reuse_valid),.reuse_ready(reuse_ready),.reuse_slot(reuse_slot),.reuse_old_token(reuse_old_token),
  .reuse_epoch(reuse_epoch),.reuse_frame(reuse_frame),.reuse_pts(reuse_pts),.reuse_duration(reuse_duration),.reuse_new_token(reuse_new_token),
  .evict_valid(evict_valid),.evict_ready(evict_ready),.evict_slot(evict_slot),.evict_token(evict_token),
  .idle(),.token_exhausted(),.queued_frames(),.busy_slots(busy_slots[1:0]),.quarantine_slots(quarantine_slots[1:0]),.resident_slots(resident_slots),.rejected_events(serrors));
 db_av_frame_pool dynamic_pool(
  .clk(clk),.rst(rst),.cancel(cancel),.alloc_valid(alloc_valid&&!alloc_static),.alloc_ready(da),.alloc_kind(alloc_kind),
  .alloc_epoch(alloc_epoch),.alloc_asset(alloc_asset),.alloc_frame(alloc_frame),.alloc_pts(alloc_pts),.alloc_duration(alloc_duration),
  .alloc_slot(ds),.alloc_token(dtok),.alloc_base(db),.commit_valid(commit_valid&&!commit_static),.commit_ready(dc),.commit_slot(commit_slot),.commit_token(commit_token),.writes_idle(writes_idle),
  .frame_valid(dv),.frame_take(dt),.frame_kind(ddesc[`DB_FRAME_DESCRIPTOR_KIND]),.frame_epoch(ddesc[`DB_FRAME_DESCRIPTOR_EPOCH]),
  .frame_asset(ddesc[`DB_FRAME_DESCRIPTOR_ASSET]),.frame_id(ddesc[`DB_FRAME_DESCRIPTOR_ID]),.frame_pts(ddesc[`DB_FRAME_DESCRIPTOR_PTS]),.frame_duration(ddesc[`DB_FRAME_DESCRIPTOR_DURATION]),
  .frame_base(ddesc[`DB_FRAME_DESCRIPTOR_BASE]),.frame_token(ddesc[`DB_FRAME_DESCRIPTOR_TOKEN]),.frame_slot(ddesc[`DB_FRAME_DESCRIPTOR_SLOT]),
  .release_valid(dr),.release_ready(drr),.release_slot(release_slot),.release_token(release_token),.reads_idle(reads_idle),.release_keep(1'b0),
  .reuse_valid(1'b0),.reuse_ready(),.reuse_slot(2'd0),.reuse_old_token(32'd0),.reuse_epoch(32'd0),.reuse_frame(32'd0),.reuse_pts(32'd0),.reuse_duration(32'd0),.reuse_new_token(),
  .evict_valid(1'b0),.evict_ready(),.evict_slot(2'd0),.evict_token(32'd0),
  .idle(),.token_exhausted(),.queued_frames(),.busy_slots(busy_slots[4:2]),.quarantine_slots(quarantine_slots[4:2]),.resident_slots(),.rejected_events(derrors));
 db_av_frame_dispatch dispatch(.clk(clk),.rst(rst),.cancel(cancel),.transport_drained(transport_drained),
  .still_valid(sv),.stream_valid(dv),.still_take(st),.stream_take(dt),.still_descriptor(sdesc),.stream_descriptor(ddesc),
  .frame_valid(frame_valid),.frame_take(frame_take),.frame_is_still(frame_is_still),.frame_descriptor(frame_descriptor),
  .finish_valid(finish_valid),.finish_ready(finish_ready),.still_release(sr),.stream_release(dr),.still_release_ready(srr),.stream_release_ready(drr),
  .release_slot(release_slot),.release_token(release_token),.busy(sender_busy),.quarantined(sender_quarantined));
 assign alloc_ready=alloc_static?sa:da;assign alloc_slot=alloc_static?ss:ds;assign alloc_token=alloc_static?stok:dtok;assign alloc_base=alloc_static?sb:db;
 assign commit_ready=commit_static?sc:dc;
 assign rejected_events=serrors+derrors;
endmodule
