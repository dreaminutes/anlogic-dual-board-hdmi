`timescale 1ns/1ps
module db_noload_panel #(parameter ROW_PERIOD=25000,DEBOUNCE_SCANS=10,SWITCH_CYCLES=1000000)(
 input[15:0]rate_info,
 input clk50,rst,video_clk,video_rst,sw0,sw5,sw6,sw7,input[3:0]col,output[3:0]row,
 input de,vs,input[9:0]x,y,input[23:0]rgb,input[23:0]audio_pcm,input audio_valid,
 output[23:0]out_rgb,output reg out_de,out_vs,output[1:0]pcm_volume,output pcm_mute,output music_select,
 output song_select,key_next,key_auto,output[2:0]transition_mode,output[1:0]transition_duration,output run_control,menu_control,output reg auto_play,output reg[7:0]next_number
);
 wire running,menu_open,game_mode,music_on;wire[15:0]keys_down,keys_press;
 assign run_control=running&&!game_mode;assign menu_control=menu_open||game_mode;
 reg last_next,last_auto;
 always@(posedge clk50 or posedge rst)if(rst)begin auto_play<=1;next_number<=0;last_next<=1;last_auto<=1;end
 else begin last_next<=key_next;last_auto<=key_auto;if(running&&!menu_open&&!game_mode)begin if(last_next&&!key_next)next_number<=next_number+1'b1;if(last_auto&&!key_auto)auto_play<=~auto_play;end end
 wire[3:0]selected;
 wire[1:0]draft_volume,draft_brightness,draft_contrast,draft_duration,volume,brightness,contrast,draft_subtitle_speed,subtitle_speed;
 wire[2:0]draft_transition;
 wire draft_subtitle,subtitle_enable,draft_audio,audio_enable,draft_audio_style,audio_style,draft_song;
 db_sw5_controls #(.ROW_PERIOD(ROW_PERIOD),.DEBOUNCE_SCANS(DEBOUNCE_SCANS),.SWITCH_CYCLES(SWITCH_CYCLES)) controls(
 .clk(clk50),.rst(rst),.sw0(sw0),.sw5(sw5),.sw6(sw6),.sw7(sw7),.game_mode(game_mode),.music_on(music_on),.keys_down(keys_down),.keys_press(keys_press),.col(col),.row(row),
 .key_next(key_next),.key_auto(key_auto),.running(running),.menu_open(menu_open),.selected(selected),
 .draft_volume(draft_volume),.draft_brightness(draft_brightness),.draft_contrast(draft_contrast),.draft_transition(draft_transition),.transition_mode(transition_mode),.draft_duration(draft_duration),.transition_duration(transition_duration),
 .draft_subtitle(draft_subtitle),.subtitle_enable(subtitle_enable),.draft_subtitle_speed(draft_subtitle_speed),.subtitle_speed(subtitle_speed),
 .draft_audio(draft_audio),.audio_enable(audio_enable),.draft_audio_style(draft_audio_style),.audio_style(audio_style),.draft_song(draft_song),.volume(volume),.brightness(brightness),.contrast(contrast),.song_select(song_select));
 localparam[29:0]DEFAULT={1'b0,2'd2,1'b0,1'b1,1'b1,2'd1,1'b0,1'b0,4'd0,2'd2,2'd2,2'd1,1'b0,2'd0,2'd0,3'd0,2'd1};
 wire[29:0]config_source={music_on,volume,audio_style,audio_enable,subtitle_enable,subtitle_speed,running,menu_open,selected,draft_volume,draft_brightness,draft_contrast,draft_song,brightness,contrast,draft_transition,draft_duration};
 wire[29:0]config_video;reg[29:0]c;reg[15:0]rate_frame;
 tv_settings_cdc_v2 #(.WIDTH(30),.RESET_WORD(DEFAULT))settings_transfer(.sclk(clk50),.srst(rst),.dclk(video_clk),.drst(video_rst),.source(config_source),.dest(config_video));
 reg previous_vs;
 always@(posedge video_clk or posedge video_rst)
 if(video_rst)begin c<=DEFAULT;rate_frame<=0;previous_vs<=1;out_de<=0;out_vs<=1;end
 else begin previous_vs<=vs;out_de<=de;out_vs<=vs;if(previous_vs&&!vs)begin c<=config_video;rate_frame<=rate_info;end end
 // V22 menu ranks: 0=mute,1=quarter,2=half,3=full. Player codes start at quarter.
 assign pcm_volume=c[28:27]==0?2'd0:c[28:27]-1'b1;
 assign pcm_mute=c[28:27]==0||!c[21];
 assign music_select=c[29];
 wire[23:0]media_rgb,game_rgb;wire game_active;wire[10:0]game_font_addr;wire[4:0]game_font_data;
 assign out_rgb=game_active?game_rgb:media_rgb;
 db_noload_osd osd(.game_font_enable(game_active),.game_font_addr(game_font_addr),.game_font_data(game_font_data),.rate_info(rate_frame),.clk(video_clk),.rst(video_rst),.de(de),.x(x),.y(y),.rgb(rgb),.out_rgb(media_rgb),
 .running(c[21]),.menu_open(c[20]),.selected(c[19:16]),
 .subtitle_enable(c[24]),.draft_subtitle(c[24]),.subtitle_speed(c[23:22]),.draft_subtitle_speed(c[23:22]),
 .audio_enable(c[25]),.draft_audio(c[25]),.audio_style(c[26]),.draft_audio_style(c[26]),.audio_pcm(audio_pcm),.audio_valid(audio_valid),
 .draft_song(c[9]),.draft_volume(c[15:14]),.draft_brightness(c[13:12]),.draft_contrast(c[11:10]),.draft_transition(c[4:2]),.draft_duration(c[1:0]),.brightness(c[8:7]),.contrast(c[6:5]),.fps(8'd0));
 reg reset_toggle,pause_toggle;
 always@(posedge clk50 or posedge rst)
 if(rst)begin reset_toggle<=0;pause_toggle<=0;end
 else if(!game_mode)begin reset_toggle<=0;pause_toggle<=0;end
 else begin if(keys_press[13])reset_toggle<=~reset_toggle;if(keys_press[12])pause_toggle<=~pause_toggle;end
 wire[4:0]game_config;
 tv_settings_cdc_v2 #(.WIDTH(5),.RESET_WORD(5'd0)) game_transfer(
 .sclk(clk50),.srst(rst),.dclk(video_clk),.drst(video_rst),
 .source({game_mode,reset_toggle,pause_toggle,keys_down[1],keys_down[0]}),.dest(game_config));
 wire[1:0]game_state,lives;wire[2:0]level;wire[11:0]score;
 wire[9:0]player_x,star_x,rock_x;wire[8:0]star_y,rock_y;wire rock_visible;wire[4:0]hit_flash,catch_flash;
 db_star_game game(.clk(video_clk),.rst(video_rst),.frame_tick(previous_vs&&!vs),
 .enable(game_config[4]),.reset_toggle(game_config[3]),.pause_toggle(game_config[2]),.left(game_config[1]),.right(game_config[0]),
 .active(game_active),.state(game_state),.lives(lives),.level(level),.score(score),.player_x(player_x),.star_x(star_x),.rock_x(rock_x),.star_y(star_y),.rock_y(rock_y),.rock_visible(rock_visible),.hit_flash(hit_flash),.catch_flash(catch_flash));
 db_star_renderer renderer(.font_address(game_font_addr),.font_data(game_font_data),.clk(video_clk),.rst(video_rst),.de(de),.x(x),.y(y),
 .state(game_state),.lives(lives),.level(level),.score(score),.player_x(player_x),.star_x(star_x),.rock_x(rock_x),.star_y(star_y),.rock_y(rock_y),.rock_visible(rock_visible),.hit_flash(hit_flash),.catch_flash(catch_flash),.rgb(game_rgb));
endmodule
