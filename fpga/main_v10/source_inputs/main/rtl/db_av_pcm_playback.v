`timescale 1ns/1ps
// Exactly48kHz from the original25MHz pixel/audio clock. Prime1024 samples,
// recover by re-priming after underflow, and emit silence while muted/unprimed.
module db_av_pcm_playback(
 input wire clk,rst,enable,mute,input wire[1:0]volume,
 input wire fifo_valid,input wire[15:0]fifo_data,input wire[12:0]fifo_used,
 output wire fifo_take,output reg pcm_valid,output reg[23:0]pcm,output reg underflow
);
 reg[11:0]acc;reg primed;
 wire tick=acc>=3119;
 assign fifo_take=tick&&primed&&fifo_valid&&enable;
 wire signed[23:0]full_sample={fifo_data,8'd0};
 always@(posedge clk or posedge rst)
  if(rst)begin acc<=0;primed<=0;pcm<=0;pcm_valid<=0;underflow<=0;end
  else begin
   acc<=tick?acc-12'd3119:acc+12'd6;pcm_valid<=0;
   if(!enable)primed<=0;
   else if(!primed&&fifo_used>=1024)primed<=1;
   if(tick)begin
    pcm_valid<=1;pcm<=0;
    if(primed&&enable)begin
     if(!fifo_valid)begin primed<=0;underflow<=1;end
     else if(!mute)case(volume)
      0:pcm<=full_sample>>>2;1:pcm<=full_sample>>>1;default:pcm<=full_sample;
     endcase
    end
   end
  end
endmodule
