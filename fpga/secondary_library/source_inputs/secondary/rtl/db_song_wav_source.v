`timescale 1ns/1ps
// Shares the mounted FAT32 geometry/catalog with the media reader. No second
// mount or directory scanner. V22 WAV format: fixed44-byte PCM16 mono48k header.
module db_song_wav_source(
 input wire clk,rst,enable,catalog_ready,input wire[1:0]song_count,input wire song_select,
 input wire[31:0]song0_cluster,song0_size,song1_cluster,song1_size,
 input wire[31:0]data_base,fat_base,cluster_count,input wire[7:0]sectors_per_cluster,input wire[2:0]cluster_shift,
 output reg sd_req,output reg[31:0]sd_lba,input wire[31:0]sd_data,input wire sd_valid,sd_end,
 output wire pcm_valid,output wire[15:0]pcm_data,input wire pcm_ready,input wire[11:0]pcm_free,
 output reg failed,output wire active
);
 localparam WAIT=0,LBA=1,READ=2,CHECK=3,PRIME=4,LATCH=5,SAMPLE=6,NEXT=7,FAT=8,FAT_CHECK=9,STOP=10;
 reg[3:0]state;reg[31:0]cluster,first_cluster,file_size,file_lba,remaining,declared,position,next_cluster,riff_size;
 reg[7:0]sector_index;reg[7:0]received;reg[6:0]read_index;reg half,first_sector,reading_fat,header_bad;
 reg selected;reg[31:0]buffer_q,word_hold;reg[31:0]sector[0:127];
 reg[27:0]watchdog;
 assign active=state!=WAIT&&state!=STOP;
 assign pcm_valid=state==SAMPLE&&!failed&&enable;
 assign pcm_data=half?word_hold[31:16]:word_hold[15:0];
 always@(posedge clk)begin
  if(sd_valid&&state==READ&&!reading_fat&&received<128)sector[received[6:0]]<=sd_data;
  buffer_q<=sector[read_index];
 end
 task read_sector(input[31:0]a,input f);begin
  sd_lba<=a;sd_req<=1;received<=0;reading_fat<=f;watchdog<=0;state<=READ;
 end endtask
 task fail;begin failed<=1;sd_req<=0;state<=STOP;end endtask
 always@(posedge clk or posedge rst)
  if(rst)begin state<=WAIT;sd_req<=0;sd_lba<=0;failed<=0;cluster<=0;first_cluster<=0;file_size<=0;file_lba<=0;remaining<=0;declared<=0;position<=0;next_cluster<=0;riff_size<=0;
   sector_index<=0;received<=0;read_index<=0;half<=0;first_sector<=1;reading_fat<=0;header_bad<=0;selected<=0;word_hold<=0;watchdog<=0;end
  else if(!enable)begin state<=WAIT;sd_req<=0;failed<=0;end
  // Never abandon a physical sector transaction. Buffered old PCM may drain;
  // sample cursor and FIFOs stay continuous when the requested track changes.
  else if(state!=WAIT&&state!=READ&&(song_select&&song_count>1)!=selected)begin state<=WAIT;sd_req<=0;failed<=0;end
  else case(state)
   WAIT:if(catalog_ready&&song_count!=0)begin
    selected<=song_select&&song_count>1;
    first_cluster<=song_select&&song_count>1?song1_cluster:song0_cluster;
    cluster<=song_select&&song_count>1?song1_cluster:song0_cluster;
    file_size<=song_select&&song_count>1?song1_size:song0_size;
    first_sector<=1;sector_index<=0;position<=0;header_bad<=0;state<=LBA;
   end
   LBA:begin file_lba<=data_base+((cluster-32'd2)<<cluster_shift);state<=NEXT;end
   NEXT:if(pcm_free>=256)read_sector(file_lba+sector_index,0);
   READ:begin
    watchdog<=watchdog+1'b1;
    if(sd_valid)begin
     if(received>=128)fail;else received<=received+1'b1;
     if(reading_fat)begin if(received=={1'b0,cluster[6:0]})next_cluster<=sd_data&32'h0fffffff;end
     else if(first_sector)case(received)
      0:if(sd_data!=32'h46464952)header_bad<=1;
      1:riff_size<=sd_data;
      2:if(sd_data!=32'h45564157)header_bad<=1;
      3:if(sd_data!=32'h20746d66)header_bad<=1;
      4:if(sd_data!=16)header_bad<=1;
      5:if(sd_data!=32'h00010001)header_bad<=1;
      6:if(sd_data!=48000)header_bad<=1;
      7:if(sd_data!=96000)header_bad<=1;
      8:if(sd_data!=32'h00100002)header_bad<=1;
      9:if(sd_data!=32'h61746164)header_bad<=1;
      10:begin declared<=sd_data;remaining<=sd_data;end
     endcase
    end
    if(sd_end)begin sd_req<=0;if(received+(sd_valid?1:0)!=128)fail;else state<=reading_fat?FAT_CHECK:CHECK;end
    else if(watchdog==200000000)fail;
   end
   CHECK:begin
    if(first_sector&&(header_bad||file_size<46||declared<2||declared[0]||declared>file_size-44||riff_size>file_size-8||{1'b0,riff_size}<{1'b0,declared}+36))fail;
    else begin read_index<=first_sector?7'd11:7'd0;position<=first_sector?44:position;half<=0;state<=PRIME;end
   end
   PRIME:state<=LATCH;
   LATCH:begin word_hold<=buffer_q;state<=SAMPLE;end
   SAMPLE:if(pcm_valid&&pcm_ready)begin
    remaining<=remaining-2;position<=position+2;
    if(remaining==2)begin
     // Repeat the selected track, without interrupting the continuous PCM clock.
     cluster<=first_cluster;first_sector<=1;sector_index<=0;position<=0;header_bad<=0;state<=LBA;
    end else if(half)begin
     half<=0;
     if(read_index==127)begin
      first_sector<=0;
      if(sector_index+1<sectors_per_cluster)begin sector_index<=sector_index+1'b1;state<=NEXT;end
      else state<=FAT;
     end else begin read_index<=read_index+1'b1;state<=PRIME;end
    end else half<=1;
   end
   FAT:read_sector(fat_base+(cluster>>7),1);
   FAT_CHECK:if(next_cluster<2||next_cluster>=cluster_count+2||next_cluster==cluster)fail;
    else begin cluster<=next_cluster;sector_index<=0;state<=LBA;end
   STOP:begin end
   default:fail;
  endcase
endmodule
