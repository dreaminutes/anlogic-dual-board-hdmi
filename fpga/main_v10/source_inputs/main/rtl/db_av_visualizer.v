`timescale 1ns/1ps
// 512-point radix-2 FFT. One fabric shift/add multiplier is reused for the
// Hann window and all complex butterflies; no additional DSP is required.
// Every stage divides by two, so signed 12-bit RAM cannot overflow.
module db_av_audio_fft(input clk,rst,input [23:0] pcm,input pcm_valid,frame_start,
 input [5:0] display_index,input [10:0] sine_value,output [7:0] sine_index,output reg [5:0] display_level,output reg display_ready);
// 512-point FFT at 48 kHz: bin181 is 16,968.75 Hz (approximately 17 kHz).
// Keep 64 original ring/linear bands: bins1..32 individually, then four-bin
// mid bands through 9 kHz and five/six-bin high bands through bin181.
// Display mapping only; PCM playback and all FFT butterflies are unchanged.
function [8:0] band_end;input [5:0] band;begin case(band)
 6'd0:band_end=9'd1;
 6'd1:band_end=9'd2;
 6'd2:band_end=9'd3;
 6'd3:band_end=9'd4;
 6'd4:band_end=9'd5;
 6'd5:band_end=9'd6;
 6'd6:band_end=9'd7;
 6'd7:band_end=9'd8;
 6'd8:band_end=9'd9;
 6'd9:band_end=9'd10;
 6'd10:band_end=9'd11;
 6'd11:band_end=9'd12;
 6'd12:band_end=9'd13;
 6'd13:band_end=9'd14;
 6'd14:band_end=9'd15;
 6'd15:band_end=9'd16;
 6'd16:band_end=9'd17;
 6'd17:band_end=9'd18;
 6'd18:band_end=9'd19;
 6'd19:band_end=9'd20;
 6'd20:band_end=9'd21;
 6'd21:band_end=9'd22;
 6'd22:band_end=9'd23;
 6'd23:band_end=9'd24;
 6'd24:band_end=9'd25;
 6'd25:band_end=9'd26;
 6'd26:band_end=9'd27;
 6'd27:band_end=9'd28;
 6'd28:band_end=9'd29;
 6'd29:band_end=9'd30;
 6'd30:band_end=9'd31;
 6'd31:band_end=9'd32;
 6'd32:band_end=9'd36;
 6'd33:band_end=9'd40;
 6'd34:band_end=9'd44;
 6'd35:band_end=9'd48;
 6'd36:band_end=9'd52;
 6'd37:band_end=9'd56;
 6'd38:band_end=9'd60;
 6'd39:band_end=9'd64;
 6'd40:band_end=9'd68;
 6'd41:band_end=9'd72;
 6'd42:band_end=9'd76;
 6'd43:band_end=9'd80;
 6'd44:band_end=9'd84;
 6'd45:band_end=9'd88;
 6'd46:band_end=9'd92;
 6'd47:band_end=9'd96;
 6'd48:band_end=9'd101;
 6'd49:band_end=9'd106;
 6'd50:band_end=9'd111;
 6'd51:band_end=9'd117;
 6'd52:band_end=9'd122;
 6'd53:band_end=9'd127;
 6'd54:band_end=9'd133;
 6'd55:band_end=9'd138;
 6'd56:band_end=9'd143;
 6'd57:band_end=9'd149;
 6'd58:band_end=9'd154;
 6'd59:band_end=9'd159;
 6'd60:band_end=9'd165;
 6'd61:band_end=9'd170;
 6'd62:band_end=9'd175;
 6'd63:band_end=9'd181;
 default:band_end=9'd1;
endcase end endfunction

 function [8:0] reverse9;input [8:0] a;integer k;begin
  for(k=0;k<9;k=k+1)reverse9[k]=a[8-k];
 end endfunction
 function [11:0] absolute12;input signed [11:0] a;begin absolute12=a[11]?-a:a;end endfunction
 function [5:0] log_height;input [12:0] mag;begin
  if(|mag[12:9])log_height=63;
  else if(mag[8])log_height={3'd7,mag[7:5]};
  else if(mag[7])log_height={3'd6,mag[6:4]};
  else if(mag[6])log_height={3'd5,mag[5:3]};
  else if(mag[5])log_height={3'd4,mag[4:2]};
  else if(mag[4])log_height={3'd3,mag[3:1]};
  else if(mag[3])log_height={3'd2,mag[2:0]};
  else if(mag[2])log_height={3'd1,mag[1:0],1'b0};
  else if(mag[1])log_height={3'd0,mag[0],2'b0};
  else log_height=0;
 end endfunction
 localparam CLEAR=0,CAPTURE=1,WINDOW_WAIT=2,CAP_STORE=3,
  FETCH_A=4,LATCH_A=5,LATCH_B=6,MUL0=7,MUL1=8,MUL2=9,MUL3=10,
  SUM=11,WRITE_A=12,WRITE_B=13,LEVEL_FETCH=14,LEVEL_LATCH=15,
  LEVEL_STORE=16,WAIT_FRAME=17,DECAY=18,WINDOW_FETCH=19,FFT_COS=20;
 reg [4:0] state;
 reg [6:0] clear_index;
 reg [8:0] sample_index,half_span,group_base,butterfly;
 reg [3:0] stage;
 wire [8:0] address_a=group_base+butterfly,address_b=address_a+half_span;
 wire [8:0] twiddle_phase=butterfly<<(8-stage);
 wire [8:0] trig_phase=(state==CAPTURE||state==WINDOW_FETCH)?sample_index+9'd128:
  ((state==FETCH_A||state==LATCH_A||state==LATCH_B||state==FFT_COS||state==MUL1)?twiddle_phase+9'd128:twiddle_phase);
 assign sine_index=trig_phase[7]?(8'd128-{1'b0,trig_phase[6:0]}):{1'b0,trig_phase[6:0]};
 reg sine_sign;
 always @(posedge clk or posedge rst)if(rst)sine_sign<=0;else sine_sign<=trig_phase[8];
 wire signed [11:0] trig=sine_sign?-$signed({1'b0,sine_value}):$signed({1'b0,sine_value});
 reg signed [11:0] ar,ai,br,bi;
 reg signed [23:0] p0,p1,p2,p3;
 reg signed [13:0] tr,ti;
 wire signed [14:0] plus_r=$signed(ar)+$signed(tr),plus_i=$signed(ai)+$signed(ti);
 wire signed [14:0] minus_r=$signed(ar)-$signed(tr),minus_i=$signed(ai)-$signed(ti);
 wire signed [24:0] product_r=$signed(p0)+$signed(p1),product_i=$signed(p2)-$signed(p3);
 reg signed [11:0] windowed,pcm_held;
 reg [5:0] band,new_height;reg [8:0] scan_bin;reg [12:0] band_peak;
 reg front_bank,seen_pcm,decaying;
 reg [11:0] timeout_frames;
 reg [23:0] fft_ram[0:511] /* fehdl force_ram=1, ram_style="bram" */;
 reg [23:0] ram_q;
 wire [8:0] ram_read_address=(state==LATCH_A)?address_b:((state==LEVEL_FETCH||state==LEVEL_LATCH)?scan_bin:address_a);
 wire ram_write=(state==CAP_STORE||state==WRITE_A||state==WRITE_B);
 wire [8:0] ram_write_address=(state==CAP_STORE)?reverse9(sample_index):((state==WRITE_A)?address_a:address_b);
 wire [23:0] ram_write_data=(state==CAP_STORE)?{windowed,12'd0}:
  ((state==WRITE_A)?{plus_r[12:1],plus_i[12:1]}:{minus_r[12:1],minus_i[12:1]});
 always @(posedge clk)begin
  if(ram_write&&!rst)fft_ram[ram_write_address]<=ram_write_data;
  ram_q<=fft_ram[ram_read_address];
 end
 reg [5:0] level_ram[0:127] /* fehdl force_ram=1, ram_style="bram" */;
 reg [5:0] old_height;
 wire level_write=(state==CLEAR||state==LEVEL_STORE)&&!rst;
 // True dual-port RAM: port A reads the current visible band's old level,
 // then writes the new level into the hidden bank. Port B serves every pixel.
 wire [6:0] analysis_address=(state==CLEAR)?clear_index:
  ((state==LEVEL_STORE)?{~front_bank,band}:{front_bank,band});
 wire [5:0] release_height=(old_height>2)?old_height-6'd2:6'd0;
 wire [5:0] smoothed=(new_height>=release_height)?new_height:release_height;
 always @(posedge clk)begin
  if(level_write)level_ram[analysis_address]<=(state==CLEAR)?6'd0:smoothed;
  old_height<=level_ram[analysis_address];
 end
 always @(posedge clk)begin
  display_level<=level_ram[{front_bank,display_index}];
 end
 wire [11:0] abs_r=absolute12(ram_q[23:12]),abs_i=absolute12(ram_q[11:0]);
 wire [12:0] magnitude=(abs_r>=abs_i)?{1'b0,abs_r}+{2'b0,abs_i[11:1]}:{1'b0,abs_i}+{2'b0,abs_r[11:1]};
 reg multiply_start;reg signed [11:0] multiply_a,multiply_b;
 wire multiply_done;wire signed [23:0] multiply_result;
 db_av_dsp_multiply multiplier(.clk(clk),.rst(rst),.start(multiply_start),.a(multiply_a),.b(multiply_b),.done(multiply_done),.result(multiply_result));
 wire signed [12:0] window_raw=13'sd1024-$signed(trig);
 wire [12:0] next_peak=(magnitude>band_peak)?magnitude:band_peak;
 always @(posedge clk or posedge rst)
 if(rst)begin
  state<=CLEAR;clear_index<=0;sample_index<=0;half_span<=1;group_base<=0;butterfly<=0;stage<=0;
  ar<=0;ai<=0;br<=0;bi<=0;p0<=0;p1<=0;p2<=0;p3<=0;tr<=0;ti<=0;windowed<=0;pcm_held<=0;
  band<=0;scan_bin<=1;band_peak<=0;new_height<=0;front_bank<=0;display_ready<=0;seen_pcm<=0;decaying<=0;timeout_frames<=0;
  multiply_start<=0;multiply_a<=0;multiply_b<=0;
 end else begin
  multiply_start<=0;
  if(frame_start)begin seen_pcm<=pcm_valid;timeout_frames<=seen_pcm?0:timeout_frames+1'b1;end
  else if(pcm_valid)seen_pcm<=1;
  case(state)
   CLEAR:begin
    if(clear_index==127)begin state<=CAPTURE;display_ready<=1;end
    else clear_index<=clear_index+1'b1;
   end
   CAPTURE:begin
    if(pcm_valid)begin
     pcm_held<=$signed(pcm[23:12]);state<=WINDOW_FETCH;
    end else if(frame_start&&!seen_pcm)begin sample_index<=0;band<=0;decaying<=1;state<=DECAY;end
   end
   WINDOW_FETCH:begin multiply_a<=pcm_held;multiply_b<=window_raw>>>1;multiply_start<=1;state<=WINDOW_WAIT;end
   WINDOW_WAIT:if(multiply_done)begin windowed<=multiply_result>>>10;state<=CAP_STORE;end
   CAP_STORE:if(sample_index==511)begin
    stage<=0;half_span<=1;group_base<=0;butterfly<=0;decaying<=0;state<=FETCH_A;
   end else begin sample_index<=sample_index+1'b1;state<=CAPTURE;end
   FETCH_A:state<=LATCH_A;
   LATCH_A:begin ar<=ram_q[23:12];ai<=ram_q[11:0];state<=LATCH_B;end
   LATCH_B:begin
    br<=ram_q[23:12];bi<=ram_q[11:0];state<=FFT_COS;
   end
   FFT_COS:begin multiply_a<=br;multiply_b<=trig;multiply_start<=1;state<=MUL0;end
   MUL0:if(multiply_done)begin
    p0<=multiply_result;multiply_a<=bi;multiply_b<=trig;multiply_start<=1;state<=MUL1;
   end
   MUL1:if(multiply_done)begin
    p1<=multiply_result;multiply_a<=bi;multiply_b<=trig;multiply_start<=1;state<=MUL2;
   end
   MUL2:if(multiply_done)begin
    p2<=multiply_result;multiply_a<=br;multiply_b<=trig;multiply_start<=1;state<=MUL3;
   end
   MUL3:if(multiply_done)begin p3<=multiply_result;state<=SUM;end
   SUM:begin tr<=product_r>>>10;ti<=product_i>>>10;state<=WRITE_A;end
   WRITE_A:state<=WRITE_B;
   WRITE_B:begin
    state<=FETCH_A;
    if(butterfly+1<half_span)butterfly<=butterfly+1'b1;
    else begin
     butterfly<=0;
     if({1'b0,group_base}+({1'b0,half_span}<<1)<512)group_base<=group_base+(half_span<<1);
     else begin
      group_base<=0;
      if(stage==8)begin band<=0;scan_bin<=1;band_peak<=0;state<=LEVEL_FETCH;end
      else begin stage<=stage+1'b1;half_span<=half_span<<1;end
     end
    end
   end
   LEVEL_FETCH:state<=LEVEL_LATCH;
   LEVEL_LATCH:begin
    if(scan_bin==band_end(band))begin new_height<=log_height(next_peak);state<=LEVEL_STORE;end
    else begin band_peak<=next_peak;scan_bin<=scan_bin+1'b1;state<=LEVEL_FETCH;end
   end
   DECAY:begin new_height<=0;state<=LEVEL_STORE;end
   LEVEL_STORE:begin
    if(band==63)state<=WAIT_FRAME;
    else begin band<=band+1'b1;scan_bin<=scan_bin+1'b1;band_peak<=0;state<=decaying?DECAY:LEVEL_FETCH;end
   end
   WAIT_FRAME:if(frame_start)begin front_bank<=~front_bank;sample_index<=0;state<=CAPTURE;end
   default:state<=CLEAR;
  endcase
 end
endmodule

// Signed Booth multiplication uses a 13-bit adder, rather than a 24-bit
// accumulator plus separate operand/result negation. Still exactly 12 steps.
// Registered signed12x12 multiply: inferred native DSP, one result per request.
module db_av_dsp_multiply(input clk,rst,start,input signed[11:0]a,b,output reg done,output reg signed[23:0]result);
 always@(posedge clk)begin
  done<=0;if(rst)begin done<=0;result<=0;end
  else if(start)begin result<=$signed(a)*$signed(b);done<=1;end
 end
endmodule
module db_av_visualizer(input clk,rst,input [23:0] pcm,input pcm_valid,frame_start,enable,style,
 input [9:0] x,y,input [10:0] sine_value,output [7:0] sine_index,output wire ink,glow,output wire [23:0] color);
 function signed [10:0] atan_step;input integer i;begin case(i)
  0:atan_step=256;1:atan_step=151;2:atan_step=80;3:atan_step=41;4:atan_step=20;
  5:atan_step=10;6:atan_step=5;7:atan_step=3;default:atan_step=1;
 endcase end endfunction
 // Four-pixel raster lookahead absorbs the CORDIC and synchronous level read.
 // Both overlays start after x=64, so row changes have settled before any ink.
 // Coordinate equality also suppresses stale output on arbitrary raster jumps.
 wire [9:0] ahead=x+10'd4;
 wire [9:0] abs_x=(ahead>=320)?ahead-10'd320:10'd320-ahead;
 wire [9:0] abs_y=(y>=224)?y-10'd224:10'd224-y;
 // Preserve V22 signed 11-bit half-pixel CORDIC. The enlarged 208-pixel
 // bounding square covers every 1.5x ring pixel; all intermediate vectors
 // inside it are -416..970, safely within -1024..1023. Outside is transparent.
 reg signed [10:0] cx[0:3],cy[0:3];reg signed [10:0] ca[0:3];
 reg [9:0] target_x[0:3],target_y[0:3];
 // Three fixed rotations per pipeline group. The 25 MHz pixel clock
 // allows this combinational depth, saving 318 registers and their routing.
 always @(posedge clk)begin
  cx[0]<=$signed({abs_x,1'b0});cy[0]<=$signed({abs_y,1'b0});ca[0]<=0;
  target_x[0]<=ahead;target_y[0]<=y;
 end
 wire signed [10:0] rotated_x[0:8],rotated_y[0:8];wire signed [10:0] rotated_a[0:8];
 genvar rotation;
 generate for(rotation=0;rotation<9;rotation=rotation+1)begin:fixed_rotation
  wire signed [10:0] ix,iy;wire signed [10:0] ia;
  if(rotation%3==0)begin:from_register
   assign ix=cx[rotation/3];assign iy=cy[rotation/3];assign ia=ca[rotation/3];
  end else begin:from_previous
   assign ix=rotated_x[rotation-1];assign iy=rotated_y[rotation-1];assign ia=rotated_a[rotation-1];
  end
  assign rotated_x[rotation]=(iy>=0)?ix+(iy>>>rotation):ix-(iy>>>rotation);
  assign rotated_y[rotation]=(iy>=0)?iy-(ix>>>rotation):iy+(ix>>>rotation);
  assign rotated_a[rotation]=(iy>=0)?ia+atan_step(rotation):ia-atan_step(rotation);
  if(rotation%3==2)begin:group_register
   always @(posedge clk)begin
    cx[rotation/3+1]<=rotated_x[rotation];cy[rotation/3+1]<=rotated_y[rotation];ca[rotation/3+1]<=rotated_a[rotation];
    target_x[rotation/3+1]<=target_x[rotation/3];target_y[rotation/3+1]<=target_y[rotation/3];
   end
  end
 end endgenerate
 wire [9:0] angle=(ca[3]<0)?10'd0:((ca[3]>512)?10'd512:ca[3][9:0]);
 wire [10:0] half_angle=(target_y[3]>=224)?11'd512-{1'b0,angle}:11'd512+{1'b0,angle};
 wire [5:0] ring_index=(half_angle>=1024)?6'd63:half_angle[9:4];
 wire [5:0] linear_index=(target_x[3]-10'd64)>>3;
 wire [5:0] display_index=style?ring_index:linear_index;
 wire [5:0] level;wire ready;
 db_av_audio_fft fft(.clk(clk),.rst(rst),.pcm(pcm),.pcm_valid(pcm_valid),.frame_start(frame_start),
  .display_index(display_index),.sine_index(sine_index),.sine_value(sine_value),.display_level(level),.display_ready(ready));
 reg [9:0] tx_q,ty_q,actual_x,actual_y;reg [10:0] radius_q;
 reg [10:0] angle_q;reg [5:0] index_q;reg enable_q,style_q;
 always @(posedge clk or posedge rst)
 if(rst)begin tx_q<=0;ty_q<=0;actual_x<=0;actual_y<=0;radius_q<=0;angle_q<=0;index_q<=0;enable_q<=0;style_q<=0;end
 else begin
  tx_q<=target_x[3];ty_q<=target_y[3];actual_x<=x;actual_y<=y;radius_q<=cx[3];angle_q<=half_angle;
  index_q<=display_index;enable_q<=enable;style_q<=style;
 end
 wire aligned=ready&&enable_q&&tx_q==actual_x&&ty_q==actual_y;
 // Display displacement: linear 3x, ring 1.5x; preserve FFT/log levels and PCM.
 wire [8:0] expansion=({3'd0,level}<<1)+{3'd0,level}+{5'd0,level[5:2]}+{8'd0,level[5]};
 wire [10:0] ring_expansion={2'd0,expansion}+{3'd0,expansion[8:1]};
 wire [10:0] ring_limit=11'd374+ring_expansion;
 // Ring uses floor(1.5 * original expansion), matching pixel rasterization.
 // Full-scale radius is about 207 pixels and fits inside the active screen.
 wire ring_area=radius_q>=369&&radius_q<=ring_limit&&tx_q>=112&&tx_q<528&&ty_q>=16&&ty_q<432;
 wire ring_core=ring_area&&angle_q[3:0]>=2&&angle_q[3:0]<12&&radius_q+2<=ring_limit;
 wire ring_halo=ring_area&&angle_q[3:0]<14;
 wire [7:0] linear_height={level,1'b0}+{2'b0,level};
 wire [9:0] rise=10'd408-ty_q;
 wire linear_area=tx_q>=64&&tx_q<576&&ty_q>=217&&ty_q<=408;
 wire linear_core=linear_area&&tx_q[2:0]>=2&&tx_q[2:0]<6&&rise<={2'd0,linear_height};
 wire linear_halo=linear_area&&tx_q[2:0]>=1&&tx_q[2:0]<7&&rise<=({2'd0,linear_height}+2);
 assign ink=aligned&&(style_q?ring_halo:linear_halo);
 assign glow=style_q?!ring_core:!linear_core;
 wire [4:0] gradient=(index_q<32)?index_q[4:0]:~index_q[4:0];
 wire [7:0] red=8'd224-{1'b0,gradient,2'b0},green=8'd112+{3'd0,gradient},blue=8'd224+{3'd0,gradient};
 assign color=style_q?24'h59e4eb:{red,green,blue};
endmodule
