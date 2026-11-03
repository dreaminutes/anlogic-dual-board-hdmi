`timescale 1ns/1ps
// Separate mixed-media stream diagnostic: real frozen SD backend, original FAT/GIF
// decode/scalers, bounded output slots supplied by the board queue.
// No PCM/SD arbitration changes are inferred here; audio is a later stage.
module db_library_loader #(parameter STILL_CYCLES=150000000)(
 output wire file_fifo_write,output wire[33:0]file_fifo_data,input wire file_fifo_full,file_finish_toggle,
 input wire auto_play,playing,menu_open,audio_hold,drop_video,input wire[7:0]next_number,
 input wire song_select,output wire pcm_valid,output wire[15:0]pcm_data,input wire pcm_ready,input wire[11:0]pcm_free,output wire audio_failed,
 input wire mem_clk,mem_rst,sd_clk,sd_fast_clk,sd_sample_clk,sd_rst,memory_initialized,enable,output wire monitor_sd_request,monitor_byte_backpressure,monitor_prefetch,
 input wire[3:0]sd_dat,inout wire sd_cmd,output wire sd_dclk,
 output wire mem_req,mem_write,output wire[20:0]mem_address,output wire[31:0]mem_data,input wire mem_ready,mem_rvalid,input wire[31:0]mem_rdata,
 output wire loaded,card_initialized,failed,output wire[7:0]error_code,
 output wire bridge_overflow,cancel_stream,output wire[31:0]total_frames,
 output wire alloc_valid,alloc_static,output wire[1:0]alloc_kind,
 output wire[31:0]alloc_epoch,alloc_asset,alloc_frame,alloc_pts,alloc_duration,
 input wire alloc_ready,input wire[1:0]alloc_slot,input wire[31:0]alloc_token,input wire[20:0]alloc_base,
 output wire commit_valid,commit_static,output wire[1:0]commit_slot,output wire[31:0]commit_token,input wire commit_ready,
 input wire writes_idle,reads_idle,frame_finished,input wire[31:0]finished_asset,
 input wire[1:0]resident_slots,output wire evict_valid,output wire[1:0]evict_slot,output wire[31:0]evict_token,input wire evict_ready
);
 wire hw_init,hw_failed;wire[7:0]hw_error;wire[31:0]sd_data;wire sd_valid,sd_end,sd_req;wire[31:0]sd_lba;wire[3:0]sd_count,visual_count,mux_count;wire sd_audio,mux_audio,mux_req;wire[31:0]mux_lba;
 reg init_committed,fault_seen;reg[7:0]fault_code_hold;
 wire backend_reset=sd_rst||!enable;
 always@(posedge sd_clk or posedge backend_reset)
  if(backend_reset)begin init_committed<=0;fault_seen<=0;fault_code_hold<=0;end
  else begin
   if(hw_init&&!hw_failed&&!fault_seen)init_committed<=1;
   if(hw_failed&&!fault_seen)begin fault_seen<=1;fault_code_hold<=hw_error;end
  end
 (* async_reg="true" *)reg[2:0]fault_sync;
 reg[7:0]fault_code_mem;reg fault_committed;
 always@(posedge mem_clk or posedge mem_rst)
  if(mem_rst)begin fault_sync<=0;fault_code_mem<=0;fault_committed<=0;end
  else begin
   fault_sync<={fault_sync[1:0],fault_seen};
   // Terminal code is held in source domain before flag traverses3 stages.
   if(fault_sync[2]&&!fault_committed)begin fault_code_mem<=fault_code_hold;fault_committed<=1;end
   if(cancel_stream)begin fault_code_mem<=0;fault_committed<=0;end
  end
 (* async_reg="true" *)reg[2:0]init_sync,enable_sync,overflow_sync;
 always @(posedge mem_clk or posedge mem_rst)
  if(mem_rst)begin init_sync<=0;enable_sync<=0;overflow_sync<=0;end
  else begin init_sync<={init_sync[1:0],init_committed};enable_sync<={enable_sync[1:0],enable};overflow_sync<={overflow_sync[1:0],bridge_overflow};end
 assign card_initialized=init_sync[2];
 wire visual_req;wire[31:0]visual_lba;wire[31:0]visual_data;wire visual_valid,visual_end;
 assign monitor_sd_request=visual_req;
 wire mux_valid,mux_end,audio_req,audio_valid,audio_end,catalog_ready;wire[31:0]audio_lba;
 wire[31:0]audio_data_base,audio_fat_base,audio_cluster_count,song0_cluster,song0_size,song1_cluster,song1_size;
 wire[7:0]audio_spc;wire[2:0]audio_shift;wire[1:0]song_count;
 db_av_sector_bridge bridge(.visual_audio(mux_audio),.sd_audio(sd_audio),.visual_count(mux_count),.sd_count(sd_count),.mem_clk(mem_clk),.mem_rst(mem_rst||cancel_stream),.sd_clk(sd_clk),.sd_rst(backend_reset),
  .visual_req(mux_req),.visual_lba(mux_lba),.sd_req(sd_req),.sd_lba(sd_lba),
  .sd_data(sd_data),.sd_valid(sd_valid),.sd_end(sd_end),.visual_data(visual_data),
  .visual_valid(mux_valid),.visual_end(mux_end),.overflow(bridge_overflow));
 db_fast24_sector_backend backend(.fast_clk(sd_fast_clk),.sample_clk(sd_sample_clk),.sd_audio(sd_audio),.sd_count(sd_count),.clk(sd_clk),.rst(backend_reset),.sd_dat(sd_dat),.sd_cmd(sd_cmd),.sd_dclk(sd_dclk),
  .initialized(hw_init),.failed(hw_failed),.error_code(hw_error),.sd_req(sd_req),.sd_lba(sd_lba),.sd_data(sd_data),.sd_valid(sd_valid),.sd_end(sd_end));
 db_av_sector_mux scheduler(.clk(mem_clk),.rst(mem_rst||cancel_stream),.media_req(visual_req),.media_lba(visual_lba),.media_count(visual_count),
  .audio_req(audio_req),.audio_lba(audio_lba),.request(mux_req),.lba(mux_lba),.count(mux_count),.audio(mux_audio),
  .data(visual_data),.valid(mux_valid),.done(mux_end),.media_valid(visual_valid),.media_done(visual_end),.audio_valid(audio_valid),.audio_done(audio_end));
 db_song_wav_source music(.clk(mem_clk),.rst(mem_rst||cancel_stream),.enable(!cancel_stream),.catalog_ready(catalog_ready),.song_count(song_count),.song_select(song_select),
  .song0_cluster(song0_cluster),.song0_size(song0_size),.song1_cluster(song1_cluster),.song1_size(song1_size),
  .data_base(audio_data_base),.fat_base(audio_fat_base),.cluster_count(audio_cluster_count),.sectors_per_cluster(audio_spc),.cluster_shift(audio_shift),
  .sd_req(audio_req),.sd_lba(audio_lba),.sd_data(visual_data),.sd_valid(audio_valid),.sd_end(audio_end),
  .pcm_valid(pcm_valid),.pcm_data(pcm_data),.pcm_ready(pcm_ready),.pcm_free(pcm_free),.failed(audio_failed),.active());
 wire file_failed;wire[7:0]file_error;
 assign cancel_stream=!enable_sync[2];
 assign failed=file_failed||overflow_sync[2]||fault_committed;assign error_code=fault_committed?fault_code_mem:file_failed?file_error:overflow_sync[2]?8'hf0:8'd0;
 db_library_file_catalog #(.STILL_CYCLES(STILL_CYCLES)) files(.audio_hold(audio_hold),.drop_video(drop_video),.auto_play(auto_play),.playing(playing),.menu_open(menu_open),.next_number(next_number),.file_fifo_write(file_fifo_write),.file_fifo_data(file_fifo_data),.file_fifo_full(file_fifo_full),.file_finish_toggle(file_finish_toggle),.catalog_ready(catalog_ready),.audio_data_base(audio_data_base),.audio_fat_base(audio_fat_base),.audio_cluster_count(audio_cluster_count),.audio_spc(audio_spc),.audio_shift(audio_shift),
  .song_count(song_count),.song0_cluster(song0_cluster),.song0_size(song0_size),.song1_cluster(song1_cluster),.song1_size(song1_size),.monitor_byte_backpressure(monitor_byte_backpressure),.monitor_prefetch(monitor_prefetch),.clk(mem_clk),.rst(mem_rst),.cancel(cancel_stream),.memory_initialized(memory_initialized),.sd_initialized(init_sync[2]&&enable_sync[2]),.frame_finished(frame_finished),.finished_asset(finished_asset),.resident_slots(resident_slots),.evict_valid(evict_valid),.evict_slot(evict_slot),.evict_token(evict_token),.evict_ready(evict_ready),
  .sd_sec_read(visual_req),.sd_sec_read_count(visual_count),.sd_sec_read_addr(visual_lba),.sd_sec_read_data(visual_data),.sd_sec_read_data_valid(visual_valid),.sd_sec_read_end(visual_end),
  .alloc_valid(alloc_valid),.alloc_static(alloc_static),.alloc_kind(alloc_kind),.alloc_epoch(alloc_epoch),.alloc_asset(alloc_asset),.alloc_frame(alloc_frame),.alloc_pts(alloc_pts),.alloc_duration(alloc_duration),
  .alloc_ready(alloc_ready),.alloc_slot(alloc_slot),.alloc_token(alloc_token),.alloc_base(alloc_base),
  .commit_valid(commit_valid),.commit_static(commit_static),.commit_slot(commit_slot),.commit_token(commit_token),.commit_ready(commit_ready),
  .mem_req(mem_req),.mem_write(mem_write),.mem_address(mem_address),.mem_data(mem_data),.mem_ready(mem_ready),.mem_rvalid(mem_rvalid),.mem_rdata(mem_rdata),.writes_idle(writes_idle),.reads_idle(reads_idle),
  .done(loaded),.failed(file_failed),.error_code(file_error),.total_frames(total_frames),.current_file(),.found_files());
endmodule
