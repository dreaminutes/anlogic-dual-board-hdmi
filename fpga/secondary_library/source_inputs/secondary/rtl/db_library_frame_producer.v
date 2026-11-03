`timescale 1ns/1ps
// DBV1 byte source -> the SAME bounded dynamic slot protocol as GIF. Every
// payload CRC must pass before the last raster word can reach the writer.
// A corrupt frame stays uncommitted; supervisor must cancel to reclaim it.
// Header FPS is a positive nominal numerator/denominator. Actual cadence is
// the contiguous 90kHz PTS/duration of each record, including fractional FPS
// and variable durations. No hardware divider/multiplier is needed. A duration
// must be nonzero and less than half the32-bit timeline range.
module db_library_frame_producer(
 input wire clk,rst,cancel,start,drop_video,input wire[31:0]epoch,asset,
 input wire word_valid,input wire[31:0]word_data,output wire word_ready,
 output wire alloc_valid,alloc_static,output wire[1:0]alloc_kind,
 output wire[31:0]alloc_epoch,alloc_asset,alloc_frame,alloc_pts,alloc_duration,
 input wire alloc_ready,input wire[1:0]alloc_slot,input wire[31:0]alloc_token,input wire[20:0]alloc_base,
 output wire commit_valid,commit_static,output wire[1:0]commit_slot,output wire[31:0]commit_token,input wire commit_ready,
 output wire mem_req,mem_write,output wire[20:0]mem_address,output wire[31:0]mem_data,input wire mem_ready,writes_idle,
 output wire busy,output reg done,failed,output reg[7:0]error_code,output wire[31:0]frames_committed
);
 localparam IDLE=0,HEADER=1,CHECK_HEADER=2,FRAME_HEADER=3,CHECK_FRAME=4,START_WRITER=5,PIXELS=6,WAIT_WRITER=7,FINISHED=8,FAULT=9,FINAL_CRC=10;
 reg[12:0]content_index;assign frames_committed={19'd0,content_index};
 reg skipped,previous_skipped;reg[31:0]expected_pts;
 reg[3:0]state;reg[2:0]index;reg[31:0]header[0:7],record_header[0:3];
 reg[31:0]held_epoch,held_asset,frame_pts,frame_duration,expected_crc,crc;
 reg[12:0]total_frames;reg[17:0]payload_word;reg[31:0]packed_word;reg packed_valid,packed_last;
 wire writer_start_ready,writer_word_ready,writer_done,writer_failed,writer_busy;
 wire local_rst=rst||cancel;wire[31:0]next_crc;
 db_crc32_word crc_word(.previous(crc),.data(word_data),.next_crc(next_crc));
 assign word_ready=!local_rst&&(state==HEADER||state==FRAME_HEADER||state==FINISHED||(state==PIXELS&&(skipped||!packed_valid||writer_word_ready)));
 assign busy=state!=IDLE&&state!=FINISHED&&state!=FAULT;
 db_vburst3_frame_writer writer(.clk(clk),.rst(local_rst||start),.cancel(cancel),.start_valid(state==START_WRITER&&!skipped),.start_ready(writer_start_ready),.start_static(1'b0),.start_kind(2'd2),
  .start_epoch(held_epoch),.start_asset(held_asset),.start_frame({19'd0,content_index}),.start_pts(frame_pts),.start_duration(frame_duration),
  .word_valid(packed_valid),.word_ready(writer_word_ready),.word_data(packed_word),.word_last(packed_last),
  .alloc_valid(alloc_valid),.alloc_static(alloc_static),.alloc_kind(alloc_kind),.alloc_epoch(alloc_epoch),.alloc_asset(alloc_asset),.alloc_frame(alloc_frame),.alloc_pts(alloc_pts),.alloc_duration(alloc_duration),
  .alloc_ready(alloc_ready),.alloc_slot(alloc_slot),.alloc_token(alloc_token),.alloc_base(alloc_base),
  .commit_valid(commit_valid),.commit_static(commit_static),.commit_slot(commit_slot),.commit_token(commit_token),.commit_ready(commit_ready),
  .mem_req(mem_req),.mem_write(mem_write),.mem_address(mem_address),.mem_data(mem_data),.mem_ready(mem_ready),.writes_idle(writes_idle),.done(writer_done),.failed(writer_failed),.busy(writer_busy));
 task fail(input[7:0]code);begin failed<=1;error_code<=code;state<=FAULT;packed_valid<=0;end endtask
 always@(posedge clk or posedge local_rst)begin
  if(local_rst)begin
   skipped<=0;previous_skipped<=0;expected_pts<=0;state<=IDLE;index<=0;held_epoch<=0;held_asset<=0;total_frames<=0;frame_pts<=0;frame_duration<=0;expected_crc<=0;crc<=32'hffffffff;
   payload_word<=0;packed_word<=0;packed_valid<=0;packed_last<=0;done<=0;failed<=0;error_code<=0;content_index<=0;
  end else begin
   done<=0;
   if(start)begin skipped<=0;previous_skipped<=0;expected_pts<=0;state<=HEADER;index<=0;held_epoch<=epoch;held_asset<=asset;failed<=0;error_code<=0;content_index<=0;packed_valid<=0;packed_last<=0;end
   else if(writer_failed)fail(8'h93);
   else begin
    if(packed_valid&&writer_word_ready)packed_valid<=0;
    case(state)
     IDLE:state<=IDLE;
     HEADER:if(word_valid&&word_ready)begin header[index]<=word_data;if(index==7)state<=CHECK_HEADER;else index<=index+1'b1;end
     CHECK_HEADER:begin
      if(header[0]!=32'h31564244||header[1]!=32'h00200001||header[2]!=32'h01e00280||header[3]!=32'h00010001||header[4]==0||header[5]==0||header[6]==0||header[6]>6990||header[7]!=0)fail(8'h90);
      else begin total_frames<=header[6][12:0];index<=0;state<=FRAME_HEADER;end
     end
     FRAME_HEADER:if(word_valid&&word_ready)begin record_header[index[1:0]]<=word_data;if(index==3)state<=CHECK_FRAME;else index<=index+1'b1;end
     CHECK_FRAME:if(record_header[0]!=content_index||record_header[1]!=expected_pts||record_header[2]==0||record_header[2][31])fail(8'h91);
      else begin frame_pts<=record_header[1];frame_duration<=record_header[2];expected_crc<=record_header[3];crc<=32'hffffffff;payload_word<=0;packed_last<=0;skipped<=drop_video&&!previous_skipped&&content_index!=0&&content_index+1<total_frames;state<=START_WRITER;end
     START_WRITER:if(skipped||writer_start_ready)state<=PIXELS;
     PIXELS:if(word_valid&&word_ready)begin
      crc<=next_crc;packed_word<=word_data;
      if(payload_word==153599)begin packed_valid<=0;packed_last<=1;state<=FINAL_CRC;end
      else begin payload_word<=payload_word+1'b1;packed_valid<=!skipped;end
     end
     FINAL_CRC:if((~crc)!=expected_crc)fail(8'h92);else begin packed_valid<=!skipped;state<=WAIT_WRITER;end
     WAIT_WRITER:if(skipped||writer_done)begin previous_skipped<=skipped;
      expected_pts<=expected_pts+frame_duration;content_index<=content_index+1'b1;index<=0;
      if(content_index+1==total_frames)begin done<=1;state<=FINISHED;end else state<=FRAME_HEADER;
     end
     FINISHED:state<=FINISHED;
     FAULT:state<=FAULT;
     default:fail(8'hff);
    endcase
   end
  end
 end
endmodule
