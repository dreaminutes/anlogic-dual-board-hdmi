`timescale 1ns/1ps
// Read-only FAT32 root-directory scanner and backpressured file-byte source.
// Streaming variant: original BMP/GIF checks plus DBV1 raw video.
// Kind 0=BMP, 1=GIF, 2=DBV. Original frozen FAT32 module remains unchanged.
// Sector interface holds sd_sec_read until sd_sec_read_end. It requires exactly
// 512 data bytes per sector and tolerates end coincident with the final byte.
// file_index selects metadata continuously; hold it steady through open_start.
module db_library_media_reader #(
 parameter READ_TIMEOUT_CYCLES=200000000,
 parameter MOUNT_MAX_RETRIES=3,
 parameter MOUNT_RETRY_DELAY_CYCLES=5000000
)(
 output wire catalog_ready,output wire[31:0]audio_data_base,audio_fat_base,audio_cluster_count,
 output wire[7:0]audio_spc,output wire[2:0]audio_shift,
 output reg[1:0]song_count,output reg[31:0]song0_cluster,song0_size,song1_cluster,song1_size,
 input stream_cancel,input clk,rst,sd_init_done,scan_start,output wire monitor_prefetch,
 input wire word_stream_enable,output wire stream_word_valid,output wire[31:0]stream_word_data,input wire stream_word_ready,
 output reg scan_done,output reg [31:0] file_count,
 input [31:0] file_index,input open_start,output reg file_opened,
 output wire byte_valid,output wire [7:0] byte_data,input byte_ready,
 output reg stream_done,
 output [1:0] selected_kind,output [15:0] selected_width,selected_height,
 output selected_top_down,
 output [31:0] selected_size,selected_pixel_offset,selected_row_stride,
 output busy,output reg error,output reg [7:0] error_code,
 output reg sd_sec_read,output reg [31:0] sd_sec_read_addr,output reg[3:0]sd_sec_read_count,
 input [31:0] sd_sec_read_data,input sd_sec_read_data_valid,sd_sec_read_end
);
 localparam IDLE=0,READ_WAIT=1,READ_GAP=2,FETCH_ADDR=3,FETCH_BYTE=4,
 ZERO_GOT=5,ZERO_PARSE=6,MBR_PARSE=7,BOOT_GOT=8,BOOT_PARSE=9,
 GEOMETRY=10,MOUNT_CHECK=11,DIR_READ=12,DIR_GOT=13,DIR_PARSE=14,
 DIR_ADVANCE=15,DIR_LINK=16,HEADER_GOT=17,HEADER_PARSE=18,
 PUBLISH=19,SCAN_FINISH=20,FILE_READ=21,FILE_GOT=22,
 STREAM_ADDR=23,STREAM_LATCH=24,STREAM_SEND=25,FILE_ADVANCE=26,
    FILE_LINK=27,FAT_LOOK=28,FAT_GOT=29,FAT_PARSE=30,MOUNT_RETRY=31,FILE_PREFETCH_LINK=32,PLAN_START=33,PLAN_STEP=34,PLAN_LINK=35,PLAN_DONE=36;
 localparam MOUNT_RETRY_BITS=(MOUNT_MAX_RETRIES>0)?$clog2(MOUNT_MAX_RETRIES+1):1;
 reg [MOUNT_RETRY_BITS-1:0] mount_retry_count;
 localparam HEADER_VALIDATE=37,HEADER_ARITH=38,FILE_OPEN_INIT=39,HEADER_COMPARE=40;
 localparam PLAN_APPLY=41,PLAN_LINK_PREP=42,PLAN_LINK_MATCH=43;
 reg plan_stop_r,plan_within_r,plan_fat_miss_r,plan_link_valid_r,plan_link_match_r;
 reg[31:0]plan_next_lba_r,plan_expected_lba_r;
 localparam DIR_CLASSIFY=45;reg dir_end_r,dir_wav_r,dir_media_r;
 localparam MOUNT_APPLY=44;reg[8:0]mount_bad;
 reg[2:0]header_checks;reg[13:0]header_stride;reg[12:0]header_height;
 reg[31:0]open_cluster_hold,open_size_hold;
 reg catalog_complete;
 reg [5:0] state=IDLE,read_return,fetch_return,fat_return;
 reg [31:0] sector_ram[0:255] /* fehdl force_ram=1, ram_style="bram" */;
 reg [31:0] fat_ram[0:127] /* fehdl force_ram=1, ram_style="bram" */;
 // Two banks: immutable current data and one next sector below EOF.
 // Cluster boundaries require an actual validated FAT entry, including on
 // fragmented files. FAT fills never overwrite either data bank. No guessed
 // adjacency, whole-file caching, new card commands or speculative EOF reads.
 reg active_bank,prefetch_active,prefetch_valid;
 reg[31:0]plan_start_lba,plan_lba,plan_cluster,plan_remaining,known_lba;
 reg[7:0]plan_sector;reg[4:0]plan_total;reg[3:0]known_count;
 reg plan_prefetch,reuse_known,known_valid;
 wire[3:0]authorized_count=plan_total>2?plan_total[3:0]-4'd1:4'd1;
 // At total16,low4bits are0 and modular minus1 produces15 data plus guard.
 wire known_hit=known_valid&&plan_start_lba>=known_lba&&(plan_start_lba-known_lba)<known_count;
 reg reading_fat;
 assign monitor_prefetch=prefetch_active;
 reg [31:0] prefetch_lba,prefetch_watchdog;
 reg chain_valid;reg [31:0] chain_cluster,chain_lba;
 reg [9:0] prefetch_count;reg [2:0] prefetch_gap;
 reg [9:0] receive_count;
 wire prefetch_final_length_ok=sd_sec_read_data_valid?(prefetch_count==10'd508):(prefetch_count==10'd512);
 wire prefetch_bad_length=prefetch_active&&((sd_sec_read_data_valid&&prefetch_count>=512)||(sd_sec_read_end&&!prefetch_final_length_ok));
 wire prefetch_timeout=prefetch_active&&!sd_sec_read_end&&prefetch_watchdog>=READ_TIMEOUT_CYCLES-1;
 // One explicit RAM write port: normal and prefetch ownership are exclusive.
 // Two procedural write sites make this tool fall back to thousands of FFs.
 wire sector_write=sd_sec_read_data_valid&&!rst&&sd_init_done&&
  ((state==READ_WAIT&&!reading_fat&&receive_count<512)||(prefetch_active&&prefetch_count<512));
 wire[7:0]sector_write_address=prefetch_active?{!active_bank,prefetch_count[8:2]}:{active_bank,receive_count[8:2]};
 reg[31:0]sector_word_q,fat_word_q;reg[1:0]ram_lane_q;
 wire[7:0]sector_q=sector_word_q[ram_lane_q*8+:8],fat_q=fat_word_q[ram_lane_q*8+:8];
 reg [7:0] ram_q,scratch[0:63];
 reg [8:0] ram_addr,stream_offset;
 reg [6:0] fetch_count,fetch_length;
 reg fetch_fat;
 reg [2:0] gap;
 reg [31:0] watchdog;
 reg [7:0] sig0,sig1;
 reg [1:0] partition_index;
 reg partitioned,mounted;
 reg [31:0] partition_lba,partition_sectors,total_sectors,reserved_sectors;
 reg [31:0] fat_size,fat_base,data_base,cluster_count,root_cluster;
 reg [7:0] sectors_per_cluster;
 reg [2:0] cluster_shift;
 reg [1:0] fat_count,active_fat;
 reg [31:0] dir_cluster,dir_lba;
 reg [7:0] dir_sector;
 reg [3:0] dir_entry;
 reg [15:0] dir_budget;
 reg [1:0] candidate_kind;
 reg [31:0] candidate_cluster,candidate_size;
 reg [31:0] entry_cluster,entry_size,entry_offset,entry_stride;
 reg [15:0] entry_width,entry_height;
 reg [1:0] entry_kind;reg entry_top_down;
 reg seeking;reg[31:0]search_index,loaded_index;
 reg [31:0] file_cluster,file_lba,file_size,file_position;
 // Eight bytes include both resident responses and outstanding synchronous
 // sector-RAM reads. The registered address plus registered RAM output takes
 // two edges before capture. Never issue past this sector or the file's EOF.
 wire word_mode=word_stream_enable&&selected_kind==2;
 reg word_sector_final;
 reg [7:0] byte_fifo[0:7];
 reg [2:0] byte_head,byte_tail;
 reg [3:0] byte_count;
 reg [1:0] byte_read_pipe;
 reg [9:0] bytes_issued,sector_length;
 wire [4:0] byte_credits={1'b0,byte_count}+{4'd0,byte_read_pipe[0]}+{4'd0,byte_read_pipe[1]};
 wire byte_issue=(!word_mode && state==STREAM_SEND && bytes_issued<sector_length && byte_credits<8);
 wire byte_push=byte_read_pipe[1];
 assign byte_valid=(!word_mode && state==STREAM_SEND && byte_count!=0 && sd_init_done && !rst);
 assign byte_data=byte_fifo[byte_head];
 wire byte_pop=byte_valid&&byte_ready;
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   byte_head<=0;byte_tail<=0;byte_count<=0;byte_read_pipe<=0;bytes_issued<=0;
  end else if(!sd_init_done || state!=STREAM_SEND || word_mode)begin
   byte_head<=0;byte_tail<=0;byte_count<=0;byte_read_pipe<=0;bytes_issued<=0;
  end else begin
   byte_read_pipe<={byte_read_pipe[0],byte_issue};
   if(byte_issue)bytes_issued<=bytes_issued+1'b1;
   if(byte_push)begin byte_fifo[byte_tail]<=sector_q;byte_tail<=byte_tail+1'b1;end
   if(byte_pop)byte_head<=byte_head+1'b1;
   case({byte_push,byte_pop})
    2'b10:byte_count<=byte_count+1'b1;
    2'b01:byte_count<=byte_count-1'b1;
    default:begin end
   endcase
  end
 end
 // Eight whole-word credits include outstanding synchronous RAM reads.
 reg[31:0]word_fifo[0:7];reg[2:0]word_head,word_tail;reg[3:0]word_count;
 reg[1:0]word_read_pipe;reg[7:0]words_issued;
 wire[7:0]sector_words=sector_length[9:2];
 wire[4:0]word_credits={1'b0,word_count}+{4'd0,word_read_pipe[0]}+{4'd0,word_read_pipe[1]};
 wire word_issue=word_mode&&state==STREAM_SEND&&words_issued<sector_words&&word_credits<8;
 wire word_push=word_read_pipe[1];
 assign stream_word_valid=word_mode&&state==STREAM_SEND&&word_count!=0&&sd_init_done&&!rst;
 assign stream_word_data=word_fifo[word_head];wire word_pop=stream_word_valid&&stream_word_ready;
 always@(posedge clk or posedge rst)begin
  if(rst)begin word_head<=0;word_tail<=0;word_count<=0;word_read_pipe<=0;words_issued<=0;end
  else if(!sd_init_done||state!=STREAM_SEND||!word_mode)begin word_head<=0;word_tail<=0;word_count<=0;word_read_pipe<=0;words_issued<=0;end
  else begin
   word_read_pipe<={word_read_pipe[0],word_issue};
   if(word_issue)words_issued<=words_issued+1'b1;
   if(word_push)begin word_fifo[word_tail]<=sector_word_q;word_tail<=word_tail+1'b1;end
   if(word_pop)word_head<=word_head+1'b1;
   case({word_push,word_pop})2'b10:word_count<=word_count+1'b1;2'b01:word_count<=word_count-1'b1;endcase
  end
 end
 reg [7:0] file_sector;
 reg [31:0] lookup_cluster,next_cluster,fat_tag;
 reg fat_valid;
 wire [31:0] wanted_fat_lba=fat_base+(lookup_cluster>>7);
 wire final_length_ok=sd_sec_read_data_valid?(receive_count==10'd508):(receive_count==10'd512);
 assign catalog_ready=mounted&&catalog_complete;assign audio_data_base=data_base;assign audio_fat_base=fat_base;assign audio_cluster_count=cluster_count;assign audio_spc=sectors_per_cluster;assign audio_shift=cluster_shift;
 assign busy=(state!=IDLE);
 assign selected_kind=entry_kind;
 assign selected_width=entry_width;
 assign selected_height=entry_height;
 assign selected_top_down=entry_top_down;
 assign selected_size=entry_size;
 assign selected_pixel_offset=entry_offset;
 assign selected_row_stride=entry_stride;
 function [31:0] le32;
  input integer n;
  begin le32={scratch[n+3],scratch[n+2],scratch[n+1],scratch[n]};end
 endfunction
 function [15:0] le16;
  input integer n;
  begin le16={scratch[n+1],scratch[n]};end
 endfunction
 // Separate address cones keep state selection out of the subtract/shift/add
 // path. This changes no request cycle, bounds or 32-bit modular arithmetic.
 (* syn_keep=1 *)wire[31:0]next_cluster_lba=data_base+((next_cluster-32'd2)*sectors_per_cluster);
 (* syn_keep=1 *)wire[31:0]open_cluster_lba=data_base+((open_cluster_hold-32'd2)*sectors_per_cluster);
 (* syn_keep=1 *)wire[31:0]root_cluster_lba=data_base+((root_cluster-32'd2)*sectors_per_cluster);
 (* syn_keep=1 *)wire[31:0]entry_cluster_lba=data_base+((({scratch[21],scratch[20],scratch[27],scratch[26]}&32'h0fffffff)-32'd2)*sectors_per_cluster);
 wire valid_cluster=(next_cluster>=2 && next_cluster<cluster_count+2);
 wire [31:0] bmp_w={scratch[21],scratch[20],scratch[19],scratch[18]};
 wire [31:0] bmp_h_signed={scratch[25],scratch[24],scratch[23],scratch[22]};
 wire [31:0] bmp_h=bmp_h_signed[31]?(~bmp_h_signed+1):bmp_h_signed;
 // Geometry arithmetic is deliberately bounded to the accepted dimensions;
 // accept BMP dimensions through 4096x4096 without a general 32x32 multiply.
 wire [13:0] bmp_stride_small=((({1'b0,bmp_w[12:0]}*14'd3)+14'd3)&14'h3ffc);
 reg [26:0] bmp_pixels_size_small;
 wire [31:0] bmp_stride={18'd0,bmp_stride_small};
 wire [31:0] bmp_pixels_size={5'd0,bmp_pixels_size_small};
 wire [31:0] bmp_offset={scratch[13],scratch[12],scratch[11],scratch[10]};
 wire [31:0] bmp_dib_size={scratch[17],scratch[16],scratch[15],scratch[14]};
 wire [31:0] bmp_declared_size={scratch[5],scratch[4],scratch[3],scratch[2]};
 wire [31:0] bmp_compression={scratch[33],scratch[32],scratch[31],scratch[30]};
 wire [15:0] bmp_planes={scratch[27],scratch[26]};
 wire [15:0] bmp_bpp={scratch[29],scratch[28]};
 wire [15:0] gif_w={scratch[7],scratch[6]},gif_h={scratch[9],scratch[8]};
 wire bmp_header_ok=(scratch[0]==8'h42 && scratch[1]==8'h4d &&
  candidate_size>=54 && bmp_dib_size>=40 && bmp_dib_size<=candidate_size-14 &&
  bmp_w>=1 && bmp_w<=4096 && bmp_h>=1 && bmp_h<=4096 &&
  bmp_planes==1 && bmp_bpp==24 && bmp_compression==0 &&
  bmp_offset>=54 && bmp_offset>=14+bmp_dib_size && bmp_offset<=candidate_size &&
  bmp_pixels_size<=candidate_size-bmp_offset &&
  bmp_declared_size>=bmp_offset+bmp_pixels_size && bmp_declared_size<=candidate_size);
 wire gif_header_ok=(scratch[0]=="G" && scratch[1]=="I" && scratch[2]=="F" &&
  scratch[3]=="8" && (scratch[4]=="7"||scratch[4]=="9") && scratch[5]=="a" &&
  gif_w==640 && gif_h==480 &&
  candidate_size>=14 && (!scratch[10][7] ||
  candidate_size>=14+(32'd6<<scratch[10][2:0])));
 // DBV1 bounds: 6990 full 640x480 records fit below FAT32's 4GiB file
 // limit. Validate the complete header and declared exact payload length.
 // Expose the header bytes directly in continuous expressions. A constant
 // function argument alone does not reliably retrigger simulation when the
 // function reads a module-level scratch RAM behind that argument.
 wire [31:0] dbv_frames={scratch[27],scratch[26],scratch[25],scratch[24]};
 wire dbv_audio={scratch[3],scratch[2],scratch[1],scratch[0]}==32'h32564244;
 wire[31:0]dbv_audio_bytes={scratch[31],scratch[30],scratch[29],scratch[28]};
 wire [32:0] dbv_required_size=33'd32+(dbv_audio?33'd16+{1'b0,dbv_audio_bytes}:33'd0)+{20'd0,dbv_frames[12:0]}*33'd614416;
 wire dbv_header_ok=({scratch[3],scratch[2],scratch[1],scratch[0]}==(dbv_audio?32'h32564244:32'h31564244) &&
  {scratch[5],scratch[4]}==(dbv_audio?16'd2:16'd1) && {scratch[7],scratch[6]}==16'd32 &&
  {scratch[9],scratch[8]}==16'd640 && {scratch[11],scratch[10]}==16'd480 &&
  {scratch[13],scratch[12]}==16'd1 && {scratch[15],scratch[14]}==16'd1 &&
  {scratch[19],scratch[18],scratch[17],scratch[16]}!=32'd0 &&
  {scratch[23],scratch[22],scratch[21],scratch[20]}!=32'd0 &&
  dbv_frames>=1 && dbv_frames<=6990 && (dbv_audio?(dbv_audio_bytes>=4&&dbv_audio_bytes<=4063232&&dbv_audio_bytes[1:0]==0):dbv_audio_bytes==0) &&
  dbv_required_size=={1'b0,candidate_size});
 // Both RAMs use synchronous read ports and retain their contents on reset.
 always @(posedge clk)begin
  if(sector_write)sector_ram[sector_write_address]<=sd_sec_read_data;
  if(sd_sec_read_data_valid && state==READ_WAIT && receive_count<512)begin
   if(reading_fat)fat_ram[receive_count[8:2]]<=sd_sec_read_data;
  end
  sector_word_q<=sector_ram[{active_bank,ram_addr[8:2]}];
  ram_lane_q<=ram_addr[1:0];
  fat_word_q<=fat_ram[ram_addr[8:2]];
 end
 always @* ram_q=fetch_fat?fat_q:sector_q;
 task read_sector;
  input [31:0] lba;input [5:0] afterwards;input is_fat;
  begin sd_sec_read_addr<=lba;sd_sec_read<=1;sd_sec_read_count<=1;known_valid<=0;receive_count<=0;
   watchdog<=0;reading_fat<=is_fat;read_return<=afterwards;state<=READ_WAIT;end
 endtask
 // Planning never changes the live file cursor or current consumer bank.
 task plan_data;
  input[31:0]lba,cluster,remaining;input[7:0]sector_index;input prefetch;
  begin
   plan_start_lba<=lba;plan_lba<=lba;plan_cluster<=cluster;plan_remaining<=remaining;
   plan_sector<=sector_index;plan_total<=1;plan_prefetch<=prefetch;reuse_known<=0;state<=PLAN_START;
  end
 endtask
 task fetch;
  input [8:0] offset;input [6:0] length;input [5:0] afterwards;input is_fat;
  begin ram_addr<=offset;fetch_length<=length;fetch_count<=0;fetch_fat<=is_fat;
   fetch_return<=afterwards;state<=FETCH_ADDR;end
 endtask
 task fail;
  input [7:0] why;
  begin
   sd_sec_read<=0;
   // A completed but invalid MBR/BPB read may be transient. Remount only
   // before any directory/file data is published, with a bounded delay.
   // Persistent invalid media still reports the original 03 (OSD F035).
   if(why==8'h03 && !mounted && mount_retry_count<MOUNT_MAX_RETRIES)begin
    mount_retry_count<=mount_retry_count+1'b1;
    watchdog<=0;state<=MOUNT_RETRY;
   end else begin error<=1;error_code<=why;state<=IDLE;prefetch_active<=0;prefetch_valid<=0;end
  end
 endtask
 integer i;
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   song_count<=0;song0_cluster<=0;song0_size<=0;song1_cluster<=0;song1_size<=0;catalog_complete<=0;
   dir_end_r<=0;dir_wav_r<=0;dir_media_r<=0;mount_bad<=0;plan_stop_r<=0;plan_within_r<=0;plan_fat_miss_r<=0;plan_link_valid_r<=0;plan_link_match_r<=0;plan_next_lba_r<=0;plan_expected_lba_r<=0;
   state<=IDLE;sd_sec_read<=0;sd_sec_read_addr<=0;sd_sec_read_count<=1;sector_length<=0;word_sector_final<=0;
   plan_start_lba<=0;plan_lba<=0;plan_cluster<=0;plan_remaining<=0;known_lba<=0;plan_sector<=0;plan_total<=1;known_count<=0;plan_prefetch<=0;reuse_known<=0;known_valid<=0;
   chain_valid<=0;chain_cluster<=0;chain_lba<=0;
   active_bank<=0;prefetch_active<=0;prefetch_valid<=0;prefetch_lba<=0;prefetch_watchdog<=0;prefetch_count<=0;prefetch_gap<=0;
   scan_done<=0;file_count<=0;stream_done<=0;error<=0;error_code<=0;
   receive_count<=0;watchdog<=0;ram_addr<=0;fetch_fat<=0;fat_valid<=0;
   partition_lba<=0;partitioned<=0;mounted<=0;file_position<=0;
   mount_retry_count<=0;
   entry_cluster<=0;entry_size<=0;entry_offset<=0;entry_stride<=0;
   entry_width<=0;entry_height<=0;entry_kind<=0;entry_top_down<=0;
   seeking<=0;search_index<=0;loaded_index<=32'hffffffff;file_opened<=0;
  end else if(!sd_init_done)begin
   state<=IDLE;sd_sec_read<=0;scan_done<=0;stream_done<=0;file_opened<=0;
   known_valid<=0;sd_sec_read_count<=1;chain_valid<=0;
   active_bank<=0;prefetch_active<=0;prefetch_valid<=0;prefetch_count<=0;prefetch_watchdog<=0;prefetch_gap<=0;
   song_count<=0;catalog_complete<=0;file_count<=0;error<=0;error_code<=0;fat_valid<=0;mounted<=0;
   mount_retry_count<=0;
  end else begin
   scan_done<=0;stream_done<=0;file_opened<=0;
   if(prefetch_gap!=0)prefetch_gap<=prefetch_gap-1'b1;
   if(prefetch_active)begin
    prefetch_watchdog<=prefetch_watchdog+1'b1;
    if(sd_sec_read_data_valid)prefetch_count<=prefetch_count+10'd4;
    if(sd_sec_read_end)begin
     sd_sec_read<=0;prefetch_active<=0;prefetch_valid<=!prefetch_bad_length;
     prefetch_gap<=4;
    end
   end
   // A malformed/failed prefetched sector cannot be published to consumer RAM.
   // Fault takes priority over state transitions and must never complete EOF.
   if(prefetch_bad_length)fail(8'h02);
   else if(prefetch_timeout)fail(8'h01);
   else if(stream_cancel&&!sd_sec_read&&!prefetch_active)begin
    state<=IDLE;stream_done<=0;known_valid<=0;chain_valid<=0;prefetch_valid<=0;
    // Mounted catalog/geometry and song entries survive a live asset change.
   end
   else case(state)
    IDLE:begin
     if(scan_start)begin
      seeking<=0;loaded_index<=32'hffffffff;search_index<=0;
      mount_retry_count<=0;
      song_count<=0;catalog_complete<=0;file_count<=0;error<=0;error_code<=0;fat_valid<=0;mounted<=0;
      partitioned<=0;partition_lba<=0;partition_index<=0;
      read_sector(0,ZERO_GOT,0);
     end else if(open_start)begin
      error<=0;error_code<=0;
      if(!mounted || file_index>=file_count)fail(8'h07);
      else begin
       if(loaded_index==file_index)begin open_cluster_hold<=entry_cluster;open_size_hold<=entry_size;state<=FILE_OPEN_INIT;end
       else begin seeking<=1;search_index<=0;dir_cluster<=root_cluster;dir_lba<=root_cluster_lba;dir_sector<=0;dir_entry<=0;dir_budget<=0;fat_valid<=0;state<=DIR_READ;end
      end
     end
    end
    FILE_OPEN_INIT:begin
     file_opened<=1;
     file_cluster<=open_cluster_hold;file_lba<=open_cluster_lba;
     chain_valid<=0;file_sector<=0;file_position<=0;file_size<=open_size_hold;state<=FILE_READ;
    end
    READ_WAIT:begin
     watchdog<=watchdog+1;
     if(sd_sec_read_data_valid)begin
      if(receive_count>=512)fail(8'h02);else receive_count<=receive_count+10'd4;
      if(receive_count==508)begin sig0<=sd_sec_read_data[23:16];sig1<=sd_sec_read_data[31:24];end
     end
     if(sd_sec_read_end)begin
      sd_sec_read<=0;
      if(!final_length_ok)fail(8'h02);
      else begin gap<=4;state<=READ_GAP;end
     end else if(watchdog>=READ_TIMEOUT_CYCLES-1)fail(8'h01);
    end
    READ_GAP:if(gap==0)state<=read_return;else gap<=gap-1;
    MOUNT_RETRY:begin
     if(watchdog>=MOUNT_RETRY_DELAY_CYCLES-1)begin
      // Restart at LBA0: never retain a partition address from a bad read.
      partitioned<=0;partition_lba<=0;partition_index<=0;
      file_count<=0;fat_valid<=0;mounted<=0;
      read_sector(0,ZERO_GOT,0);
     end else watchdog<=watchdog+1'b1;
    end
    FETCH_ADDR:state<=FETCH_BYTE;
    FETCH_BYTE:begin
     scratch[fetch_count[5:0]]<=ram_q;
     if(fetch_count+1==fetch_length)state<=fetch_return;
     else begin fetch_count<=fetch_count+1;ram_addr<=ram_addr+1;state<=FETCH_ADDR;end
    end
    ZERO_GOT:if(sig0!=8'h55||sig1!=8'haa)fail(8'h03);else fetch(0,64,ZERO_PARSE,0);
    ZERO_PARSE:begin
     if(le16(11)==512 && le16(17)==0 && le16(22)==0 && le32(36)!=0)
      state<=BOOT_PARSE;
     else fetch(446,16,MBR_PARSE,0);
    end
    MBR_PARSE:begin
     if((scratch[4]==8'h0b||scratch[4]==8'h0c)&&le32(8)!=0&&le32(12)!=0)begin
      partitioned<=1;partition_lba<=le32(8);partition_sectors<=le32(12);
      read_sector(le32(8),BOOT_GOT,0);
     end else if(partition_index==3)fail(8'h03);
     else begin partition_index<=partition_index+1;fetch(446+((partition_index+1)*16),16,MBR_PARSE,0);end
    end
    BOOT_GOT:if(sig0!=8'h55||sig1!=8'haa)fail(8'h03);else fetch(0,64,BOOT_PARSE,0);
    BOOT_PARSE:begin
     if(le16(11)!=512||le16(17)!=0||le16(22)!=0||le16(19)!=0||le32(36)==0||
      le16(14)==0||scratch[16]==0||scratch[16]>2||le16(42)!=0||
      scratch[13]==0||(scratch[13]&(scratch[13]-1))!=0||scratch[13]>128)fail(8'h03);
     else begin
      reserved_sectors<={16'd0,le16(14)};fat_count<=scratch[16][1:0];
      fat_size<=le32(36);total_sectors<=le32(32);root_cluster<=le32(44)&32'h0fffffff;
      sectors_per_cluster<=scratch[13];
      case(scratch[13])1:cluster_shift<=0;2:cluster_shift<=1;4:cluster_shift<=2;
       8:cluster_shift<=3;16:cluster_shift<=4;32:cluster_shift<=5;
       64:cluster_shift<=6;default:cluster_shift<=7;endcase
      if(scratch[40][7])begin
       if(scratch[40][3:0]>=scratch[16])fail(8'h03);
       else begin active_fat<=scratch[40][1:0];state<=GEOMETRY;end
      end else begin active_fat<=0;state<=GEOMETRY;end
     end
    end
    GEOMETRY:begin
     fat_base<=partition_lba+reserved_sectors+(active_fat==1?fat_size:0);
     data_base<=partition_lba+reserved_sectors+(fat_count==2?(fat_size<<1):fat_size);
     cluster_count<=(total_sectors-reserved_sectors-(fat_count==2?(fat_size<<1):fat_size))>>cluster_shift;
     state<=MOUNT_CHECK;
    end
    MOUNT_CHECK:begin
     mount_bad[0]<=reserved_sectors>=total_sectors;
     mount_bad[1]<=fat_size>=total_sectors;
     mount_bad[2]<=fat_count==2&&fat_size>(total_sectors>>1);
     mount_bad[3]<=total_sectors<=reserved_sectors+(fat_count==2?(fat_size<<1):fat_size);
     mount_bad[4]<=cluster_count<65525||cluster_count>32'h0fffffed;
     mount_bad[5]<=root_cluster<2||root_cluster>=cluster_count+2;
     mount_bad[6]<=fat_size<((cluster_count+2+127)>>7);
     mount_bad[7]<=partitioned&&total_sectors>partition_sectors;
     mount_bad[8]<=partition_lba+total_sectors<partition_lba;
     state<=MOUNT_APPLY;
    end
    MOUNT_APPLY:begin
     if(|mount_bad)fail(8'h03);
     else begin mounted<=1;dir_cluster<=root_cluster;dir_lba<=root_cluster_lba;
      dir_sector<=0;dir_entry<=0;dir_budget<=0;state<=DIR_READ;end
    end
    DIR_READ:begin
     if(dir_budget==65535)fail(8'h04);
     else begin dir_budget<=dir_budget+1;read_sector(dir_lba+dir_sector,DIR_GOT,0);end
    end
    DIR_GOT:fetch({dir_entry,5'b0},32,DIR_PARSE,0);
    DIR_PARSE:begin
     dir_end_r<=scratch[0]==0;
     dir_wav_r<=!seeking&&song_count<2&&scratch[0]!=8'he5&&(scratch[11]&8'h18)==0&&scratch[11]!=8'h0f&&le32(28)>=46&&
      (scratch[8]=="W"||scratch[8]=="w")&&(scratch[9]=="A"||scratch[9]=="a")&&(scratch[10]=="V"||scratch[10]=="v")&&
      ({le16(20),le16(26)}&32'h0fffffff)>=2&&({le16(20),le16(26)}&32'h0fffffff)<cluster_count+2;
     dir_media_r<=scratch[0]!=8'he5 && (scratch[11]&8'h18)==0 && scratch[11]!=8'h0f &&
      le32(28)>=14 && ({le16(20),le16(26)}&32'h0fffffff)>=2 &&
      ({le16(20),le16(26)}&32'h0fffffff)<cluster_count+2 &&
      (((scratch[8]=="B"||scratch[8]=="b")&&(scratch[9]=="M"||scratch[9]=="m")&&(scratch[10]=="P"||scratch[10]=="p")) ||
       ((scratch[8]=="G"||scratch[8]=="g")&&(scratch[9]=="I"||scratch[9]=="i")&&(scratch[10]=="F"||scratch[10]=="f")) ||
       ((scratch[8]=="D"||scratch[8]=="d")&&(scratch[9]=="B"||scratch[9]=="b")&&(scratch[10]=="V"||scratch[10]=="v")));
     state<=DIR_CLASSIFY;
    end
    DIR_CLASSIFY:begin
     if(dir_end_r)state<=SCAN_FINISH;
     else if(dir_wav_r)begin
      if(song_count==0)begin song0_cluster<={le16(20),le16(26)}&32'h0fffffff;song0_size<=le32(28);end
      else begin song1_cluster<={le16(20),le16(26)}&32'h0fffffff;song1_size<=le32(28);end
      song_count<=song_count+1'b1;state<=DIR_ADVANCE;
     end else if(dir_media_r)begin
      candidate_kind<=(scratch[8]=="G"||scratch[8]=="g")?2'd1:(scratch[8]=="D"||scratch[8]=="d")?2'd2:2'd0;
      candidate_cluster<={le16(20),le16(26)}&32'h0fffffff;candidate_size<=le32(28);
      read_sector(entry_cluster_lba,HEADER_GOT,0);
     end else state<=DIR_ADVANCE;
    end
    HEADER_GOT:fetch(0,54,HEADER_PARSE,0);
    HEADER_PARSE:begin header_stride<=bmp_stride_small;header_height<=bmp_h[12:0];state<=HEADER_ARITH;end
    HEADER_ARITH:begin bmp_pixels_size_small<=header_stride*header_height;state<=HEADER_COMPARE;end
    HEADER_COMPARE:begin header_checks<={dbv_header_ok,bmp_header_ok,gif_header_ok};state<=HEADER_VALIDATE;end
    HEADER_VALIDATE:begin
     if((candidate_kind==1 && header_checks[0])||(candidate_kind==0 && header_checks[1])||(candidate_kind==2 && header_checks[2]))state<=PUBLISH;
     else state<=DIR_ADVANCE;
    end
    PUBLISH:begin
     // One metadata record only. Initial scan counts every valid file; later
     // opens find the requested ordinal in FAT directory order, without a
     // fixed-size file table or per-file frame allocation.
     if((!seeking&&file_count==0)||(seeking&&search_index==file_index))begin
      entry_cluster<=candidate_cluster;entry_size<=candidate_size;entry_kind<=candidate_kind;
      entry_width<=candidate_kind==1?le16(6):candidate_kind==2?le16(8):bmp_w[15:0];
      entry_height<=candidate_kind==1?le16(8):candidate_kind==2?le16(10):bmp_h[15:0];
      entry_top_down<=candidate_kind==0?bmp_h_signed[31]:1'b0;
      entry_offset<=candidate_kind==0?bmp_offset:candidate_kind==2?32'd32:32'd0;
      entry_stride<=candidate_kind==0?bmp_stride:candidate_kind==2?32'd1280:32'd0;
      loaded_index<=seeking?file_index:32'd0;
     end
     if(seeking&&search_index==file_index)begin
      open_cluster_hold<=candidate_cluster;open_size_hold<=candidate_size;seeking<=0;state<=FILE_OPEN_INIT;
     end else begin
      if(seeking)search_index<=search_index+1'b1;else file_count<=file_count+1'b1;
      state<=DIR_ADVANCE;
     end
    end
    DIR_ADVANCE:begin
     if(dir_entry!=15)begin dir_entry<=dir_entry+1;state<=DIR_READ;end
     else begin
      dir_entry<=0;
      if(dir_sector+1<sectors_per_cluster)begin dir_sector<=dir_sector+1;state<=DIR_READ;end
      else begin lookup_cluster<=dir_cluster;fat_return<=DIR_LINK;state<=FAT_LOOK;end
     end
    end
    DIR_LINK:begin
     if(next_cluster>=32'h0ffffff8)state<=SCAN_FINISH;
     else if(!valid_cluster||next_cluster==dir_cluster)fail(8'h04);
     else begin dir_cluster<=next_cluster;dir_lba<=next_cluster_lba;dir_sector<=0;state<=DIR_READ;end
    end
    SCAN_FINISH:if(seeking)begin seeking<=0;fail(8'h07);end else begin catalog_complete<=1;scan_done<=1;state<=IDLE;end
    FILE_READ:if(!prefetch_active&&prefetch_gap==0)begin
     if(prefetch_valid)begin
      if(prefetch_lba!=file_lba+file_sector)fail(8'h08);
      else begin active_bank<=!active_bank;prefetch_valid<=0;state<=FILE_GOT;end
     end else plan_data(file_lba+file_sector,file_cluster,file_size-file_position,file_sector,0);
    end
    FILE_GOT:if(word_mode&&((file_size-file_position)&32'd3)!=0)fail(8'h02);else begin
     word_sector_final<=file_size-file_position<=512;
     fetch_fat<=0;ram_addr<=0;stream_offset<=0;
     sector_length<=(file_size-file_position>=512)?10'd512:file_size-file_position;
     chain_valid<=0;
     if(file_size-file_position>512)begin
      if({1'b0,file_sector}+1<sectors_per_cluster)begin
       plan_data(file_lba+file_sector+1'b1,file_cluster,file_size-file_position-512,file_sector+1'b1,1);
      end else begin
       // Resolve the actual successor before requesting any next data LBA.
       // Cached FAT lookup is cheap; a FAT miss uses the separate FAT RAM.
       lookup_cluster<=file_cluster;fat_return<=FILE_PREFETCH_LINK;state<=FAT_LOOK;
      end
     end else state<=STREAM_SEND;
    end
    FILE_PREFETCH_LINK:begin
     if(!valid_cluster||next_cluster==file_cluster)fail(8'h06);
     else begin
      chain_valid<=1;chain_cluster<=next_cluster;chain_lba<=next_cluster_lba;
      plan_data(next_cluster_lba,next_cluster,file_size-file_position-512,0,1);
     end
    end
    PLAN_START:begin
     if(known_hit)begin reuse_known<=1;state<=PLAN_DONE;end
     else state<=PLAN_STEP;
    end
    PLAN_STEP:begin
     plan_stop_r<=plan_total==16||plan_remaining<=512;
     plan_within_r<={1'b0,plan_sector}+1<sectors_per_cluster;
     plan_fat_miss_r<=plan_total>1&&fat_valid&&fat_tag!=fat_base+(plan_cluster>>7);
     state<=PLAN_APPLY;
    end
    PLAN_APPLY:begin
     if(plan_stop_r)state<=PLAN_DONE;
     else if(plan_within_r)begin
      plan_lba<=plan_lba+1'b1;plan_sector<=plan_sector+1'b1;
      plan_total<=plan_total+1'b1;plan_remaining<=plan_remaining-512;state<=PLAN_STEP;
     end else if(plan_fat_miss_r)begin
      // Do not thrash between FAT pages while serving an immutable run.
      // The last authorized sector is the guard,not published run data.
      state<=PLAN_DONE;
     end else begin lookup_cluster<=plan_cluster;fat_return<=PLAN_LINK;state<=FAT_LOOK;end
    end
    PLAN_LINK_PREP:begin
     plan_next_lba_r<=next_cluster_lba;plan_expected_lba_r<=plan_lba+1;
     plan_link_valid_r<=valid_cluster&&next_cluster!=plan_cluster;state<=PLAN_LINK_MATCH;
    end
    PLAN_LINK_MATCH:begin plan_link_match_r<=plan_next_lba_r==plan_expected_lba_r;state<=PLAN_LINK;end
    PLAN_LINK:begin
     if(!plan_link_valid_r||!plan_link_match_r)state<=PLAN_DONE;
     else begin
      plan_cluster<=next_cluster;plan_lba<=plan_next_lba_r;plan_sector<=0;
      plan_total<=plan_total+1'b1;plan_remaining<=plan_remaining-512;state<=PLAN_STEP;
     end
    end
    PLAN_DONE:begin
     if(plan_prefetch)begin
      sd_sec_read_addr<=plan_start_lba;sd_sec_read<=1;
      prefetch_lba<=plan_start_lba;prefetch_active<=1;prefetch_valid<=0;
      prefetch_count<=0;prefetch_watchdog<=0;fetch_fat<=0;ram_addr<=0;state<=STREAM_SEND;
     end else read_sector(plan_start_lba,FILE_GOT,0);
     sd_sec_read_count<=reuse_known?4'd1:authorized_count;
     known_valid<=1;
     if(!reuse_known)begin known_lba<=plan_start_lba;known_count<=authorized_count;end
    end
    STREAM_SEND:if(word_mode)begin
     if(word_issue)ram_addr<={words_issued[6:0],2'b00};
     if(word_pop)begin
      file_position<=file_position+4;
      if(word_sector_final&&{1'b0,stream_offset}+10'd4>=sector_length)begin stream_done<=1;state<=IDLE;end
      else if(stream_offset==508)state<=FILE_ADVANCE;
      else stream_offset<=stream_offset+9'd4;
     end
    end else begin
     if(byte_issue)ram_addr<=bytes_issued[8:0];
     if(byte_pop)begin
      file_position<=file_position+1;
      if(file_position+1>=file_size)begin stream_done<=1;state<=IDLE;end
      else if(stream_offset==511)state<=FILE_ADVANCE;
      else stream_offset<=stream_offset+1'b1;
     end
    end
    FILE_ADVANCE:begin
     if(file_sector+1<sectors_per_cluster)begin file_sector<=file_sector+1;state<=FILE_READ;end
     else if(chain_valid)begin
      file_cluster<=chain_cluster;file_lba<=chain_lba;file_sector<=0;
      chain_valid<=0;state<=FILE_READ;
     end else begin lookup_cluster<=file_cluster;fat_return<=FILE_LINK;state<=FAT_LOOK;end
    end
    FILE_LINK:begin
     if(!valid_cluster||next_cluster==file_cluster)fail(8'h06);
     else begin file_cluster<=next_cluster;file_lba<=next_cluster_lba;file_sector<=0;state<=FILE_READ;end
    end
    FAT_LOOK:begin
     if(fat_valid && fat_tag==wanted_fat_lba)fetch({lookup_cluster[6:0],2'b0},4,FAT_PARSE,1);
     else begin fat_valid<=0;fat_tag<=wanted_fat_lba;read_sector(wanted_fat_lba,FAT_GOT,1);end
    end
    FAT_GOT:begin fat_valid<=1;fetch({lookup_cluster[6:0],2'b0},4,FAT_PARSE,1);end
    FAT_PARSE:begin next_cluster<=le32(0)&32'h0fffffff;state<=fat_return==PLAN_LINK?PLAN_LINK_PREP:fat_return;end
    default:fail(8'hff);
   endcase
  end
 end
endmodule
