`timescale 1ns/1ps
`include "db_frame_descriptor.vh"
// Full basic media/UI/audio candidate. SD50 with a phase-staged input,
// source link25; BMP/GIF/media ownership and authored timing retained.
module db_library_secondary_board #(parameter STILL_CYCLES=150000000)(
 input wire clk,sw0,credit_in,command_in,input wire[7:0]reserved,
 input wire[3:0]sd_dat,inout wire sd_cmd,output wire sd_dclk,
 output wire forward_clk,link_valid,output wire[7:0]link_data,led
);
 wire rst_start,mem_rst,mem_clk,ram_clk,unused_clk;
 media_power_reset reset_power(.clk(clk),.rst(rst_start));
 db_mem50_pll memory_pll(.refclk(clk),.reset(1'b0),.clk0_out(mem_clk),.clk1_out(unused_clk),.clk2_out(ram_clk));
 reset_sync reset_memory(.clk(mem_clk),.arst(rst_start),.rst(mem_rst));
 (* syn_keep=1 *)wire enable;
 db_av_start startup(.clk(clk),.rst(rst_start),.sw0(sw0),.enable(enable));
 wire sd_core_clk,sd_fast_clk,sd_sample_clk,sd_locked,sd_reset;
 db_fast24_sd_pll sd_pll(.refclk(clk),.reset(1'b0),.clk0_out(sd_core_clk),.clk1_out(sd_fast_clk),.clk2_out(sd_sample_clk),.locked(sd_locked));
 reset_sync reset_sd(.clk(sd_core_clk),.arst(rst_start||!sd_locked),.rst(sd_reset));
 reg link_clk=0;
 // Symmetric divide-by-two:20ns high/20ns low.
 always @(posedge clk)link_clk<=~link_clk;
 wire monitor_sd_request,monitor_byte_backpressure,monitor_prefetch;
 wire cancel_stream,memory_initialized,loaded,card_initialized,failed,overflow,port_failed;
 wire[7:0]error_code;wire[31:0]total_frames;
 wire alloc_valid,alloc_static,alloc_ready,commit_valid,commit_static,commit_ready;wire[1:0]alloc_kind,alloc_slot,commit_slot;
 wire[31:0]alloc_epoch,alloc_asset,alloc_frame,alloc_pts,alloc_duration,alloc_token,commit_token;wire[20:0]alloc_base;
 wire evict_valid,evict_ready;wire[1:0]evict_slot;wire[31:0]evict_token;
 wire frame_valid,frame_is_still,frame_take,finish_valid,finish_ready;wire[216:0]frame_descriptor;
 wire[4:0]busy_slots,quarantine_slots;wire[1:0]resident_slots;wire sender_busy,sender_quarantined;wire[31:0]rejected_events;
 wire producer_req,producer_write,producer_ready,producer_rvalid;wire[20:0]producer_address;wire[31:0]producer_data,producer_rdata;
 wire sender_req,sender_ready,sender_rvalid;wire[20:0]sender_address;wire[31:0]sender_rdata;
 wire mem_req,mem_write,mem_ready,mem_rvalid;wire[20:0]mem_address;wire[31:0]mem_data,mem_rdata;
 wire writes_idle,sender_reads_idle,producer_reads_idle,memory_idle;wire[3:0]pending_reads;wire[31:0]unexpected_responses;
 wire pcm_valid,pcm_ready,pcm_link_valid,pcm_take,audio_failed,audio_active;
 wire[15:0]pcm_data,pcm_link_data;wire[11:0]pcm_free,pcm_used;
 wire hello_retry;
 wire md_valid,md_ready,mp_valid,mp_ready,md_done;wire[7:0]md_type,mp_data;wire[31:0]md_frame;wire[15:0]md_sequence,md_length;
 wire file_fifo_write,file_fifo_full,file_fifo_empty,file_fifo_read,file_finish,file_failed;
 wire[33:0]file_fifo_data,file_fifo_q;
 wire fd_valid,fd_ready,fp_valid,fp_ready,fd_done;wire[7:0]fd_type,fp_data;wire[31:0]fd_frame;wire[15:0]fd_length;
 db_opt_word_fifo file_fifo(.rst(rst_start||!enable||mem_rst),.clkw(mem_clk),.clkr(link_clk),.we(file_fifo_write),.re(file_fifo_read),.di(file_fifo_data),.dout(file_fifo_q),.empty_flag(file_fifo_empty),.full_flag(file_fifo_full),.wrusedw());
 db_library_file_sender file_sender(.clk(link_clk),.rst(rst_start||!enable),.fifo_data(file_fifo_q),.fifo_empty(file_fifo_empty),.fifo_read(file_fifo_read),
 .descriptor_valid(fd_valid),.descriptor_ready(fd_ready),.packet_type(fd_type),.frame_id(fd_frame),.payload_length(fd_length),
 .payload_valid(fp_valid),.payload_ready(fp_ready),.payload_data(fp_data),.packet_done(fd_done),.finish_toggle(file_finish),.failed(file_failed));
 wire[31:0]requested_control,control_mem,control_link;wire command_valid;
 db_full_command_rx commands(.clk(clk),.rst(rst_start||!enable),.serial_in(command_in),.control_word(requested_control),.command_valid(command_valid));
 tv_settings_cdc_v2 #(.WIDTH(32),.RESET_WORD(32'd0)) control_to_memory(.sclk(clk),.srst(rst_start),.dclk(mem_clk),.drst(mem_rst),.source(requested_control),.dest(control_mem));
 tv_settings_cdc_v2 #(.WIDTH(32),.RESET_WORD(32'd0)) control_to_link(.sclk(clk),.srst(rst_start),.dclk(link_clk),.drst(rst_start),.source(requested_control),.dest(control_link));
 db_library_loader #(.STILL_CYCLES(STILL_CYCLES)) loader(.audio_hold(control_mem[27]),.drop_video(control_mem[26]),.auto_play(control_mem[1]),.playing(control_mem[2]),.menu_open(control_mem[3]),.next_number(control_mem[16:9]),.file_fifo_write(file_fifo_write),.file_fifo_data(file_fifo_data),.file_fifo_full(file_fifo_full),.file_finish_toggle(file_finish),.song_select(control_mem[0]),.pcm_valid(pcm_valid),.pcm_data(pcm_data),.pcm_ready(pcm_ready),.pcm_free(pcm_free),.audio_failed(audio_failed),.monitor_sd_request(monitor_sd_request),.monitor_byte_backpressure(monitor_byte_backpressure),.monitor_prefetch(monitor_prefetch),.mem_clk(mem_clk),.mem_rst(mem_rst),.sd_clk(sd_core_clk),.sd_fast_clk(sd_fast_clk),.sd_sample_clk(sd_sample_clk),.sd_rst(sd_reset),.memory_initialized(memory_initialized),.enable(enable&&!rst_start&&sd_locked),
  .sd_dat(sd_dat),.sd_cmd(sd_cmd),.sd_dclk(sd_dclk),
  .mem_req(producer_req),.mem_write(producer_write),.mem_address(producer_address),.mem_data(producer_data),.mem_ready(producer_ready),.mem_rvalid(producer_rvalid),.mem_rdata(producer_rdata),
  .loaded(loaded),.card_initialized(card_initialized),.failed(failed),.error_code(error_code),.bridge_overflow(overflow),.cancel_stream(cancel_stream),.total_frames(total_frames),.frame_finished(finish_valid&&finish_ready),.finished_asset(frame_descriptor[`DB_FRAME_DESCRIPTOR_ASSET]),.resident_slots(resident_slots),.evict_valid(evict_valid),.evict_slot(evict_slot),.evict_token(evict_token),.evict_ready(evict_ready),
  .alloc_valid(alloc_valid),.alloc_static(alloc_static),.alloc_kind(alloc_kind),.alloc_epoch(alloc_epoch),.alloc_asset(alloc_asset),.alloc_frame(alloc_frame),.alloc_pts(alloc_pts),.alloc_duration(alloc_duration),
  .alloc_ready(alloc_ready),.alloc_slot(alloc_slot),.alloc_token(alloc_token),.alloc_base(alloc_base),
  .commit_valid(commit_valid),.commit_static(commit_static),.commit_slot(commit_slot),.commit_token(commit_token),.commit_ready(commit_ready),.writes_idle(writes_idle),.reads_idle(producer_reads_idle));
 wire transport_drained;
 db_av_queue queue(.clk(mem_clk),.rst(mem_rst),.cancel(cancel_stream),.transport_drained(transport_drained),.writes_idle(writes_idle),.reads_idle(sender_reads_idle),
  .alloc_valid(alloc_valid),.alloc_static(alloc_static),.alloc_kind(alloc_kind),.alloc_epoch(alloc_epoch),.alloc_asset(alloc_asset),.alloc_frame(alloc_frame),.alloc_pts(alloc_pts),.alloc_duration(alloc_duration),
  .alloc_ready(alloc_ready),.alloc_slot(alloc_slot),.alloc_token(alloc_token),.alloc_base(alloc_base),
  .commit_valid(commit_valid),.commit_static(commit_static),.commit_slot(commit_slot),.commit_token(commit_token),.commit_ready(commit_ready),
  .reuse_valid(1'b0),.reuse_slot(2'd0),.reuse_old_token(32'd0),.reuse_epoch(32'd0),.reuse_frame(32'd0),.reuse_pts(32'd0),.reuse_duration(32'd0),.reuse_ready(),.reuse_new_token(),
  .evict_valid(evict_valid),.evict_slot(evict_slot),.evict_token(evict_token),.evict_ready(evict_ready),
  .frame_valid(frame_valid),.frame_is_still(frame_is_still),.frame_take(frame_take),.frame_descriptor(frame_descriptor),.finish_valid(finish_valid),.finish_ready(finish_ready),
  .busy_slots(busy_slots),.quarantine_slots(quarantine_slots),.resident_slots(resident_slots),.sender_busy(sender_busy),.sender_quarantined(sender_quarantined),.rejected_events(rejected_events));
 (* syn_keep=1 *)wire tx_reset=rst_start||!enable;
 wire word_req,word_ready,word_done;wire[20:0]word_address;wire[31:0]word_data;
 wire read_req,read_ready,read_valid;wire[20:0]read_address;wire[31:0]read_data;
 wire raw_clk,raw_valid,credit_seen,echo_seen,sender_failed;wire[7:0]raw_data;wire[31:0]frame_id;
 // 1024 samples (~21ms) here plus the unchanged4096-sample main FIFO.
 // Reallocate two BRAMs to the file sender's reused metadata/data buffer.
 wire[10:0]audio_free_small,audio_used_small;
 assign pcm_free={1'b0,audio_free_small};assign pcm_used={1'b0,audio_used_small};
 db_av_pcm_fifo #(.AW(10)) audio_fifo(.rst(tx_reset||mem_rst),.wr_clk(mem_clk),.rd_clk(link_clk),
  .wr_valid(pcm_valid),.wr_data(pcm_data),.wr_ready(pcm_ready),.wr_free(audio_free_small),
  .rd_valid(pcm_link_valid),.rd_data(pcm_link_data),.rd_take(pcm_take),.rd_used(audio_used_small));
 db_start24_media_sender sender(.link_clk(link_clk),.rst(tx_reset),.session_confirmed(control_link[25]),.hello_retry(hello_retry),.frame_id(frame_id),.failed(sender_failed),
  .descriptor_valid(md_valid),.descriptor_ready(md_ready),.kind(md_type),.length(md_length),.sequence_number(md_sequence),.wire_frame(md_frame),
  .payload_valid(mp_valid),.payload_ready(mp_ready),.payload(mp_data),.done(md_done),
  .read_req(word_req),.read_ready(word_ready),.read_done(word_done),.read_address(word_address),.read_data(word_data));
 wire selected_fd,selected_busy;reg file_packet;
 wire mux_md_valid,mux_md_ready,mux_mp_ready,mux_md_done;
 reg mux_busy;
 reg[7:0]consumed_grant;
 wire frame_permission=control_link[24:17]!=consumed_grant&&control_link[2]&&!control_link[3];
 wire file_eligible=control_link[25]&&(fd_type!=8'h30||frame_permission);
 wire raster_eligible=md_type!=8'h13||frame_permission;
 wire choose_file=fd_valid&&file_eligible&&((fd_type!=8'h31&&fd_type!=8'h34)||control_link[31])&&!(md_valid&&md_type==8'h03);
 always@(posedge link_clk or posedge rst_start)if(rst_start)consumed_grant<=0;
 else if(!enable)consumed_grant<=0;
 else if(mux_md_valid&&mux_md_ready&&((choose_file&&fd_type==8'h30)||(!choose_file&&md_type==8'h13)))consumed_grant<=control_link[24:17];
 wire using_file=mux_busy?file_packet:choose_file;
 assign mux_md_valid=mux_busy?1'b0:(choose_file?fd_valid:(md_valid&&raster_eligible));
 assign fd_ready=!mux_busy&&choose_file&&mux_md_ready;assign md_ready=!mux_busy&&!choose_file&&raster_eligible&&mux_md_ready;
 assign fp_ready=mux_busy&&file_packet&&mux_mp_ready;assign mp_ready=mux_busy&&!file_packet&&mux_mp_ready;
 assign fd_done=mux_md_done&&mux_busy&&file_packet;assign md_done=mux_md_done&&mux_busy&&!file_packet;
 always@(posedge link_clk or posedge rst_start)if(rst_start)begin mux_busy<=0;file_packet<=0;end
 else if(!enable)begin mux_busy<=0;file_packet<=0;end
 else begin if(mux_md_valid&&mux_md_ready)begin mux_busy<=1;file_packet<=choose_file;end if(mux_md_done)mux_busy<=0;end
 db_start24_link_mux transport(.clk(link_clk),.rst(tx_reset),.hello_retry(hello_retry),.session_confirmed(control_link[25]),.credit_in(credit_in),.media_descriptor_valid(mux_md_valid),.media_descriptor_ready(mux_md_ready),
  .media_type(using_file?fd_type:md_type),.media_frame(using_file?fd_frame:md_frame),.media_sequence(using_file?16'd0:md_sequence),.media_length(using_file?fd_length:md_length),
  .media_payload_valid(mux_busy&&(file_packet?fp_valid:mp_valid)),.media_payload_ready(mux_mp_ready),.media_payload(file_packet?fp_data:mp_data),.media_done(mux_md_done),
  .pcm_valid(pcm_link_valid),.pcm_data(pcm_link_data),.pcm_used(pcm_used),.pcm_take(pcm_take),
  .forward_clk(raw_clk),.link_valid(raw_valid),.link_data(raw_data),.audio_active(audio_active));
 db_burstrow_prefetch_cdc read_bridge(.src_clk(link_clk),.dst_clk(mem_clk),.arst(tx_reset),
  .src_req(word_req),.src_ready(word_ready),.src_address(word_address),.src_done(word_done),.src_data(word_data),
  .mem_req(read_req),.mem_address(read_address),.mem_ready(read_ready),.mem_rvalid(read_valid),.mem_data(read_data));
 db_av_lease_port cache_port(.clk(mem_clk),.rst(mem_rst),.cancel(cancel_stream),.req(read_req),.address(read_address),.ready(read_ready),.rvalid(read_valid),.data(read_data),
  .frame_valid(frame_valid),.frame_take(frame_take),.frame_descriptor(frame_descriptor),.finish_valid(finish_valid),.finish_ready(finish_ready),
  .ram_req(sender_req),.ram_address(sender_address),.ram_ready(sender_ready),.ram_rvalid(sender_rvalid),.ram_data(sender_rdata),.reads_idle(sender_reads_idle),.failed(port_failed),.transport_drained(transport_drained));
 db_gifpipe_arbiter arbiter(.gif_mode(alloc_kind==2'd1),.batch_enable(alloc_kind==2'd2),.clk(mem_clk),.rst(mem_rst),.cancel(cancel_stream),
  .producer_req(producer_req),.producer_write(producer_write),.producer_address(producer_address),.producer_data(producer_data),.producer_ready(producer_ready),.producer_rvalid(producer_rvalid),.producer_rdata(producer_rdata),
  .sender_req(sender_req),.sender_address(sender_address),.sender_ready(sender_ready),.sender_rvalid(sender_rvalid),.sender_rdata(sender_rdata),
  .mem_req(mem_req),.mem_write(mem_write),.mem_address(mem_address),.mem_data(mem_data),.mem_ready(mem_ready),.mem_rvalid(mem_rvalid),.mem_rdata(mem_rdata),
  .writes_idle(writes_idle),.sender_reads_idle(sender_reads_idle),.producer_reads_idle(producer_reads_idle),.memory_idle(memory_idle),.pending_reads(pending_reads),.unexpected_responses(unexpected_responses));
 db_av3_sdram memory(.clk(mem_clk),.ram_clk(ram_clk),.rst(mem_rst),.req(mem_req),.write(mem_write),.address(mem_address),.din(mem_data),
  .ready(mem_ready),.initialized(memory_initialized),.read_valid(mem_rvalid),.dout(mem_rdata));
 assign forward_clk=tx_reset?1'bz:raw_clk;assign link_valid=tx_reset?1'bz:raw_valid;assign link_data=tx_reset?8'bzzzzzzzz:raw_data;
 // Sticky diagnostic errors cross only into the first LED synchronizer.
 // Keep this aggregate named so its asynchronous entry can be constrained
 // without exempting data/control paths or subsequent synchronizer stages.
 // Register the memory-domain reduction before the LED-only CDC entry.
 // This level never controls media, ownership, or transport handshakes.
 (* syn_keep=1,syn_preserve=1 *)reg mem_error_status=0;
 always @(posedge mem_clk)begin
  if(mem_rst)mem_error_status<=0;
  else mem_error_status<=audio_failed||failed||overflow||port_failed||(|rejected_events)||(|unexpected_responses);
 end
 (* syn_keep=1 *)wire async_error_status=mem_error_status||sender_failed||file_failed;
 (* async_reg="true" *)reg[4:0]diag0=0,diag1=0,diag2=0;
 always @(posedge clk)begin
  diag0<={1'b0,async_error_status,audio_active,loaded,card_initialized};diag1<=diag0;diag2<=diag1;
 end
 assign led={1'b1,diag2[4],diag2[3],diag2[2],diag2[1],diag2[0],enable&&!rst_start,audio_active};
endmodule
