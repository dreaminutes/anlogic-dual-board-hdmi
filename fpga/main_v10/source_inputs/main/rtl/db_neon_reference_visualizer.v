`timescale 1ns/1ps
module db_neon_reference_visualizer(input neon_mode,input[5:0]neon_index,output[5:0]neon_level,output neon_ready,
 output[9:0]neon_polar_angle,neon_polar_x,neon_polar_y,output[8:0]neon_polar_radius,output[10:0]neon_polar_radius_q2,input clk,rst,input [23:0] pcm,input pcm_valid,frame_start,enable,style,
 input [9:0] x,y,input [10:0] sine_value,output [7:0] sine_index,output wire ink,glow,output wire [23:0] color);
 function signed [10:0] atan_step;input integer i;begin case(i)
  0:atan_step=256;1:atan_step=151;2:atan_step=80;3:atan_step=41;4:atan_step=20;
  5:atan_step=10;6:atan_step=5;7:atan_step=3;default:atan_step=1;
 endcase end endfunction
 // Four-pixel raster lookahead absorbs the CORDIC and synchronous level read.
 // Both overlays start after x=64, so row changes have settled before any ink.
 // Coordinate equality also suppresses stale output on arbitrary raster jumps.
 wire [9:0] ahead=x+(neon_mode?10'd8:10'd4);
 wire [9:0] abs_x=(ahead>=320)?ahead-10'd320:10'd320-ahead;
 wire [9:0] center_y=neon_mode?10'd240:10'd224;
 wire [9:0] abs_y=(y>=center_y)?y-center_y:center_y-y;
 // Neon coordinates use Q2 precision in signed13. Each legacy operation
 // still truncates to signed11 before the next rotation, preserving its
 // original wrap behaviour over every raw coordinate, including blanking.
 reg signed [12:0] cx[0:3],cy[0:3];reg signed [10:0] ca[0:3];
 reg[3:0]neon_stage;
 reg [9:0] target_x[0:3],target_y[0:3];
 // Three fixed rotations per pipeline group. The 25 MHz pixel clock
 // allows this combinational depth, saving 318 registers and their routing.
 always @(posedge clk)begin
  cx[0]<=neon_mode?$signed({1'b0,abs_x,2'b0}):$signed({{2{abs_x[9]}},abs_x,1'b0});
  cy[0]<=neon_mode?$signed({1'b0,abs_y,2'b0}):$signed({{2{abs_y[9]}},abs_y,1'b0});ca[0]<=0;
  neon_stage[0]<=neon_mode;
  target_x[0]<=ahead;target_y[0]<=y;
 end
 wire signed [12:0] rotated_x[0:8],rotated_y[0:8];wire signed [10:0] rotated_a[0:8];
 genvar rotation;
 generate for(rotation=0;rotation<9;rotation=rotation+1)begin:fixed_rotation
  wire signed [12:0] ix,iy;wire signed [10:0] ia;
  wire rotation_neon=neon_stage[rotation/3];
  if(rotation%3==0)begin:from_register
   assign ix=cx[rotation/3];assign iy=cy[rotation/3];assign ia=ca[rotation/3];
  end else begin:from_previous
   assign ix=rotated_x[rotation-1];assign iy=rotated_y[rotation-1];assign ia=rotated_a[rotation-1];
  end
  wire signed[12:0] shift_y=iy>>>rotation,shift_x=ix>>>rotation;
  wire[12:0] addend_x=shift_y^{13{iy[12]}};
  wire[12:0] addend_y=shift_x^{13{!iy[12]}};
  wire signed[12:0] raw_x=ix+$signed(addend_x)+$signed({12'd0,iy[12]});
  wire signed[12:0] raw_y=iy+$signed(addend_y)+$signed({12'd0,!iy[12]});
  assign rotated_x[rotation]=rotation_neon?raw_x:$signed({{2{raw_x[10]}},raw_x[10:0]});
  assign rotated_y[rotation]=rotation_neon?raw_y:$signed({{2{raw_y[10]}},raw_y[10:0]});
  wire signed[10:0] delta_a=iy[12]?-atan_step(rotation):atan_step(rotation);
  assign rotated_a[rotation]=ia+delta_a;
  if(rotation%3==2)begin:group_register
   always @(posedge clk)begin
    cx[rotation/3+1]<=rotated_x[rotation];cy[rotation/3+1]<=rotated_y[rotation];ca[rotation/3+1]<=rotated_a[rotation];
    target_x[rotation/3+1]<=target_x[rotation/3];target_y[rotation/3+1]<=target_y[rotation/3];
    neon_stage[rotation/3+1]<=neon_stage[rotation/3];
   end
  end
 end endgenerate
 wire [9:0] angle=(ca[3]<0)?10'd0:((ca[3]>512)?10'd512:ca[3][9:0]);
 // The shared CORDIC retains nine rotations and four edges. Q2 inputs
 // reduce neon angle/radius rounding; visible r<=400 fits signed13.
 // Legacy DOWN arithmetic retains signed11 truncation after every rotation.
 // Mode tags travel with the coordinate through all four pipeline groups.
 wire[9:0]neon_quarter={1'b0,angle[9:1]};
 assign neon_polar_angle=(target_y[3]<240)?
  ((target_x[3]>=320)?neon_quarter:10'd512-neon_quarter):
  ((target_x[3]<320)?10'd512+neon_quarter:10'd0-neon_quarter);
 // A common >>11 scale preserves old exported radius in legacy mode:
 // reinterpret its signed11 bit pattern as unsigned, then multiply by four.
 wire[12:0]radius_operand=neon_stage[3]?cx[3]:{cx[3][10:0],2'b0};
 wire[21:0]neon_cx_extended={9'd0,radius_operand};
 wire[21:0]neon_radius_scaled=(neon_cx_extended<<8)+(neon_cx_extended<<5)+
  (neon_cx_extended<<4)+(neon_cx_extended<<2)+(neon_cx_extended<<1)+neon_cx_extended;
 assign neon_polar_radius=(|neon_radius_scaled[21:20])?9'd511:neon_radius_scaled[19:11];
 assign neon_polar_radius_q2=(|neon_radius_scaled[21:20])?11'd2047:neon_radius_scaled[19:9];
 assign neon_polar_x=target_x[3];assign neon_polar_y=target_y[3];
 wire [10:0] half_angle=(target_y[3]>=224)?11'd512-{1'b0,angle}:11'd512+{1'b0,angle};
 wire [5:0] ring_index=(half_angle>=1024)?6'd63:half_angle[9:4];
 wire [5:0] linear_index=(target_x[3]-10'd64)>>3;
 wire [5:0] display_index=neon_mode?neon_index:(style?ring_index:linear_index);
 wire [5:0] level;wire ready;
 assign neon_level=level;assign neon_ready=ready;
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
