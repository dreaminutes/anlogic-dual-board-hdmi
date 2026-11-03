`timescale 1ns/1ps
// All visible state changes at video blanking. No frame RAM or multiplier.
module db_star_game #(parameter FRAMES_PER_SECOND=60,LEVEL_SECONDS=10)(
 input clk,rst,frame_tick,enable,left,right,reset_toggle,pause_toggle,
 output reg active,output reg[1:0]state,lives,output reg[2:0]level,
 output reg[11:0]score,output reg[9:0]player_x,star_x,rock_x,
 output reg[8:0]star_y,rock_y,output wire rock_visible,
 output reg[4:0]hit_flash,catch_flash
);
 localparam READY=0,PLAY=1,PAUSED=2,OVER=3;
 reg reset_seen,pause_seen;reg[5:0]frames;reg[3:0]seconds;
 reg[6:0]rock_delay;reg[15:0]random;
 wire[3:0]star_step={1'b0,level}+4'd2,rock_step={1'b0,level}+4'd3;
 wire[9:0]star_next={1'b0,star_y}+star_step,rock_next={1'b0,rock_y}+rock_step;
 wire[9:0]move_x=left&&!right?(player_x<=62?10'd56:player_x-10'd6):
                          right&&!left?(player_x>=578?10'd584:player_x+10'd6):player_x;
 wire star_touch=star_next>=414&&star_y<=444&&star_x+10'd32>=move_x&&star_x<=move_x+10'd32;
 wire rock_touch=rock_next>=412&&rock_y<=446&&rock_x+10'd34>=move_x&&rock_x<=move_x+10'd34;
 assign rock_visible=rock_delay==0;
 task initialize;begin
  state<=READY;lives<=3;level<=0;score<=0;player_x<=320;
  star_x<=320;star_y<=92;rock_x<=464;rock_y<=80;rock_delay<=70;
  frames<=0;seconds<=0;random<=16'h9e37;hit_flash<=0;catch_flash<=0;
 end endtask
 always@(posedge clk or posedge rst)
 if(rst)begin active<=0;reset_seen<=0;pause_seen<=0;initialize;end
 else if(frame_tick)begin
  active<=enable;reset_seen<=reset_toggle;pause_seen<=pause_toggle;
  if(!enable||!active||reset_toggle!=reset_seen)initialize;
  else if(pause_toggle!=pause_seen)begin
   if(state==READY||state==PAUSED)state<=PLAY;
   else if(state==PLAY)state<=PAUSED;
  end else if(state==PLAY)begin
   random<={random[14:0],random[15]^random[13]^random[12]^random[10]};
   player_x<=move_x;
   if(hit_flash!=0)hit_flash<=hit_flash-1'b1;
   if(catch_flash!=0)catch_flash<=catch_flash-1'b1;
   if(frames==FRAMES_PER_SECOND-1)begin
    frames<=0;
    if(seconds==LEVEL_SECONDS-1)begin seconds<=0;if(level<5)level<=level+1'b1;end
    else seconds<=seconds+1'b1;
   end else frames<=frames+1'b1;
   if(star_touch||star_next>=460)begin
    star_y<=88;star_x<=10'd64+{1'b0,random[4:0],4'b0};
    if(star_touch)begin
     catch_flash<=12;
     // Each star adds10; store only the three changing decimal digits.
     if(score!=12'h999)begin
      if(score[3:0]!=9)score[3:0]<=score[3:0]+1'b1;
      else begin score[3:0]<=0;if(score[7:4]!=9)score[7:4]<=score[7:4]+1'b1;
       else begin score[7:4]<=0;score[11:8]<=score[11:8]+1'b1;end end
     end
    end
   end else star_y<=star_next[8:0];
   if(rock_delay!=0)rock_delay<=rock_delay-1'b1;
   else if(rock_touch||rock_next>=460)begin
    rock_y<=84;rock_x<=10'd64+{1'b0,random[9:5],4'b0};rock_delay<=30;
    if(rock_touch)begin hit_flash<=20;if(lives==1)begin lives<=0;state<=OVER;end else lives<=lives-1'b1;end
   end else rock_y<=rock_next[8:0];
  end
 end
endmodule
