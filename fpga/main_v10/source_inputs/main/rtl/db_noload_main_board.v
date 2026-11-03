`timescale 1ns/1ps
// Independent full-frame hardware diagnostic. Production V22 files are intact.
module db_noload_main_board(
 input wire clk,sw0,sw1,sw5,sw6,sw7,input wire[3:0]col,output wire[3:0]row,input wire forward_clk,link_valid,input wire[7:0]link_data,reserved,
 output wire credit_out,command_out,output wire[7:0]led,
 output wire HDMI_CLK_P,HDMI_D0_P,HDMI_D1_P,HDMI_D2_P
);
 wire rst_start,rst_all,mem_rst,video_clk,hdmi_5x_clk,mem_clk,ram_clk,unused_clk,capture_250_raw;
 media_power_reset r(.clk(clk),.rst(rst_start));
 db_cable10_video_pll vpll(.refclk(clk),.reset(1'b0),.clk0_out(video_clk),.clk1_out(hdmi_5x_clk),.capture_out(capture_250_raw));
 db_mem50_pll memory_pll(.refclk(clk),.reset(1'b0),.clk0_out(mem_clk),.clk1_out(unused_clk),.clk2_out(ram_clk));
 reset_sync u_rs_video(.clk(video_clk),.arst(rst_start),.rst(rst_all));
 reset_sync u_rs_mem(.clk(mem_clk),.arst(rst_start),.rst(mem_rst));
 (* syn_keep=1 *)wire enable;
 db_av_start startup(.clk(clk),.rst(rst_start),.sw0(1'b1),.enable(enable));
 wire capture_clk;
 EG_LOGIC_BUFG capture_bufg(.i(capture_250_raw),.o(capture_clk));
 wire session_confirm_src;
 wire[15:0]rate_info;wire[23:0]audio_pcm;wire audio_valid;
 wire[6:0]status;wire[23:0]video_rgb;wire video_de,video_vs,base_de,base_vs;wire[23:0]base_rgb;wire[9:0]pixel_x,pixel_y;wire[1:0]pcm_volume;wire video_hold,video_drop,music_select;wire pcm_mute,song_select,command_serial,run_control,menu_control,auto_play,file_room;wire[7:0]next_number,frame_grant;wire[2:0]transition_mode;wire[1:0]transition_duration;
 db_noload_memory_video core(.video_hold(video_hold),.video_drop(video_drop),.audio_music(music_select),.session_confirm_src(session_confirm_src),.rate_info(rate_info),.run_control(run_control),.menu_control(menu_control),.transition_mode(transition_mode),.transition_duration(transition_duration),.next_number(next_number),.frame_grant(frame_grant),.file_room(file_room),.audio_pcm(audio_pcm),.audio_valid(audio_valid),.audio_volume(pcm_volume),.audio_mute(pcm_mute),.capture_clk(capture_clk),.clk50(clk),.mem_clk(mem_clk),.ram_clk(ram_clk),.video_clk(video_clk),
  .start_rst(rst_start),.mem_rst(mem_rst),.video_rst(rst_all),.enable(enable&&!rst_start),
  .forward_clk(forward_clk),.link_valid(link_valid),.link_data(link_data),.reserved(reserved),
  .credit_out(credit_out),.command_out(),.status(status),
  .rgb(base_rgb),.de(base_de),.vs(base_vs),.pixel_x(pixel_x),.pixel_y(pixel_y));
 db_noload_panel panel(.music_select(music_select),.rate_info(rate_info),.clk50(clk),.rst(rst_start),.video_clk(video_clk),.video_rst(rst_all),.sw0(sw0),.sw5(sw5),.sw6(sw6),.sw7(sw7),.col(col),.row(row),
 .de(base_de),.vs(base_vs),.x(pixel_x),.y(pixel_y),.rgb(base_rgb),.audio_pcm(audio_pcm),.audio_valid(audio_valid),
 .out_rgb(video_rgb),.out_de(video_de),.out_vs(video_vs),.pcm_volume(pcm_volume),.pcm_mute(pcm_mute),.song_select(song_select),.key_next(),.key_auto(),.transition_mode(transition_mode),.transition_duration(transition_duration),.run_control(run_control),.menu_control(menu_control),.auto_play(auto_play),.next_number(next_number));
 db_full_command_tx commands(.clk(clk),.rst(rst_start),.enable(enable),.control_word({file_room,3'd0,video_hold,video_drop,session_confirm_src,frame_grant,next_number,transition_duration,transition_mode,menu_control,run_control,auto_play,song_select}),.serial_out(command_serial));
 assign command_out=enable?command_serial:1'bz;
 assign led={status,audio_valid};
wire axis_s_user,axis_s_valid,axis_s_last,axis_s_ready;wire [23:0] axis_s_data;
wire [9:0] tmds_ch0_data,tmds_ch1_data,tmds_ch2_data,tmds_clk_data;
// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_vs          (video_vs),
    .I_de          (video_de),
    .I_rgb         (video_rgb),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

//---------------------------------------------------------------------------
// EDID / DDC 处理说明：
//   官方板把 HDMI 的 DDC(SCL/SDA) 接到 FPGA，上电后用 startup_pulse 触发一次
//   EDID 读取。本板 HDMI 只引出了 4 对 TMDS 差分，没有 DDC 通路，
//   因此这里不再触发 EDID 读取（保持常 0），DDC 输出也不引出到芯片引脚。
//   视频时序完全由下面 HDMI 核的 HTOTAL/VTOTAL 等参数固定为 640x480@60。
//---------------------------------------------------------------------------

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_all),
    .I_edid_read_trig   (1'b0),             // 本板无 DDC，不触发 EDID 读取
    .O_edid_read_valid  (),
    .O_edid_read_data   (),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_pcm),
    .I_audio_right_data (audio_pcm),
    .I_acr_valid        (audio_valid),
    .I_acr_cts          (20'd25000),
    .I_acr_n            (20'd6144),

    .O_video_locked     (),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_start),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule

