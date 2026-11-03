`timescale 1ns/1ps
// Audio is the video timeline even while background music is selected.
// Switching SW5 never seeks/restarts the cached original soundtrack.
module db_library_pcm_select(
 input clk,rst,input bg_valid,input[23:0]bg_pcm,input music_select,mute,input[1:0]volume,
 input[39:0]control,input[60:0]response,
 output[20:0]request_word,output[40:0]play_position,
 output reg pcm_valid,output reg[23:0]pcm,output reg underflow
);
 // control={run,cache-match,play_epoch8,cache_generation8,total_samples21,pad1}
 wire run=control[39],valid=control[38];wire[7:0]epoch=control[37:30],generation=control[29:22];
 wire[20:0]total=control[21:1];reg[7:0]seen_epoch;reg[20:0]cursor;reg[31:0]time90;reg[2:0]fraction;
 wire tag_ok=response[60]&&response[59:52]==generation&&response[51:32]==cursor[20:1];
 wire signed[23:0]sample=cursor[0]?{response[31:16],8'd0}:{response[15:0],8'd0};
 assign request_word=valid?{1'b0,cursor[20:1]}:21'h100000;
 // The memory scheduler needs only timeline and EOF, not the full cursor.
 assign play_position={seen_epoch,cursor>=total,time90};
 always@(posedge clk or posedge rst)
 if(rst)begin seen_epoch<=0;cursor<=0;time90<=0;fraction<=0;pcm<=0;pcm_valid<=0;underflow<=0;end
 else begin
  pcm_valid<=0;
  if(epoch!=seen_epoch)begin seen_epoch<=epoch;cursor<=0;time90<=0;fraction<=0;end
  if(bg_valid)begin
   pcm_valid<=1;pcm<=0;
   if(music_select)pcm<=mute?24'd0:bg_pcm;
   else if(run&&valid&&epoch==seen_epoch&&cursor<total&&tag_ok&&!mute)case(volume)
    0:pcm<=sample>>>2;1:pcm<=sample>>>1;default:pcm<=sample;
   endcase
   if(run&&valid&&epoch==seen_epoch)begin
    if(cursor<total)cursor<=cursor+1'b1;
    time90<=time90+(fraction==0?32'd1:32'd2);fraction<=fraction+3'd7;
    if(cursor<total&&!tag_ok)underflow<=1;
   end
  end
 end
endmodule
