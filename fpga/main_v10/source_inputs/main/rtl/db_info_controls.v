`timescale 1ns/1ps
module db_info_controls #(parameter ROW_PERIOD=25000,DEBOUNCE_SCANS=10,SWITCH_CYCLES=1000000)
(input clk,rst,sw0,sw5,sw6,sw7,input [3:0] col,output [3:0] row,
 output[15:0]keys_down,keys_press,output reg game_mode,music_on,
 output key_next,key_auto,output reg running,menu_open,
 output reg [3:0] selected,output reg [1:0] draft_volume,draft_brightness,draft_contrast,
 output reg [2:0] draft_transition,transition_mode,
 output reg [1:0] draft_duration,transition_duration,
 output reg draft_subtitle,subtitle_enable,output reg [1:0] draft_subtitle_speed,subtitle_speed,
 output reg draft_audio,audio_enable,draft_audio_style,audio_style,
 output reg draft_song,output reg [1:0] volume,brightness,contrast,output reg song_select);
// Volume ranks: 0=mute, 1=25%, 2=50% (default), 3=100%.
 reg [15:0] ticks;reg [1:0] row_index;
 (* async_reg="true" *)reg [3:0] c0,c1;
 (* async_reg="true" *)reg [3:0] sw_a,sw_b;
 reg [19:0] switch0_count,switch7_count;reg[3:0]switch6_count,switch5_count;
 reg [15:0] stable,press;reg [3:0] count[0:15];integer j;integer idx;
 assign keys_down=stable;assign keys_press=press;
 assign row=~(4'b0001<<row_index);
 assign key_next=~stable[7];assign key_auto=~stable[6];
 wire sw0_done=(switch0_count==SWITCH_CYCLES-1)&&(sw_b[0]!=running);
 wire switch_sample=ticks==ROW_PERIOD-1&&row_index==0;
 wire sw5_done=switch_sample&&(switch5_count==DEBOUNCE_SCANS-1)&&(sw_b[3]!=music_on);
 wire sw6_done=switch_sample&&(switch6_count==DEBOUNCE_SCANS-1)&&(sw_b[1]!=game_mode);
 wire sw7_done=(switch7_count==SWITCH_CYCLES-1)&&(sw_b[2]!=menu_open);
 // Independent, full-row scanner. Emit a single registered event per press.
 always @(posedge clk or posedge rst)
 if(rst)begin ticks<=0;row_index<=0;c0<=15;c1<=15;stable<=0;press<=0;
  for(j=0;j<16;j=j+1)count[j]<=0;end
 else begin
  c0<=col;c1<=c0;press<=0;
  if(ticks==ROW_PERIOD-1)begin ticks<=0;row_index<=row_index+1'b1;
   for(j=0;j<4;j=j+1)begin
    idx={row_index,2'b0}+j;
    if((~c1[j])==stable[idx])count[idx]<=0;
    else if(count[idx]==DEBOUNCE_SCANS-1)begin
     stable[idx]<=~c1[j];count[idx]<=0;if(!c1[j])press[idx]<=1;
    end else count[idx]<=count[idx]+1'b1;
   end
  end else ticks<=ticks+1'b1;
 end
 function [1:0] brightness_rank;input [1:0] code;begin
  case(code)2:brightness_rank=0;1:brightness_rank=1;0:brightness_rank=2;default:brightness_rank=3;endcase
 end endfunction
 function [1:0] brightness_code;input [1:0] rank;begin
  case(rank)0:brightness_code=2;1:brightness_code=1;2:brightness_code=0;default:brightness_code=3;endcase
 end endfunction
 function [1:0] contrast_rank;input [1:0] code;begin
  case(code)1:contrast_rank=0;0:contrast_rank=1;default:contrast_rank=code;endcase
 end endfunction
 function [1:0] contrast_code;input [1:0] rank;begin
  case(rank)0:contrast_code=1;1:contrast_code=0;default:contrast_code=rank;endcase
 end endfunction
 always @(posedge clk or posedge rst)
 if(rst)begin
  sw_a<=0;sw_b<=0;switch0_count<=0;switch7_count<=0;switch6_count<=0;switch5_count<=0;music_on<=0;game_mode<=0;running<=0;menu_open<=0;
  draft_audio<=0;audio_enable<=0;draft_audio_style<=0;audio_style<=0;draft_subtitle<=0;subtitle_enable<=0;draft_subtitle_speed<=1;subtitle_speed<=1;
  selected<=0;draft_duration<=1;transition_duration<=1;draft_transition<=0;transition_mode<=0;draft_volume<=2;draft_brightness<=2;draft_contrast<=1;draft_song<=0;
  volume<=2;brightness<=0;contrast<=0;song_select<=0;
 end else begin
  sw_a<={sw5,sw7,sw6,sw0};sw_b<=sw_a;
  if(running&&menu_open&&!game_mode&&!sw7_done)begin
   volume<=draft_volume;brightness<=brightness_code(draft_brightness);
   contrast<=contrast_code(draft_contrast);song_select<=draft_song;transition_mode<=draft_transition;transition_duration<=draft_duration;subtitle_enable<=draft_subtitle;subtitle_speed<=draft_subtitle_speed;audio_enable<=draft_audio;audio_style<=draft_audio_style;
  end
  if(sw_b[0]==running||sw0_done)switch0_count<=0;else switch0_count<=switch0_count+1'b1;
  if(sw0_done)running<=sw_b[0];
  if(sw_b[1]==game_mode||sw6_done)switch6_count<=0;else if(switch_sample)switch6_count<=switch6_count+1'b1;
  if(sw6_done)game_mode<=sw_b[1];
  if(sw_b[3]==music_on||sw5_done)switch5_count<=0;else if(switch_sample)switch5_count<=switch5_count+1'b1;
  if(sw5_done)music_on<=sw_b[3];
  if(sw_b[2]==menu_open||sw7_done)switch7_count<=0;else switch7_count<=switch7_count+1'b1;
  if(sw7_done)begin
   menu_open<=sw_b[2];
   if(sw_b[2])begin
    // Opening copies the saved settings; each edit applies on the next clock.
    selected<=0;draft_volume<=volume;draft_brightness<=brightness_rank(brightness);
    draft_contrast<=contrast_rank(contrast);draft_song<=song_select;draft_transition<=transition_mode;draft_duration<=transition_duration;draft_subtitle<=subtitle_enable;draft_subtitle_speed<=subtitle_speed;draft_audio<=audio_enable;draft_audio_style<=audio_style;
   end else begin
    // Closing retains the final edits; SW0 never erases settings.
    volume<=draft_volume;brightness<=brightness_code(draft_brightness);
    contrast<=contrast_code(draft_contrast);song_select<=draft_song;transition_mode<=draft_transition;transition_duration<=draft_duration;subtitle_enable<=draft_subtitle;subtitle_speed<=draft_subtitle_speed;audio_enable<=draft_audio;audio_style<=draft_audio_style;
   end
  end else if(running&&menu_open&&!game_mode)begin
   if(press[15])selected<=(selected==0)?4'd9:selected-1'b1;
   else if(press[14])selected<=(selected==9)?4'd0:selected+1'b1;
   else if(press[11])case(selected)
    0:if(draft_volume<3)draft_volume<=draft_volume+1'b1;
    1:if(draft_brightness<3)draft_brightness<=draft_brightness+1'b1;
    2:if(draft_contrast<3)draft_contrast<=draft_contrast+1'b1;
    3:draft_song<=~draft_song;
    4:draft_transition<=(draft_transition==5)?3'd0:draft_transition+1'b1;
    5:if(draft_duration<3)draft_duration<=draft_duration+1'b1;
    6:draft_subtitle<=~draft_subtitle;
    7:if(draft_subtitle_speed<3)draft_subtitle_speed<=draft_subtitle_speed+1'b1;
    8:draft_audio<=~draft_audio;
    9:draft_audio_style<=~draft_audio_style;
   endcase
   else if(press[10])case(selected)
    0:if(draft_volume>0)draft_volume<=draft_volume-1'b1;
    1:if(draft_brightness>0)draft_brightness<=draft_brightness-1'b1;
    2:if(draft_contrast>0)draft_contrast<=draft_contrast-1'b1;
    3:draft_song<=~draft_song;
    4:draft_transition<=(draft_transition==0)?3'd5:draft_transition-1'b1;
    5:if(draft_duration>0)draft_duration<=draft_duration-1'b1;
    6:draft_subtitle<=~draft_subtitle;
    7:if(draft_subtitle_speed>0)draft_subtitle_speed<=draft_subtitle_speed-1'b1;
    8:draft_audio<=~draft_audio;
    9:draft_audio_style<=~draft_audio_style;
   endcase
  end
 end
endmodule
