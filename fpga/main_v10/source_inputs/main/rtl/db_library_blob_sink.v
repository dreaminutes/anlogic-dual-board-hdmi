`timescale 1ns/1ps
// Replays ordinary BMP records unchanged. Audio records occupy only the
// reserved SDRAM tail [0x108000,0x200000), past all seven graphics buffers.
module db_library_blob_sink(
 input clk,rst,input[33:0]fifo_data,input fifo_empty,output fifo_read,
 output metadata_valid,input metadata_ready,output[193:0]metadata,
 input[20:0]target_base,input[1:0]target_slot,
 output mem_req,mem_write,output[20:0]mem_address,output[31:0]mem_data,
 input mem_ready,writes_idle,output whole_complete,end_valid,input end_ready,
 output[31:0]end_frame,end_epoch,output busy,output failed,
 output reg cache_valid,cache_loading,output reg[6:0]cache_percent,
 output reg[31:0]cache_asset,output reg[20:0]cache_samples,output reg[7:0]cache_generation
);
 localparam IDLE=0,META=1,CLASSIFY=2,BSTART=3,BMETA=4,BODY=5,AUDIO=6,FINISH=7,FAULT=8,DIGEST=9;
 reg[3:0]state;reg[2:0]at;reg[255:0]held;reg[31:0]frame,crc;reg[21:0]position;reg[13:0]bucket;
 reg bad;wire b_read,b_busy,b_failed;wire[33:0]b_data=state==BSTART?{2'b01,frame}:state==BMETA?{2'b11,held[at*32+:32]}:fifo_data;
 wire b_empty=!(state==BSTART||state==BMETA||(state==BODY&&!fifo_empty));
 wire b_req,b_write;wire[20:0]b_address;wire[31:0]b_word;
 db_fast24_bmp_sink bmp(.clk(clk),.rst(rst),.fifo_data(b_data),.fifo_empty(b_empty),.fifo_read(b_read),
 .metadata_valid(metadata_valid),.metadata_ready(metadata_ready),.metadata(metadata),.target_base(target_base),.target_slot(target_slot),
 .mem_req(b_req),.mem_write(b_write),.mem_address(b_address),.mem_data(b_word),.mem_ready(mem_ready&&state!=AUDIO),.writes_idle(writes_idle),
 .whole_complete(whole_complete),.end_valid(end_valid),.end_ready(end_ready),.end_frame(end_frame),.end_epoch(end_epoch),.busy(b_busy),.failed(b_failed));
 wire audio_word=state==AUDIO&&!fifo_empty&&fifo_data[33:32]==0&&position<held[95:64];
 assign mem_req=audio_word||b_req;assign mem_write=1;
 // Address selection depends on the registered owner, never token-valid or
 // length comparisons. Those qualify req only, outside the SDRAM row-match
 // -> ready -> BMP scaler feedback path.
 assign mem_address=state==AUDIO?21'h108000+{1'b0,position[21:2]}:b_address;
 assign mem_data=state==AUDIO?fifo_data[31:0]:b_word;
 assign fifo_read=!rst&&!fifo_empty&&((state==IDLE&&!b_busy)||state==META||(state==BODY&&b_read)||(audio_word&&mem_ready)||(state==AUDIO&&fifo_data[33:32]!=0));
 assign busy=state!=IDLE||b_busy;assign failed=bad||b_failed;
 // Audio arrives far below the memory clock rate. Reuse one byte CRC stage
 // for four cycles rather than replicate the wide32-bit XOR network beside
 // the shared SDRAM bus. Capacity >40MB/s; no video-path throughput change.
 reg[31:0]crc_data;reg[1:0]crc_left;
 function[31:0]crc_byte;input[31:0]c;input[7:0]d;reg[31:0]x;integer i;begin
  x=c^{24'd0,d};for(i=0;i<8;i=i+1)x=(x>>1)^(x[0]?32'hedb88320:32'd0);crc_byte=x;
 end endfunction
 task reject;begin bad<=1;cache_valid<=0;cache_loading<=0;state<=FAULT;end endtask
 always@(posedge clk or posedge rst)
 if(rst)begin state<=IDLE;at<=0;held<=0;frame<=0;position<=0;crc<=32'hffffffff;crc_data<=0;crc_left<=0;bucket<=0;bad<=0;cache_valid<=0;cache_loading<=0;cache_percent<=0;cache_asset<=0;cache_samples<=0;cache_generation<=0;end
 else case(state)
  IDLE:if(fifo_read)begin if(fifo_data[33:32]!=1)reject;else begin frame<=fifo_data[31:0];at<=0;state<=META;end end
  META:if(fifo_read)begin if(fifo_data[33:32]!=3)reject;else begin held[at*32+:32]<=fifo_data[31:0];if(at==7)state<=CLASSIFY;else at<=at+1'b1;end end
  CLASSIFY:if(held[223:192]!=32'h31445541)state<=BSTART;
   else if(held[31:0]!=1||held[63]||held[95:64]<4||held[95:64]>4063232||held[65:64]!=0||held[127:96]==0||held[127:96]>2031616||((held[127:96]+1)>>1)!=(held[95:64]>>2)||held[159:128]!=48000||held[255:224]==0||held[255:224]>10159)reject;
   else begin cache_valid<=0;cache_loading<=1;cache_percent<=0;cache_asset<=held[63:32];cache_samples<=held[116:96];cache_generation<=cache_generation+1'b1;position<=0;bucket<=0;crc<=32'hffffffff;state<=AUDIO;end
  BSTART:if(b_read)begin at<=0;state<=BMETA;end
  BMETA:if(b_read)begin if(at==7)state<=BODY;else at<=at+1'b1;end
  BODY:if(fifo_read&&fifo_data[33:32]==2)state<=IDLE;
  AUDIO:if(fifo_read)begin
   if(fifo_data[33:32]==0)begin
    position<=position+22'd4;crc_data<=fifo_data[31:0];crc_left<=3;state<=DIGEST;
    if(bucket+1>=held[255:224])begin bucket<=0;if(cache_percent<99)cache_percent<=cache_percent+1'b1;end else bucket<=bucket+1'b1;
   end else if(fifo_data[33:32]!=2||fifo_data[31:0]!=held[95:64]||position!=held[95:64]||(~crc)!=held[191:160])reject;
   else state<=FINISH;
  end
  DIGEST:begin crc<=crc_byte(crc,crc_data[7:0]);crc_data<={8'd0,crc_data[31:8]};crc_left<=crc_left-1'b1;if(crc_left==0)state<=AUDIO;end
  FINISH:if(writes_idle)begin cache_valid<=1;cache_loading<=0;cache_percent<=100;state<=IDLE;end
  default:state<=state;
 endcase
endmodule
