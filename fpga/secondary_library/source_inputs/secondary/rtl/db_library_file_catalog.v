`timescale 1ns/1ps
// Unified file producer: static BMP owns the independent two-slot lifecycle;
// GIF and DBV video share the SAME three dynamic slots and physical sender.
// Original frozen readers/decoders remain available in previous diagnostics.
module db_library_file_catalog #(parameter STILL_CYCLES=150000000)(
 input wire auto_play,playing,menu_open,audio_hold,drop_video,input wire[7:0]next_number,
 output wire file_fifo_write,output wire[33:0]file_fifo_data,input wire file_fifo_full,file_finish_toggle,
 output wire catalog_ready,output wire[31:0]audio_data_base,audio_fat_base,audio_cluster_count,
 output wire[7:0]audio_spc,output wire[2:0]audio_shift,
 output wire[1:0]song_count,output wire[31:0]song0_cluster,song0_size,song1_cluster,song1_size,
 input wire clk,rst,cancel,memory_initialized,sd_initialized,output wire monitor_byte_backpressure,monitor_prefetch,
 input wire frame_finished,input wire[31:0]finished_asset,
 output wire sd_sec_read,output wire[31:0]sd_sec_read_addr,output wire[3:0]sd_sec_read_count,
 input wire[31:0]sd_sec_read_data,input wire sd_sec_read_data_valid,sd_sec_read_end,
 output wire alloc_valid,alloc_static,output wire[1:0]alloc_kind,
 output wire[31:0]alloc_epoch,alloc_asset,alloc_frame,alloc_pts,alloc_duration,
 input wire alloc_ready,input wire[1:0]alloc_slot,input wire[31:0]alloc_token,input wire[20:0]alloc_base,
 output wire commit_valid,commit_static,output wire[1:0]commit_slot,output wire[31:0]commit_token,input wire commit_ready,
 input wire[1:0]resident_slots,output wire evict_valid,output wire[1:0]evict_slot,output wire[31:0]evict_token,input wire evict_ready,
 output wire mem_req,mem_write,output wire[20:0]mem_address,output wire[31:0]mem_data,
 input wire mem_ready,mem_rvalid,input wire[31:0]mem_rdata,input wire writes_idle,reads_idle,
 output reg done,failed,output reg[7:0]error_code,output reg[31:0]total_frames,
 output wire[31:0]current_file,output wire[31:0]found_files
);
 localparam INIT=0,SCAN=1,OPEN=2,DECODE=3,NEXT=4,FINISHED=5,FAULT=6,WAIT_SEND=7,WAIT_OPEN=8;
 reg[7:0]seen_next;reg skip_pending,stop_feed,file_reset,manual_advance;reg[27:0]still_time;
 wire internal_cancel=cancel||file_reset;
 reg[3:0]state;reg[31:0]file_index;reg scan_start,open_start,start_file,eof_seen,file_done_seen;
 reg[31:0]file_committed_count,file_finished_count;
 wire local_rst=rst||cancel;
 wire file_opened;wire scan_done,reader_busy,reader_error,byte_valid,byte_ready,stream_done,top_down;
 wire video_word_valid,video_word_ready;wire[31:0]video_word_data;
 assign monitor_byte_backpressure=(byte_valid&&!byte_ready)||(video_word_valid&&!video_word_ready);
 reg[1:0]kind;wire[1:0]kind_metadata;wire[7:0]byte_data,reader_error_code;wire[15:0]width,height;wire[31:0]file_size,pixel_offset,row_stride;
 db_library_media_reader reader(.stream_cancel(file_reset),.catalog_ready(catalog_ready),.audio_data_base(audio_data_base),.audio_fat_base(audio_fat_base),.audio_cluster_count(audio_cluster_count),.audio_spc(audio_spc),.audio_shift(audio_shift),
  .song_count(song_count),.song0_cluster(song0_cluster),.song0_size(song0_size),.song1_cluster(song1_cluster),.song1_size(song1_size),.word_stream_enable(kind==2),.stream_word_valid(video_word_valid),.stream_word_data(video_word_data),.stream_word_ready(video_word_ready),.monitor_prefetch(monitor_prefetch),.clk(clk),.rst(local_rst),.sd_init_done(sd_initialized),.scan_start(scan_start),.scan_done(scan_done),.file_count(found_files),
  .file_index(file_index),.open_start(open_start),.file_opened(file_opened),.byte_valid(byte_valid),.byte_data(byte_data),.byte_ready(byte_ready),.stream_done(stream_done),
  .selected_kind(kind_metadata),.selected_width(width),.selected_height(height),.selected_top_down(top_down),.selected_size(file_size),.selected_pixel_offset(pixel_offset),.selected_row_stride(row_stride),
  .busy(reader_busy),.error(reader_error),.error_code(reader_error_code),.sd_sec_read(sd_sec_read),.sd_sec_read_count(sd_sec_read_count),.sd_sec_read_addr(sd_sec_read_addr),.sd_sec_read_data(sd_sec_read_data),.sd_sec_read_data_valid(sd_sec_read_data_valid),.sd_sec_read_end(sd_sec_read_end));
 assign current_file=file_index;
wire b_alloc_valid; wire b_alloc_static; wire[1:0] b_alloc_kind; wire[31:0] b_alloc_epoch; wire[31:0] b_alloc_asset; wire[31:0] b_alloc_frame; wire[31:0] b_alloc_pts; wire[31:0] b_alloc_duration; wire b_commit_valid; wire b_commit_static; wire[1:0] b_commit_slot; wire[31:0] b_commit_token; wire b_mem_req; wire b_mem_write; wire[20:0] b_mem_address; wire[31:0] b_mem_data;
 wire b_ready,b_busy,b_done,b_failed;wire[7:0]b_error;
 wire b_file_write,v_file_write;wire[33:0]b_file_data,v_file_data;wire file_busy;
 assign file_fifo_write=kind==2?v_file_write:b_file_write;assign file_fifo_data=kind==2?v_file_data:b_file_data;
 db_full_file_source b_producer(.clk(clk),.rst(local_rst||file_reset),.start(start_file&&kind==0),
 .metadata({32'd270000,{31'd0,top_down},row_stride,pixel_offset,height,width,file_size,file_index,32'd1}),
 .byte_valid(byte_valid&&state==DECODE&&!file_done_seen&&!stop_feed&&kind==0),.byte_data(byte_data),.byte_ready(b_ready),.busy(file_busy),.done(b_done),.failed(b_failed),
 .fifo_write(b_file_write),.fifo_data(b_file_data),.fifo_full(file_fifo_full),.finish_toggle(file_finish_toggle));
 assign b_alloc_valid=0;assign b_alloc_static=1;assign b_alloc_kind=0;assign b_alloc_epoch=0;assign b_alloc_asset=0;assign b_alloc_frame=0;assign b_alloc_pts=0;assign b_alloc_duration=0;
 assign b_commit_valid=0;assign b_commit_static=1;assign b_commit_slot=0;assign b_commit_token=0;
 assign b_mem_req=0;assign b_mem_write=0;assign b_mem_address=0;assign b_mem_data=0;assign b_error=8'h91;
wire g_alloc_valid; wire g_alloc_static; wire[1:0] g_alloc_kind; wire[31:0] g_alloc_epoch; wire[31:0] g_alloc_asset; wire[31:0] g_alloc_frame; wire[31:0] g_alloc_pts; wire[31:0] g_alloc_duration; wire g_commit_valid; wire g_commit_static; wire[1:0] g_commit_slot; wire[31:0] g_commit_token; wire g_mem_req; wire g_mem_write; wire[20:0] g_mem_address; wire[31:0] g_mem_data;
 wire g_ready,g_busy,g_done,g_failed;wire[7:0]g_error;
 db_gifpipe_producer g_producer(
  .clk(clk),.rst(rst),.cancel(internal_cancel),.start(start_file&&kind==2'd1),.epoch(32'd1),.asset(file_index),
  .byte_valid(byte_valid&&state==DECODE&&!file_done_seen&&!stop_feed&&kind==2'd1),.byte_data(byte_data),.byte_ready(g_ready),.alloc_valid(g_alloc_valid),.alloc_static(g_alloc_static),.alloc_kind(g_alloc_kind),
  .alloc_epoch(g_alloc_epoch),.alloc_asset(g_alloc_asset),.alloc_frame(g_alloc_frame),.alloc_pts(g_alloc_pts),.alloc_duration(g_alloc_duration),.commit_valid(g_commit_valid),
  .commit_static(g_commit_static),.commit_slot(g_commit_slot),.commit_token(g_commit_token),.mem_req(g_mem_req),.mem_write(g_mem_write),.mem_address(g_mem_address),
  .mem_data(g_mem_data),.alloc_slot(alloc_slot),.alloc_token(alloc_token),.alloc_base(alloc_base),.mem_rdata(mem_rdata),.writes_idle(writes_idle),
  .alloc_ready(alloc_ready&&kind==2'd1),.commit_ready(commit_ready&&kind==2'd1),.mem_ready(mem_ready&&kind==2'd1),.busy(g_busy),.done(g_done),.failed(g_failed),
  .error_code(g_error),.mem_rvalid(mem_rvalid&&kind==2'd1),.reads_idle(reads_idle),.frames_committed());
wire v_alloc_valid; wire v_alloc_static; wire[1:0] v_alloc_kind; wire[31:0] v_alloc_epoch; wire[31:0] v_alloc_asset; wire[31:0] v_alloc_frame; wire[31:0] v_alloc_pts; wire[31:0] v_alloc_duration; wire v_commit_valid; wire v_commit_static; wire[1:0] v_commit_slot; wire[31:0] v_commit_token; wire v_mem_req; wire v_mem_write; wire[20:0] v_mem_address; wire[31:0] v_mem_data;
 wire v_ready,v_busy,v_done,v_failed;wire[7:0]v_error;
 db_library_video_producer v_producer(.drop_video(drop_video),.file_write(v_file_write),.file_data(v_file_data),.file_full(file_fifo_full),.file_finish(file_finish_toggle),
  .clk(clk),.rst(rst),.cancel(internal_cancel),.start(start_file&&kind==2'd2),.epoch(32'd1),.asset(file_index),
  .word_valid(video_word_valid&&state==DECODE&&!file_done_seen&&!stop_feed&&kind==2'd2),.word_data(video_word_data),.word_ready(v_ready),.alloc_valid(v_alloc_valid),.alloc_static(v_alloc_static),.alloc_kind(v_alloc_kind),
  .alloc_epoch(v_alloc_epoch),.alloc_asset(v_alloc_asset),.alloc_frame(v_alloc_frame),.alloc_pts(v_alloc_pts),.alloc_duration(v_alloc_duration),.commit_valid(v_commit_valid),
  .commit_static(v_commit_static),.commit_slot(v_commit_slot),.commit_token(v_commit_token),.mem_req(v_mem_req),.mem_write(v_mem_write),.mem_address(v_mem_address),
  .mem_data(v_mem_data),.alloc_slot(alloc_slot),.alloc_token(alloc_token),.alloc_base(alloc_base),.writes_idle(writes_idle),.alloc_ready(alloc_ready&&kind==2'd2),
  .commit_ready(commit_ready&&kind==2'd2),.mem_ready(mem_ready&&kind==2'd2),.busy(v_busy),.done(v_done),.failed(v_failed),.error_code(v_error),
  .frames_committed());
 assign alloc_valid=kind==0?b_alloc_valid:kind==1?g_alloc_valid:v_alloc_valid;
 assign alloc_static=kind==0?b_alloc_static:kind==1?g_alloc_static:v_alloc_static;
 assign alloc_kind=kind==0?b_alloc_kind:kind==1?g_alloc_kind:v_alloc_kind;
 assign alloc_epoch=kind==0?b_alloc_epoch:kind==1?g_alloc_epoch:v_alloc_epoch;
 assign alloc_asset=kind==0?b_alloc_asset:kind==1?g_alloc_asset:v_alloc_asset;
 assign alloc_frame=kind==0?b_alloc_frame:kind==1?g_alloc_frame:v_alloc_frame;
 assign alloc_pts=kind==0?b_alloc_pts:kind==1?g_alloc_pts:v_alloc_pts;
 assign alloc_duration=kind==0?b_alloc_duration:kind==1?g_alloc_duration:v_alloc_duration;
 assign commit_valid=kind==0?b_commit_valid:kind==1?g_commit_valid:v_commit_valid;
 assign commit_static=kind==0?b_commit_static:kind==1?g_commit_static:v_commit_static;
 assign commit_slot=kind==0?b_commit_slot:kind==1?g_commit_slot:v_commit_slot;
 assign commit_token=kind==0?b_commit_token:kind==1?g_commit_token:v_commit_token;
 assign mem_req=kind==0?b_mem_req:kind==1?g_mem_req:v_mem_req;
 assign mem_write=kind==0?b_mem_write:kind==1?g_mem_write:v_mem_write;
 assign mem_address=kind==0?b_mem_address:kind==1?g_mem_address:v_mem_address;
 assign mem_data=kind==0?b_mem_data:kind==1?g_mem_data:v_mem_data;
 wire selected_ready=kind==0?b_ready:kind==1?g_ready:v_ready;
 wire selected_done=kind==0?b_done:kind==1?g_done:v_done;
 wire selected_failed=kind==0?b_failed:kind==1?g_failed:v_failed;
 wire[7:0]selected_error=kind==0?b_error:kind==1?g_error:v_error;
 assign byte_ready=state==DECODE&&!stop_feed&&(file_done_seen||selected_ready);
 assign video_word_ready=state==DECODE&&!stop_feed&&kind==2&&(file_done_seen||v_ready);
 // Retain the two most recently loaded stills. An old resident may be evicted
 // only while a NEW still waits for a free slot; sending/queued slots never are.
 reg[31:0]static_token[0:1];
 assign evict_slot=resident_slots==2'b11 ? (static_token[0]<static_token[1]?2'd0:2'd1):resident_slots[0]?2'd0:2'd1;
 assign evict_token=static_token[evict_slot];
 assign evict_valid=!local_rst&&state==DECODE&&kind==0&&alloc_valid&&!alloc_ready&&(|resident_slots);
 task fail(input[7:0]code);begin failed<=1;error_code<=code;state<=FAULT;end endtask
 always @(posedge clk or posedge local_rst)begin
  if(local_rst)begin seen_next<=0;skip_pending<=0;stop_feed<=0;file_reset<=0;manual_advance<=0;still_time<=0;kind<=0;state<=INIT;file_index<=0;scan_start<=0;open_start<=0;start_file<=0;eof_seen<=0;file_done_seen<=0;done<=0;failed<=0;error_code<=0;total_frames<=0;static_token[0]<=0;static_token[1]<=0;file_committed_count<=0;file_finished_count<=0;end
  else begin
   scan_start<=0;open_start<=0;start_file<=0;file_reset<=0;
   if(next_number!=seen_next)begin seen_next<=next_number;skip_pending<=1;end
   if(state==DECODE&&skip_pending&&kind!=0&&commit_valid&&commit_ready)stop_feed<=1;
   if(state==WAIT_SEND&&kind==0&&playing&&!menu_open&&still_time<STILL_CYCLES)still_time<=still_time+1'b1;
   if(alloc_valid&&alloc_ready&&alloc_static)static_token[alloc_slot]<=alloc_token;
   if(commit_valid&&commit_ready)begin total_frames<=total_frames+1'b1;file_committed_count<=file_committed_count+1'b1;end
   if(frame_finished&&finished_asset==file_index)file_finished_count<=file_finished_count+1'b1;
   if(stream_done)eof_seen<=1;if(selected_done)file_done_seen<=1;
   if(reader_error)fail(8'h20|reader_error_code);
   else if(selected_failed)fail(selected_error);
   else case(state)
    INIT:if(memory_initialized&&sd_initialized)begin scan_start<=1;state<=SCAN;end
    SCAN:if(scan_done)begin if(found_files==0)fail(8'h10);else begin file_index<=0;state<=OPEN;end end
    OPEN:begin open_start<=1;state<=WAIT_OPEN;end
    WAIT_OPEN:if(file_opened)begin kind<=kind_metadata;start_file<=1;eof_seen<=0;file_done_seen<=0;file_committed_count<=0;file_finished_count<=0;stop_feed<=0;still_time<=0;state<=DECODE;end
    DECODE:if(stop_feed&&file_committed_count!=0&&file_finished_count==file_committed_count&&!sd_sec_read&&!monitor_prefetch&&writes_idle&&reads_idle)begin
      file_reset<=1;manual_advance<=1;skip_pending<=0;state<=NEXT;
     end else if(eof_seen&&file_done_seen&&!reader_busy)state<=WAIT_SEND;
    // Do not let round-robin arbitration reorder the next asset ahead of a
    // preceding GIF/video tail. A future prefetch path needs the same barrier.
    WAIT_SEND:if((kind==0||(file_committed_count!=0&&file_finished_count==file_committed_count))&&playing&&!menu_open&&
     (kind!=0||skip_pending||(auto_play&&still_time>=STILL_CYCLES))&&(kind!=2||!audio_hold||skip_pending))begin manual_advance<=skip_pending;skip_pending<=0;state<=NEXT;end
    NEXT:begin
     if(manual_advance||auto_play)file_index<=(file_index+32'd1<found_files)?file_index+1'b1:32'd0;
     done<=1;state<=OPEN;manual_advance<=0;
    end
    FINISHED:state<=FINISHED;
    FAULT:state<=FAULT;
    default:fail(8'hff);
   endcase
  end
 end
endmodule

