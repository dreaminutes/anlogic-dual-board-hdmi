`timescale 1ns/1ps
// Low-speed integration adapter: board-tested 1MHz input sampling -> existing
// typed-record/frame engine. Memory ports still require a real controller;
// this module does not implement SDRAM, HDMI, TF or the return command channel.
module db_info_sampled_engine(output wire[31:0] display_source_size,
 output wire cache_valid,cache_loading,output wire[6:0]cache_percent,output wire[31:0]cache_asset,output wire[20:0]cache_samples,output wire[7:0]cache_generation,
 output wire session_confirm_src,
 output wire pcm_write,output wire[15:0]pcm_data,input wire pcm_ready,input wire[12:0]pcm_free,
 input wire capture_clk,clk50,mem_clk,transport_arst,main_rst,
 input wire[31:0]armed_epoch_src,armed_epoch_mem,
 input wire forward_clk,link_valid,input wire[7:0]link_data,
 output wire can_start,credit_out,capture_failed,
 input wire[20:0]base0,base1,base2,
 input wire[2:0]hold_slots,input wire vblank_event,present_allow,
 output wire mem_req,output wire[20:0]mem_address,output wire[31:0]mem_data,
 input wire mem_ready,mem_done,memory_writes_idle,
 output wire display_valid,output wire[1:0]display_slot,
 output wire[31:0]display_frame_id,display_epoch,
 output wire receive_active,pending_valid,session_ready_mem,writes_idle,
 output wire[15:0]expected_row,
 output wire[31:0]crc_errors,rejected_records,rejected_rows,
 output wire[2:0]quarantine_slots,output wire transport_idle,output wire bmp_failed,output wire file_room,
 output wire display_metadata_valid,output wire[193:0]display_metadata,
 output wire asset_changed,static_transition,dynamic_continuation,output wire[31:0]metadata_errors,
 output wire monitor_begin,monitor_complete,monitor_present,monitor_cancel,
 output wire[31:0]monitor_epoch,monitor_frame,output wire[1:0]monitor_slot
);
 wire input_reset=transport_arst||main_rst;
 wire sample_valid;wire[7:0]sample_data;wire core_can_start;
 db_fast24_capture_bridge capture(.capture_clk(capture_clk),.clk50(clk50),.rst(input_reset),
  .forward_clk(forward_clk),.link_valid(link_valid),.link_data(link_data),
  .byte_valid(sample_valid),.byte_data(sample_data),.failed(capture_failed));
 assign can_start=core_can_start&&!capture_failed;
 (* async_reg="true" *)reg[2:0]credit_reset;
 always @(posedge clk50 or posedge input_reset)
  if(input_reset)credit_reset<=3'b111;
  else credit_reset<={credit_reset[1:0],1'b0};
 assign credit_out=input_reset?1'bz:(!credit_reset[2]&&can_start);
 // The unmodified engine's packet-gap timeout is 4096 local cycles (~82us at
 // 50MHz), enough for contiguous 1MHz byte traffic. Packets may not pause for
 // longer than that. The frame idle timeout and row/memory CDC are unchanged.
 db_info_receive_engine engine(.display_source_size(display_source_size),.cache_valid(cache_valid),.cache_loading(cache_loading),.cache_percent(cache_percent),.cache_asset(cache_asset),.cache_samples(cache_samples),.cache_generation(cache_generation),.session_confirm_src(session_confirm_src),.pcm_write(pcm_write),.pcm_data(pcm_data),.pcm_ready(pcm_ready),.pcm_free(pcm_free),.src_clk(clk50),.mem_clk(mem_clk),
  .transport_arst(input_reset),.main_rst(main_rst),
  .armed_epoch_src(armed_epoch_src),.armed_epoch_mem(armed_epoch_mem),
  .in_valid(sample_valid),.in_data(sample_data),.can_start(core_can_start),
  .base0(base0),.base1(base1),.base2(base2),.hold_slots(hold_slots),
  .vblank_event(vblank_event),.present_allow(present_allow),
  .mem_req(mem_req),.mem_address(mem_address),.mem_data(mem_data),.mem_ready(mem_ready),.mem_done(mem_done),.memory_writes_idle(memory_writes_idle),
  .display_valid(display_valid),.display_slot(display_slot),.display_frame_id(display_frame_id),.display_epoch(display_epoch),
  .receive_active(receive_active),.pending_valid(pending_valid),.session_ready_mem(session_ready_mem),.writes_idle(writes_idle),
  .expected_row(expected_row),.crc_errors(crc_errors),.rejected_records(rejected_records),.rejected_rows(rejected_rows),
  .quarantine_slots(quarantine_slots),.transport_idle(transport_idle),.bmp_failed(bmp_failed),.file_room(file_room),.display_metadata_valid(display_metadata_valid),.display_metadata(display_metadata),
  .asset_changed(asset_changed),.static_transition(static_transition),.dynamic_continuation(dynamic_continuation),.metadata_errors(metadata_errors),.monitor_begin(monitor_begin),.monitor_complete(monitor_complete),.monitor_present(monitor_present),.monitor_cancel(monitor_cancel),.monitor_epoch(monitor_epoch),.monitor_frame(monitor_frame),.monitor_slot(monitor_slot));
endmodule
