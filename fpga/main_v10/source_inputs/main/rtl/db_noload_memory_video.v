`timescale 1ns/1ps
// Hardware bring-up path. Uses the frozen V22 SDRAM controller/reader/arbiter.
// No TF decoder or production UI is removed: this is a separate diagnostic top.
module db_noload_memory_video(
 output wire video_hold,video_drop,input wire audio_music,
 output wire session_confirm_src,
 output wire[15:0]rate_info,output wire[23:0]audio_pcm,output wire audio_valid,input wire[1:0]audio_volume,input wire audio_mute,
 input wire run_control,menu_control,input wire[2:0]transition_mode,input wire[1:0]transition_duration,input wire[7:0]next_number,output wire[7:0]frame_grant,output wire file_room,
 input wire capture_clk,clk50,mem_clk,ram_clk,video_clk,start_rst,mem_rst,video_rst,enable,
 input wire forward_clk,link_valid,input wire[7:0]link_data,reserved,
 output wire credit_out,command_out,output wire[6:0]status,
 output wire[23:0]rgb,output reg de,vs,output reg[9:0]pixel_x,pixel_y
);
 localparam[20:0]BASE0=1024,BASE1=154624,BASE2=308224;
 reg[9:0]h,v;reg frame_toggle;
 always @(posedge video_clk or posedge video_rst)
  if(video_rst)begin h<=0;v<=0;frame_toggle<=0;de<=0;vs<=1;pixel_x<=0;pixel_y<=0;end
  else begin
   if(h==799)begin h<=0;v<=v==524?0:v+1'b1;end else h<=h+1'b1;
   if(h==0&&v==0)frame_toggle<=~frame_toggle;
   de<=h>=144&&h<784&&v>=35&&v<515;vs<=v>=2;
   pixel_x<=h-144;pixel_y<=v-35;
  end
 wire raw_de=h>=144&&h<784&&v>=35&&v<515;
 (* async_reg="true" *)reg[2:0]frame_sync;
 always @(posedge mem_clk or posedge mem_rst)
  if(mem_rst)frame_sync<=0;else frame_sync<={frame_sync[1:0],frame_toggle};
 wire frame_tick=frame_sync[2]!=frame_sync[1];
 wire memory_initialized;
 (* async_reg="true" *)reg[2:0]init_sync;
 always @(posedge clk50 or posedge start_rst)
  if(start_rst)init_sync<=0;else init_sync<={init_sync[1:0],memory_initialized};
 wire transport_reset=start_rst||!enable||!init_sync[2];
 wire capture_failed;wire monitor_begin,monitor_complete,monitor_present,monitor_cancel;
 wire[31:0]monitor_epoch,monitor_frame;wire[1:0]monitor_slot;
 wire cache_valid;wire[31:0]cache_asset;wire[20:0]cache_samples;wire[7:0]cache_generation;
 wire pcm_write,pcm_ready;wire[15:0]pcm_data,play_data;wire[12:0]pcm_free,play_used;wire play_valid,play_take,audio_underflow;
 db_av_pcm_fifo #(.AW(12)) audio_fifo(.rst(transport_reset||video_rst),.wr_clk(clk50),.rd_clk(video_clk),
  .wr_valid(pcm_write),.wr_data(pcm_data),.wr_ready(pcm_ready),.wr_free(pcm_free),
  .rd_valid(play_valid),.rd_data(play_data),.rd_take(play_take),.rd_used(play_used));
 wire audio_reset;
 reset_sync audio_reset_sync(.clk(video_clk),.arst(video_rst||transport_reset),.rst(audio_reset));
 wire[23:0]bg_pcm;wire bg_valid;
 db_av_pcm_playback player(.clk(video_clk),.rst(audio_reset),.enable(enable),.mute(audio_mute),.volume(audio_volume),
  .fifo_valid(play_valid),.fifo_data(play_data),.fifo_used(play_used),.fifo_take(play_take),.pcm_valid(bg_valid),.pcm(bg_pcm),.underflow(audio_underflow));
 wire can_start,writer_req,writer_ready,writer_idle,display_valid,receive_active,pending_valid,session_ready,transport_idle;
 wire[20:0]writer_addr;wire[31:0]writer_data,display_frame,display_epoch,crc_errors,rejected_records,rejected_rows;
 wire display_metadata_valid,asset_changed,static_transition,dynamic_continuation;wire[193:0]display_metadata;wire[31:0]metadata_errors;
 wire[1:0]display_slot;wire[2:0]quarantine;wire[15:0]expected_row;
 wire[20:0]display_base=display_slot==0?BASE0:display_slot==1?BASE1:BASE2;
 wire[20:0]render_base;
 wire[31:0]read_data;
 wire[20:0]fx_reader_base,fx_old,fx_new;wire fx_busy,fx_reader_valid,fx_req,fx_write,fx_ready,fx_rvalid;
 wire[20:0]fx_addr;wire[31:0]fx_data;
 wire[2:0]hold_slots={(render_base==BASE2)||(fx_busy&&(fx_old==BASE2||fx_new==BASE2)),(render_base==BASE1)||(fx_busy&&(fx_old==BASE1||fx_new==BASE1)),(render_base==BASE0)||(fx_busy&&(fx_old==BASE0||fx_new==BASE0))};
 wire[14:0]play_source={next_number,transition_duration,transition_mode,menu_control,run_control};wire[14:0]play_mem;
 tv_settings_cdc_v2 #(.WIDTH(15),.RESET_WORD(15'd0)) playback_settings(.sclk(clk50),.srst(start_rst),.dclk(mem_clk),.drst(mem_rst),.source(play_source),.dest(play_mem));
 wire playing=play_mem[0],menu=play_mem[1];wire[2:0]effect=play_mem[4:2];wire[1:0]effect_duration=play_mem[6:5];
 reg[193:0]timing_metadata;reg timing_metadata_valid,timing_present,timing_asset_changed,timing_continuation;
 always@(posedge mem_clk or posedge mem_rst)
 if(mem_rst)begin timing_metadata<=0;timing_metadata_valid<=0;timing_present<=0;timing_asset_changed<=0;timing_continuation<=0;end
 else begin timing_metadata<=display_metadata;timing_metadata_valid<=display_metadata_valid;timing_present<=monitor_present;timing_asset_changed<=asset_changed;timing_continuation<=dynamic_continuation;end
 reg[12:0]tick_phase;wire tick90=tick_phase>=4991;reg[31:0]elapsed,previous_duration;reg[7:0]seen_next;reg urgent;
 wire[32:0]present_elapsed={1'b0,elapsed}+((tick90&&playing&&!menu&&!fx_busy)?33'd1:33'd0);
 always@(posedge mem_clk or posedge mem_rst)if(mem_rst)begin tick_phase<=0;elapsed<=0;previous_duration<=0;seen_next<=0;urgent<=0;end
 else begin
  tick_phase<=tick90?tick_phase-13'd4991:tick_phase+13'd9;
  if(play_mem[14:7]!=seen_next)begin seen_next<=play_mem[14:7];urgent<=1;end
  if(timing_present)begin
   previous_duration<=timing_metadata[31:0];
   // Carry fractional-vblank lateness for SAME-ASSET animation/video. Reset
   // on asset/manual changes. Never shorten the authored frame duration or
   // accumulate more than one frame of catch-up after a slow decode.
   if(timing_continuation&&!urgent&&present_elapsed>=previous_duration)
    elapsed<=present_elapsed-previous_duration>previous_duration?previous_duration:present_elapsed-previous_duration;
   else elapsed<=0;
   if(timing_asset_changed)urgent<=0;
  end
  else if(tick90&&playing&&!menu&&!fx_busy&&elapsed!=32'hffffffff)elapsed<=elapsed+1'b1;
 end
 // Observer only: no rate signal feeds grants, memory, or presentation pacing.
 wire[15:0]rate_mem;
 db_rate_meter rate_meter(.clk(mem_clk),.rst(mem_rst),.tick90(tick90),
  .active(display_valid&&timing_metadata_valid&&!transport_reset),
  .paused(!playing||menu||fx_busy),.asset_changed(timing_asset_changed),
  .present(timing_present),.kind(timing_metadata[193:192]),.info(rate_mem));
 tv_settings_cdc_v2 #(.WIDTH(16),.RESET_WORD(16'd0)) rate_to_video(
  .sclk(mem_clk),.srst(mem_rst),.dclk(video_clk),.drst(video_rst),
  .source(rate_mem),.dest(rate_info));
 // Cache playback and memory request/response use acknowledged immutable bundles.
 wire[20:0]request_video,request_mem;wire[60:0]response_mem,response_video;wire[40:0]position_video,position_mem;
 reg[7:0]play_epoch,play_cache_generation;
 always@(posedge mem_clk or posedge mem_rst)
 if(mem_rst)begin play_epoch<=0;play_cache_generation<=0;end
 else if(timing_present&&timing_metadata_valid&&timing_metadata[193:192]==2&&timing_metadata[95:64]==0)begin play_epoch<=play_epoch+1'b1;play_cache_generation<=cache_generation;end
 wire matching_audio=cache_valid&&timing_metadata_valid&&timing_metadata[193:192]==2&&timing_metadata[127:96]==cache_asset&&play_cache_generation==cache_generation;
 reg audio_started;reg[20:0]audio_start_base;
 // Start when the framebuffer actually selects the first frame. Subsequent
 // buffer swaps never pause the audio clock. The scanout has two vblank
 // stages, so schedule future frame leases3024ticks ahead of audible time.
 wire audio_start_now=matching_audio&&!audio_started&&!fx_busy&&frame_tick&&fx_reader_valid&&fx_reader_base==audio_start_base;
 always@(posedge mem_clk or posedge mem_rst)
 if(mem_rst)begin audio_started<=0;audio_start_base<=0;end
 else begin
  if(!matching_audio)audio_started<=0;
  if(timing_present&&timing_metadata_valid&&timing_metadata[193:192]==2&&timing_metadata[95:64]==0)begin audio_started<=0;audio_start_base<=display_base;end
  else if(audio_start_now)audio_started<=1;
 end
 wire original_run=matching_audio&&playing&&!menu&&!fx_busy&&(audio_started||audio_start_now);
 wire[39:0]audio_control_mem={original_run,matching_audio,play_epoch,cache_generation,cache_samples,1'b0};wire[39:0]audio_control_video;
 tv_settings_cdc_v2 #(.WIDTH(40),.RESET_WORD(40'd0)) audio_control_cdc(.sclk(mem_clk),.srst(mem_rst),.dclk(video_clk),.drst(video_rst),.source(audio_control_mem),.dest(audio_control_video));
 tv_settings_cdc_v2 #(.WIDTH(21),.RESET_WORD(21'h100000)) audio_request_cdc(.sclk(video_clk),.srst(video_rst),.dclk(mem_clk),.drst(mem_rst),.source(request_video),.dest(request_mem));
 tv_settings_cdc_v2 #(.WIDTH(61),.RESET_WORD(61'd0)) audio_response_cdc(.sclk(mem_clk),.srst(mem_rst),.dclk(video_clk),.drst(video_rst),.source(response_mem),.dest(response_video));
 tv_settings_cdc_v2 #(.WIDTH(41),.RESET_WORD(41'd0)) audio_position_cdc(.sclk(video_clk),.srst(video_rst),.dclk(mem_clk),.drst(mem_rst),.source(position_video),.dest(position_mem));
 wire original_underflow;
 db_library_pcm_select audio_select(.clk(video_clk),.rst(audio_reset),.bg_valid(bg_valid),.bg_pcm(bg_pcm),.music_select(audio_music),.mute(audio_mute),.volume(audio_volume),
 .control(audio_control_video),.response(response_video),.request_word(request_video),.play_position(position_video),.pcm_valid(audio_valid),.pcm(audio_pcm),.underflow(original_underflow));
 wire audio_position_matches=position_mem[40:33]==play_epoch;
 wire[31:0]video_time90=audio_position_matches?position_mem[31:0]:32'd0;
 wire audio_finished=audio_position_matches&&position_mem[32];
 wire audio_hold_mem=matching_audio&&!audio_finished;
 reg[32:0]video_end90,video_late90,audio_lead90;
 always@(posedge mem_clk or posedge mem_rst)
 if(mem_rst)begin video_end90<=0;video_late90<=0;audio_lead90<=0;end
 else begin
  video_end90<={1'b0,timing_metadata[63:32]}+{1'b0,timing_metadata[31:0]};
  video_late90<=video_end90+{1'b0,timing_metadata[31:0]};
  audio_lead90<={1'b0,video_time90}+33'd3024;
 end
 wire video_drop_mem=matching_audio&&audio_position_matches&&({1'b0,video_time90}>video_late90);
 wire audio_read_req,audio_read_ready,audio_read_valid;wire[20:0]audio_read_addr;
 db_library_audio_reader audio_reader(.clk(mem_clk),.rst(mem_rst||transport_reset),.cache_valid(cache_valid),.cache_generation(cache_generation),.cache_samples(cache_samples),
 .request_word(request_mem),.mem_req(audio_read_req),.mem_addr(audio_read_addr),.mem_ready(audio_read_ready),.mem_rvalid(audio_read_valid),.mem_data(read_data),.response(response_mem));
 wire duration_ready=!display_valid||urgent||(matching_audio?((audio_started||audio_start_now)&&(audio_finished||audio_lead90>=video_end90)):elapsed>=timing_metadata[31:0]);
 reg[7:0]grant_mem;reg grant_outstanding;
 always@(posedge mem_clk or posedge mem_rst)if(mem_rst)begin grant_mem<=0;grant_outstanding<=0;end
 else begin
  if(monitor_begin)grant_outstanding<=0;
  if(!grant_outstanding&&!receive_active&&!pending_valid&&writer_idle&&session_ready&&playing&&!menu&&!fx_busy)begin grant_mem<=grant_mem+1'b1;grant_outstanding<=1;end
 end
 tv_settings_cdc_v2 #(.WIDTH(10),.RESET_WORD(10'd0)) grant_to_control(.sclk(mem_clk),.srst(mem_rst),.dclk(clk50),.drst(start_rst),.source({audio_hold_mem,video_drop_mem,grant_mem}),.dest({video_hold,video_drop,frame_grant}));
 wire bmp_failed,memory_writes_idle;
 db_library_transition_control #(.CLK_HZ(50000000)) transition_control(.clk(mem_clk),.rst(mem_rst),.frame_tick(frame_tick),.running(playing),.mode(effect),.duration(effect_duration),
 .source_valid(display_valid),.source_base(display_base),.source_portrait(1'b0),.source_native(1'b1),.source_index(timing_metadata[127:96]),
 .render_base(render_base),.cache_base(21'd462848),.cache_available(1'b1),.history_available(1'b1),.busy(fx_busy),.reader_valid(fx_reader_valid),.reader_base(fx_reader_base),.reader_portrait(),.reader_native(),
 .hold_old(fx_old),.hold_new(fx_new),.mem_req(fx_req),.mem_write(fx_write),.mem_addr(fx_addr),.mem_wdata(fx_data),.mem_ready(fx_ready),.mem_rvalid(fx_rvalid),.mem_rdata(read_data));
 wire writer_done;
 db_tune_write_retirement retire_writes(.clk(mem_clk),.rst(mem_rst),.accepted(writer_req&&writer_ready),.done(writer_done));
 // ready accepts a controller command at a logic edge; the RAM samples on the
 // opposite edge. Four later logic cycles cover that sample and write recovery.
 // This completion path survives transport reset so in-flight writes can drain.
 db_library_sampled_engine receiver(.cache_valid(cache_valid),.cache_loading(),.cache_percent(),.cache_asset(cache_asset),.cache_samples(cache_samples),.cache_generation(cache_generation),.session_confirm_src(session_confirm_src),.bmp_failed(bmp_failed),.file_room(file_room),.pcm_write(pcm_write),.pcm_data(pcm_data),.pcm_ready(pcm_ready),.pcm_free(pcm_free),.capture_clk(capture_clk),.clk50(clk50),.mem_clk(mem_clk),
  .transport_arst(transport_reset),.main_rst(mem_rst),.armed_epoch_src(32'd1),.armed_epoch_mem(32'd1),
  .forward_clk(forward_clk),.link_valid(link_valid),.link_data(link_data),.can_start(can_start),.credit_out(credit_out),.capture_failed(capture_failed),
  .base0(BASE0),.base1(BASE1),.base2(BASE2),.hold_slots(hold_slots),.vblank_event(frame_tick),.present_allow(playing&&!menu&&!fx_busy&&duration_ready),
  .mem_req(writer_req),.mem_address(writer_addr),.mem_data(writer_data),.mem_ready(writer_ready),.mem_done(writer_done),.memory_writes_idle(memory_writes_idle),
  .display_valid(display_valid),.display_slot(display_slot),.display_frame_id(display_frame),.display_epoch(display_epoch),
  .receive_active(receive_active),.pending_valid(pending_valid),.session_ready_mem(session_ready),.writes_idle(writer_idle),
  .expected_row(expected_row),.crc_errors(crc_errors),.rejected_records(rejected_records),.rejected_rows(rejected_rows),
  .quarantine_slots(quarantine),.transport_idle(transport_idle),.display_metadata_valid(display_metadata_valid),.display_metadata(display_metadata),.asset_changed(asset_changed),.static_transition(static_transition),.dynamic_continuation(dynamic_continuation),.metadata_errors(metadata_errors),.monitor_begin(monitor_begin),.monitor_complete(monitor_complete),.monitor_present(monitor_present),.monitor_cancel(monitor_cancel),.monitor_epoch(monitor_epoch),.monitor_frame(monitor_frame),.monitor_slot(monitor_slot));
 wire vreq,vready,vrvalid,underflow,committed;
 wire[20:0]vaddr;wire[23:0]read_rgb;wire[15:0]underflows,mismatches;
 wire mreq,mwrite,mready,mrvalid;wire[20:0]maddr;wire[31:0]mdata;
 cached_video_reader framebuffer(.mem_clk(mem_clk),.video_clk(video_clk),.mem_rst(mem_rst),.video_rst(video_rst),
  .frame_toggle(frame_toggle),.video_de(raw_de),.display_valid(fx_reader_valid),.display_base(fx_reader_base),
  .display_portrait(1'b0),.display_native_still(1'b1),.read_protect_enable(1'b0),.render_base(render_base),
  .rgb(read_rgb),.committed(committed),.underflow(underflow),.underflow_count(underflows),.read_mismatch_count(mismatches),
  .mem_req(vreq),.mem_addr(vaddr),.mem_ready(vready),.mem_rvalid(vrvalid),.mem_rdata(read_data));
 wire engine_ready;assign writer_ready=engine_ready&&writer_req;assign fx_ready=engine_ready&&!writer_req;
 wire engine_mux_req,engine_mux_write,engine_mux_ready,engine_mux_rvalid;wire[20:0]engine_mux_addr;wire[31:0]engine_mux_data;
 db_library_engine_mux audio_memory_mux(.clk(mem_clk),.rst(mem_rst),.a_req(audio_read_req),.a_addr(audio_read_addr),.a_ready(audio_read_ready),.a_rvalid(audio_read_valid),
 .e_req(writer_req||fx_req),.e_write(writer_req||fx_write),.e_addr(writer_req?writer_addr:fx_addr),.e_data(writer_req?writer_data:fx_data),.e_ready(engine_ready),.e_rvalid(fx_rvalid),
 .m_req(engine_mux_req),.m_write(engine_mux_write),.m_addr(engine_mux_addr),.m_data(engine_mux_data),.m_ready(engine_mux_ready),.m_rvalid(engine_mux_rvalid));
 animated_memory_arbiter bus(.clk(mem_clk),.rst(mem_rst),.v_req(vreq&&!audio_read_req),.v_addr(vaddr),.v_ready(vready),.v_rvalid(vrvalid),
  .e_req(engine_mux_req),.e_write(engine_mux_write),.e_addr(engine_mux_addr),.e_wdata(engine_mux_data),.e_ready(engine_mux_ready),.e_rvalid(engine_mux_rvalid),
  .m_req(mreq),.m_write(mwrite),.m_addr(maddr),.m_wdata(mdata),.m_ready(mready),.m_rvalid(mrvalid));
 // One elastic request stage breaks the shared address->row-match->ready
 // feedback loop for every client. Continuous accepted commands still run
 // at one per cycle. Retirement additionally follows physical writes here,
 // so a queued/stalled final word can never activate an incomplete frame.
 reg memory_pending,memory_write;reg[20:0]memory_address;reg[31:0]memory_data;
 reg[7:0]physical_writes;wire memory_ready;
 assign mready=!memory_pending||memory_ready;
 assign memory_writes_idle=!memory_pending&&physical_writes==0;
 always@(posedge mem_clk or posedge mem_rst)
 if(mem_rst)begin memory_pending<=0;memory_write<=0;memory_address<=0;memory_data<=0;physical_writes<=0;end
 else begin
  physical_writes<={physical_writes[6:0],memory_pending&&memory_ready&&memory_write};
  if(mready)begin memory_pending<=mreq;if(mreq)begin memory_write<=mwrite;memory_address<=maddr;memory_data<=mdata;end end
 end
 db_tune_main_sdram memory(.clk(mem_clk),.ram_clk(ram_clk),.rst(mem_rst),.req(memory_pending),.write(memory_write),.address(memory_address),.din(memory_data),
  .ready(memory_ready),.initialized(memory_initialized),.read_valid(mrvalid),.dout(read_data));
 assign rgb=committed?read_rgb:24'h000000;
 // Return command is held inactive until the actual UI command layer is added.
 assign command_out=enable?1'b0:1'bz;
 (* async_reg="true" *)reg[6:0]diag0,diag1,diag2;
 always @(posedge clk50 or posedge start_rst)
  if(start_rst)begin diag0<=0;diag1<=0;diag2<=0;end
  else begin
   diag0<={audio_underflow||original_underflow,underflow,(bmp_failed||capture_failed||crc_errors!=0||rejected_records!=0||rejected_rows!=0||metadata_errors!=0),display_valid,receive_active,memory_initialized,enable};
   diag1<=diag0;diag2<=diag1;
  end
 assign status=diag2;
endmodule
