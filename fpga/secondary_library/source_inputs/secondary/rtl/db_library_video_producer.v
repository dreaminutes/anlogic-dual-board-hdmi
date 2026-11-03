`timescale 1ns/1ps
// DBV1 compatibility, or DBV2 with an embedded PCM16/48k mono prelude.
// The prelude uses the existing bounded file FIFO, never a second frame RAM.
module db_library_video_producer(
 input clk,rst,cancel,start,drop_video,input[31:0]epoch,asset,
 input word_valid,input[31:0]word_data,output word_ready,
 output file_write,output[33:0]file_data,input file_full,file_finish,
 output alloc_valid,alloc_static,output[1:0]alloc_kind,
 output[31:0]alloc_epoch,alloc_asset,alloc_frame,alloc_pts,alloc_duration,
 input alloc_ready,input[1:0]alloc_slot,input[31:0]alloc_token,input[20:0]alloc_base,
 output commit_valid,commit_static,output[1:0]commit_slot,output[31:0]commit_token,input commit_ready,
 output mem_req,mem_write,output[20:0]mem_address,output[31:0]mem_data,input mem_ready,writes_idle,
 output busy,done,failed,output[7:0]error_code,output[31:0]frames_committed
);
 localparam IDLE=0,HEADER=1,CHECK=2,AHDR=3,ACHECK=4,BEGIN=5,META=6,AUDIO=7,END=8,WAIT=9,VSTART=10,VHDR=11,VIDEO=12,FAULT=13;
 reg[3:0]state;reg[2:0]at;reg has_audio,num_ok,den_ok,format_bad;
 reg[12:0]frame_total;reg[21:0]audio_bytes;reg[20:0]audio_samples;reg[31:0]audio_crc;reg[13:0]audio_step;
 reg[21:0]position;reg[31:0]held_asset,held_epoch;reg bad;reg[7:0]code;reg finish_seen;
 (* async_reg="true" *)reg[2:0]finish_sync;
 wire local_rst=rst||cancel;wire child_ready,child_failed;wire[7:0]child_error;
 // Original PCM's whole-file CRC is checked by the main before activation;
 // the secondary forwards the checksum, avoiding a duplicate audio checker.
 wire[255:0]metadata={{18'd0,audio_step},32'h31445541,audio_crc,32'd48000,{11'd0,audio_samples},{10'd0,audio_bytes},held_asset,held_epoch};
 assign file_write=!local_rst&&!file_full&&(state==BEGIN||state==META||state==END||(state==AUDIO&&word_valid));
 assign file_data=state==BEGIN?{2'b01,1'b1,held_asset[30:0]}:state==META?{2'b11,metadata[at*32+:32]}:
                  state==END?{2'b10,10'd0,position}:{2'b00,word_data};
 assign word_ready=!local_rst&&(state==HEADER||state==AHDR||(state==AUDIO&&!file_full)||(state==VIDEO&&child_ready));
 // Nominal FPS was already checked nonzero. Only authored PTS controls pace;
 // forwarding canonical1/1 avoids retaining two unused32-bit nominal fields.
 wire[31:0]replay=at==0?32'h31564244:at==1?32'h00200001:at==2?32'h01e00280:at==3?32'h00010001:
                         at==4||at==5?32'd1:at==6?{19'd0,frame_total}:32'd0;
 assign failed=bad||child_failed;assign error_code=bad?code:child_error;
 wire child_done;
 assign done=child_done;assign busy=state!=IDLE&&state!=FAULT;
 db_library_frame_producer video(.clk(clk),.rst(rst),.cancel(cancel),.start(state==VSTART),.drop_video(drop_video),.epoch(held_epoch),.asset(held_asset),
 .word_valid(state==VHDR||(state==VIDEO&&word_valid)),.word_data(state==VHDR?replay:word_data),.word_ready(child_ready),
 .alloc_valid(alloc_valid),.alloc_static(alloc_static),.alloc_kind(alloc_kind),.alloc_epoch(alloc_epoch),.alloc_asset(alloc_asset),.alloc_frame(alloc_frame),.alloc_pts(alloc_pts),.alloc_duration(alloc_duration),
 .alloc_ready(alloc_ready),.alloc_slot(alloc_slot),.alloc_token(alloc_token),.alloc_base(alloc_base),
 .commit_valid(commit_valid),.commit_static(commit_static),.commit_slot(commit_slot),.commit_token(commit_token),.commit_ready(commit_ready),
 .mem_req(mem_req),.mem_write(mem_write),.mem_address(mem_address),.mem_data(mem_data),.mem_ready(mem_ready),.writes_idle(writes_idle),
 .busy(),.done(child_done),.failed(child_failed),.error_code(child_error),.frames_committed(frames_committed));
 task fail(input[7:0]c);begin bad<=1;code<=c;state<=FAULT;end endtask
 always@(posedge clk or posedge local_rst)
 if(local_rst)begin state<=IDLE;at<=0;position<=0;held_asset<=0;held_epoch<=0;bad<=0;code<=0;finish_sync<=0;finish_seen<=0;has_audio<=0;num_ok<=0;den_ok<=0;format_bad<=0;frame_total<=0;audio_bytes<=0;audio_samples<=0;audio_crc<=0;audio_step<=0;end
 else begin
  finish_sync<={finish_sync[1:0],file_finish};
  if(start)begin state<=HEADER;at<=0;held_asset<=asset;held_epoch<=epoch;bad<=0;format_bad<=0;position<=0;end
  else case(state)
   HEADER:if(word_valid&&word_ready)begin
    case(at)
     0:begin has_audio<=word_data==32'h32564244;if(word_data!=32'h31564244&&word_data!=32'h32564244)format_bad<=1;end
     1:if(word_data!=(has_audio?32'h00200002:32'h00200001))format_bad<=1;
     2:if(word_data!=32'h01e00280)format_bad<=1;
     3:if(word_data!=32'h00010001)format_bad<=1;
     4:num_ok<=word_data!=0;
     5:den_ok<=word_data!=0;
     6:begin frame_total<=word_data[12:0];if(word_data==0||word_data>6990)format_bad<=1;end
     7:begin audio_bytes<=word_data[21:0];if(word_data[31:22]!=0)format_bad<=1;end
    endcase
    if(at==7)state<=CHECK;else at<=at+1'b1;
   end
   CHECK:if(format_bad||!num_ok||!den_ok)fail(8'ha0);
    else if(!has_audio&&audio_bytes==0)begin state<=VSTART;at<=0;end
    else if(has_audio&&audio_bytes>=4&&audio_bytes<=4063232&&audio_bytes[1:0]==0)begin at<=0;state<=AHDR;end
    else fail(8'ha0);
   AHDR:if(word_valid&&word_ready)begin
    case(at[1:0])
     0:begin audio_samples<=word_data[20:0];if(word_data==0||word_data>2031616)format_bad<=1;end
     1:audio_crc<=word_data;
     2:begin audio_step<=word_data[13:0];if(word_data==0||word_data>10159)format_bad<=1;end
     3:if(word_data!=48000)format_bad<=1;
    endcase
    if(at==3)state<=ACHECK;else at<=at+1'b1;
   end
   ACHECK:if(format_bad||(({1'b0,audio_samples}+22'd1)>>1)!=(audio_bytes>>2))fail(8'ha1);
    else begin at<=0;finish_seen<=finish_sync[2];state<=BEGIN;end
   BEGIN:if(file_write)state<=META;
   META:if(file_write)begin if(at==7)state<=AUDIO;else at<=at+1'b1;end
   AUDIO:if(word_valid&&word_ready)begin position<=position+22'd4;
    if(position+22'd4==audio_bytes)state<=END;
   end
   END:if(file_write)state<=WAIT;
   WAIT:if(finish_sync[2]!=finish_seen)begin state<=VSTART;at<=0;end
   VSTART:state<=VHDR;
   VHDR:if(child_ready)begin if(at==7)state<=VIDEO;else at<=at+1'b1;end
   VIDEO:state<=VIDEO;
   default:state<=state;
  endcase
 end
endmodule
