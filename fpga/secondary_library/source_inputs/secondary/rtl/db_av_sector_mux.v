`timescale 1ns/1ps
// Whole-sector arbitration. Audio requests only when its PCM FIFO needs data.
// Ownership is held through end, then through requester-low and CDC reset gap.
module db_av_sector_mux(
 input wire clk,rst,input wire media_req,input wire[31:0]media_lba,input wire[3:0]media_count,
 input wire audio_req,input wire[31:0]audio_lba,
 output reg request,output reg[31:0]lba,output reg[3:0]count,output reg audio,
 input wire[31:0]data,input wire valid,done,
 output wire media_valid,media_done,audio_valid,audio_done
);
 localparam IDLE=0,ACTIVE=1,WAIT_LOW=2,GAP=3;
 reg[1:0]state;reg[3:0]gap;reg last_audio;
 assign media_valid=state==ACTIVE&&!audio&&valid;
 assign media_done=state==ACTIVE&&!audio&&done;
 assign audio_valid=state==ACTIVE&&audio&&valid;
 assign audio_done=state==ACTIVE&&audio&&done;
 always@(posedge clk or posedge rst)
  if(rst)begin state<=IDLE;request<=0;lba<=0;count<=1;audio<=0;gap<=0;last_audio<=0;end
  else case(state)
   IDLE:if(media_req||audio_req)begin
    // A persistent media request cannot be starved by back-to-back audio/FAT.
    audio<=audio_req&&(!media_req||!last_audio);
    lba<=audio_req&&(!media_req||!last_audio)?audio_lba:media_lba;
    count<=audio_req&&(!media_req||!last_audio)?4'd1:media_count;
    request<=1;state<=ACTIVE;
   end
   ACTIVE:if(done)begin request<=0;last_audio<=audio;state<=WAIT_LOW;end
   WAIT_LOW:if(audio?!audio_req:!media_req)begin gap<=12;state<=GAP;end
   GAP:if(gap==0)state<=IDLE;else gap<=gap-1'b1;
  endcase
endmodule
