`timescale 1ns/1ps
// Full 640x480 RGB565 off-screen composition, one finished frame per job.
// Four independent source scanlines: original + two radial taps + incoming.
// The SDRAM burst reads/writes run on the existing lower-priority engine port.
// Scratch addresses are selected from dead canvases or unused SDRAM tail after loading.
module photo_frame_compositor(
 input clk,rst,start,input [2:0] mode,input [6:0] progress,
 input [20:0] old_base,new_base,target_base,
 input [6:0] phase_delta,input history_enable,history_valid,
 input [20:0] history_base,history_target,
 input old_native,old_portrait,new_native,new_portrait,
 output busy,output reg done,
 output mem_req,mem_write,output [20:0] mem_addr,output [31:0] mem_wdata,
 input mem_ready,mem_rvalid,input [31:0] mem_rdata);
 localparam IDLE=0,SETUP=1,MAPROW=2,ADDR=3,FETCH=4,DRAIN=5,
  PREP=6,PIXELS=7,FLUSH=8,WARM=9,WRITE=10,HWARM=11,HWRITE=12;
 reg [3:0] state;reg [2:0] kind;reg [1:0] channel;reg history_on;reg [20:0] history_out;reg [6:0] amount;
 reg [20:0] ob,nb,tb,row_address,out_address;
 reg onat,opor,nnat,npor;
 reg [8:0] y,issued,returned,stride;reg [9:0] x;
 reg [8:0] step0,step1,step2,load_step,source_y;
 reg [17:0] xf0,xf1,xf2;
 // Anlogic's documented DSP directive moves these multiplies away from the
 // nearly full slice fabric. Values and pipeline latency are unchanged.
 // Rows are fetched sequentially, so one coordinate multiplier serves all
 // three old-image taps. Values are stable throughout MAPROW; no extra
 // memory cycle or pixel-stage latency is introduced.
 wire [8:0] row_step=channel==0?step0:(channel==1?step1:step2);
 (*dsp_style="yes"*) wire [17:0] row_product=y*row_step;
 wire [17:0] row_position=(9'd256-row_step)*18'd240+row_product;
 (*dsp_style="yes"*) wire [17:0] row_offset=source_y*stride;
 reg [8:0] virtual_y;reg load_native,load_portrait;
 wire [9:0] portrait_y_numerator={virtual_y,1'b0};
 wire [8:0] portrait_source_y=portrait_y_numerator/10'd3;
 reg [31:0] line0[0:319] /* fehdl force_ram=1, ram_style="bram" */;
 reg [31:0] line1[0:319] /* fehdl force_ram=1, ram_style="bram" */;
 reg [31:0] line2[0:319] /* fehdl force_ram=1, ram_style="bram" */;
 reg [31:0] line3[0:319] /* fehdl force_ram=1, ram_style="bram" */;
 reg [63:0] result_line[0:319] /* fehdl force_ram=1, ram_style="bram" */;
 reg [31:0] q0,q1,q2,q3;reg [63:0] result_q;
 reg [15:0] low_pixel,history_low,history_c,left_pixel;
 reg [9:0] ax0,ax1,ax2,ax3;
 reg blank0,blank1,blank2,blank3;
 wire [9:0] vx0=xf0[17:8],vx1=xf1[17:8],vx2=xf2[17:8];
 // Constant division is bounded to <=638 here (not a general divider).
 function [9:0] map_x;input [9:0] vx;input nat,por;reg [9:0] doubled;begin
  doubled=(vx-10'd185)<<1;
  if(nat)map_x=vx;
  else if(por)map_x=doubled/10'd3;
  else map_x=vx>>1;
 end endfunction
 function blank_x;input [9:0] vx;input nat,por;begin
  blank_x=!nat&&por&&(vx<185||vx>=455);
 end endfunction
 wire [9:0] sx0=map_x(vx0,onat,opor),sx1=map_x(vx1,onat,opor),sx2=map_x(vx2,onat,opor);
 wire [9:0] sx3=map_x(x,nnat,npor);
 wire [15:0] p0=blank0?16'd0:(ax0[0]?q0[31:16]:q0[15:0]);
 wire [15:0] p1=blank1?16'd0:(ax1[0]?q1[31:16]:q1[15:0]);
 wire [15:0] p2=blank2?16'd0:(ax2[0]?q2[31:16]:q2[15:0]);
 wire [15:0] pn=blank3?16'd0:(ax3[0]?q3[31:16]:q3[15:0]);
 reg valid_a,valid_b,valid_c;reg [9:0] x_a,x_b,x_c;
 reg signed [11:0] distance_a;reg [5:0] alpha_a,alpha_b;reg [4:0] glow_a,glow_b;
 reg [15:0] old_b,new_b;reg [15:0] mixed_c;reg [4:0] glow_c;
 wire [7:0] rr={1'b0,p0[15:11],1'b0}+{3'd0,p1[15:11]}+{3'd0,p2[15:11]};
 wire [8:0] gg={1'b0,p0[10:5],1'b0}+{3'd0,p1[10:5]}+{3'd0,p2[10:5]};
 wire [7:0] bb={1'b0,p0[4:0],1'b0}+{3'd0,p1[4:0]}+{3'd0,p2[4:0]};
 // Dark pixels retain the source silhouette; no semantic subject mask exists
 // in ordinary BMP/GIF. Other pixels receive actual radial image samples.
 function is_dark;input [15:0] c;begin is_dark=c[15:11]<3&&c[10:5]<6&&c[4:0]<3;end endfunction
wire dark=is_dark(p0);
wire contour=(dark!=is_dark(p1))||(dark!=is_dark(p2))||((x_a!=0)&&(dark!=is_dark(left_pixel)));
 wire [15:0] radial_pixel=dark?p0:{rr[6:2],gg[7:2],bb[6:2]};
 // Keep both operands below the sign bit of a physical 9x9 DSP lane.
 // TD can pack a signed color delta with an unsigned coordinate multiply
 // and select unsigned mode for both lanes. In V16 this added 512*alpha
 // to a negative red delta, flipping red bit 4 whenever alpha was odd.
 // Bias by 32/64 before multiplying, then subtract bias*alpha afterwards:
 // old*32 + (new-old+bias)*alpha - bias*alpha == old*(32-alpha)+new*alpha.
 // This retains V11's exact rounding, pixel stages and memory schedule.
 wire [5:0] dr={1'b0,new_b[15:11]}+6'd32-{1'b0,old_b[15:11]};
 wire [6:0] dg={1'b0,new_b[10:5]}+7'd64-{1'b0,old_b[10:5]};
 wire [5:0] db={1'b0,new_b[4:0]}+6'd32-{1'b0,old_b[4:0]};
 (*dsp_style="yes"*) wire [11:0] pr=dr*alpha_b;
 (*dsp_style="yes"*) wire [12:0] pg=dg*alpha_b;
 (*dsp_style="yes"*) wire [11:0] pb=db*alpha_b;
 wire [12:0] red_sum={3'd0,old_b[15:11],5'b0}+{1'b0,pr}-{2'd0,alpha_b,5'b0}+13'd16;
 wire [12:0] green_sum={2'd0,old_b[10:5],5'b0}+pg-{1'b0,alpha_b,6'b0}+13'd16;
 wire [12:0] blue_sum={3'd0,old_b[4:0],5'b0}+{1'b0,pb}-{2'd0,alpha_b,5'b0}+13'd16;
 function [15:0] glow565;input [15:0] c;input [4:0] g;
 reg [6:0] r,gr,b;begin
  r={2'd0,c[15:11]}+(kind==5?g:(g>>1));gr={1'b0,c[10:5]}+g;
  b={2'd0,c[4:0]}+(kind==5?(g>>2):g);
  if(kind==5&&g>=29)glow565=16'hfffc;
  else glow565={(r>31?5'd31:r[4:0]),(gr>63?6'd63:gr[5:0]),(b>31?5'd31:b[4:0])};
 end endfunction
 // The band begins outside the left edge and leaves past the right edge.
 // Passed regions contain the incoming picture, untouched regions the old.
 wire signed [11:0] band_center=$signed({1'b0,amount,4'b0})-12'sd80;
 wire signed [11:0] band_distance=band_center-$signed({2'd0,x})-$signed({3'd0,y[8:1]});
 wire signed [11:0] flow_distance=distance_a-(kind==2&&dark?12'sd24:12'sd0);
 wire [11:0] flow_abs=flow_distance[11]?-flow_distance:flow_distance;
 wire [4:0] flow_glow=flow_abs>=64?0:((12'd64-flow_abs)>>2);
 wire [9:0] dx=x>=320?x-10'd320:10'd320-x;
 wire [9:0] dy=y>=240?y-9'd240:9'd240-y;
 wire [10:0] dy_screen={1'b0,dy}+({1'b0,dy}>>2)+({1'b0,dy}>>4);
 wire [10:0] radius=({1'b0,dx}>dy_screen)?({1'b0,dx}+(dy_screen>>1)):(dy_screen+({1'b0,dx}>>1));
 wire signed [12:0] aperture=$signed({1'b0,amount,4'b0})-13'sd320-$signed({2'd0,radius});
 wire [5:0] push_alpha=(amount<=12)?0:((aperture<=-64)?0:((aperture>=64)?32:((aperture+64)>>>2)));
 wire [5:0] fade_alpha=(amount>=64)?6'd32:{1'b0,amount[6:1]};
 // Fixed spatial value noise: two small distributed LUTs, no extra BRAM,
 // frame buffer, or time-varying random state. The burn front cannot flicker.
 function [3:0] burn_noise;input [3:0] index;begin
  case(index)
   0:burn_noise=3;1:burn_noise=12;2:burn_noise=6;3:burn_noise=15;
   4:burn_noise=8;5:burn_noise=1;6:burn_noise=10;7:burn_noise=5;
   8:burn_noise=14;9:burn_noise=7;10:burn_noise=0;11:burn_noise=11;
   12:burn_noise=4;13:burn_noise=13;14:burn_noise=9;15:burn_noise=2;
  endcase
 end endfunction
 wire [8:0] burn_edge_x=x<320?x[8:0]:(10'd639-x);
 wire [8:0] burn_edge_y=y<240?y:(9'd479-y);
 wire [8:0] burn_edge_x_scaled=burn_edge_x-(burn_edge_x>>2);
 wire [8:0] burn_edge=burn_edge_x_scaled<burn_edge_y?burn_edge_x_scaled:burn_edge_y;
 wire [3:0] burn_index0=x[6:3]^y[6:3];
 wire [3:0] burn_index1=x[8:5]^{y[6:5],y[8:7]}^{2'd0,x[9],y[4]};
 wire [4:0] burn_texture={1'b0,burn_noise(burn_index0)}+{1'b0,burn_noise(burn_index1)};
 wire signed [11:0] burn_distance=$signed({3'd0,amount,2'b0})+$signed({5'd0,amount})-12'sd12
   -$signed({3'd0,burn_edge})-$signed({7'd0,burn_texture});
 // The already available three scanline samples soften the desaturated band.
 wire [6:0] carbon_luma_sum={2'd0,rr[6:2]}+{1'b0,gg[7:2]}+{2'd0,bb[6:2]};
 wire [4:0] carbon_luma=carbon_luma_sum[6:2];
 wire [15:0] carbon_gray={carbon_luma,carbon_luma,1'b0,carbon_luma};
 wire carbon_grain=x_a[0]^x_a[3]^y[0]^y[2];
 wire [15:0] carbon_ash={{3'd0,1'b1,carbon_grain},{5'd0,(x_a[1]^y[1])},5'd0};
 wire [5:0] carbon_alpha=distance_a<=0?6'd0:(distance_a>=32?6'd32:{1'b0,distance_a[3:0],1'b0});
 // Reference-style flowing light: a curved platinum/gold front combines
 // with a growing light loop; the outgoing picture gently ripples by row.
 // The existing octagonal radius and RGB mixer are shared with other modes.
 function signed [5:0] ribbon_sine;input [4:0] index;begin
  case(index)
   0:ribbon_sine=0;1:ribbon_sine=5;2:ribbon_sine=9;3:ribbon_sine=13;
   4:ribbon_sine=17;5:ribbon_sine=20;6:ribbon_sine=22;7:ribbon_sine=24;
   8:ribbon_sine=24;9:ribbon_sine=24;10:ribbon_sine=22;11:ribbon_sine=20;
   12:ribbon_sine=17;13:ribbon_sine=13;14:ribbon_sine=9;15:ribbon_sine=5;
   16:ribbon_sine=0;17:ribbon_sine=-5;18:ribbon_sine=-9;19:ribbon_sine=-13;
   20:ribbon_sine=-17;21:ribbon_sine=-20;22:ribbon_sine=-22;23:ribbon_sine=-24;
   24:ribbon_sine=-24;25:ribbon_sine=-24;26:ribbon_sine=-22;27:ribbon_sine=-20;
   28:ribbon_sine=-17;29:ribbon_sine=-13;30:ribbon_sine=-9;31:ribbon_sine=-5;
  endcase
 end endfunction
 wire [4:0] ribbon_index=y[8:4]+amount[5:1];
 wire signed [5:0] ribbon_base=ribbon_sine(ribbon_index);
 wire signed [5:0] ribbon_next=ribbon_sine(ribbon_index+5'd1);
 wire signed [6:0] ribbon_delta=$signed({ribbon_next[5],ribbon_next})-$signed({ribbon_base[5],ribbon_base});
 (*dsp_style="yes"*) wire signed [11:0] ribbon_fraction=ribbon_delta*$signed({1'b0,y[3:0]});
 wire signed [11:0] ribbon_interpolated=$signed({{2{ribbon_base[5]}},ribbon_base,4'b0})+ribbon_fraction;
 wire signed [5:0] ribbon_wave=ribbon_interpolated[9:4];
 wire [6:0] ribbon_strength=amount<32?amount:7'd64-amount;
 (*dsp_style="yes"*) wire signed [13:0] ribbon_product=ribbon_wave*$signed({1'b0,ribbon_strength});
 reg signed [8:0] row_warp;
 wire [8:0] ribbon_step=9'd256-{2'd0,ribbon_strength};
 wire signed [11:0] ribbon_front=$signed({1'b0,amount,4'b0})-12'sd192-$signed({2'd0,x})
  +$signed({{4{ribbon_wave[5]}},ribbon_wave,2'b0});
 wire signed [11:0] ribbon_loop=$signed({2'd0,amount,3'b0})+$signed({3'd0,amount,2'b0})-12'sd192-$signed({1'b0,radius});
 wire signed [11:0] ribbon_distance=ribbon_front>ribbon_loop?ribbon_front:ribbon_loop;
 // Narrow light: 31-pixel halo and 3-pixel white core at full strength.
 // The old sweep (mode 2), radial and push paths retain V11 behavior.
 wire [4:0] ribbon_raw=flow_abs>=16?5'd0:(5'd31-{flow_abs[3:0],1'b0});
 wire [4:0] ribbon_cap=ribbon_strength>=8?5'd31:{ribbon_strength[2:0],2'b0};
 wire [4:0] ribbon_glow=ribbon_raw<ribbon_cap?ribbon_raw:ribbon_cap;
 wire [17:0] old_x_origin=(9'd256-step0)*18'd320;
 wire [17:0] ripple_x_origin=old_x_origin+{row_warp[8],row_warp,8'd0};
 reg [6:0] ease[0:64];
initial begin
 ease[0]=7'd0;
 ease[1]=7'd0;
 ease[2]=7'd0;
 ease[3]=7'd0;
 ease[4]=7'd1;
 ease[5]=7'd1;
 ease[6]=7'd2;
 ease[7]=7'd2;
 ease[8]=7'd3;
 ease[9]=7'd3;
 ease[10]=7'd4;
 ease[11]=7'd5;
 ease[12]=7'd6;
 ease[13]=7'd7;
 ease[14]=7'd8;
 ease[15]=7'd9;
 ease[16]=7'd10;
 ease[17]=7'd11;
 ease[18]=7'd12;
 ease[19]=7'd14;
 ease[20]=7'd15;
 ease[21]=7'd16;
 ease[22]=7'd17;
 ease[23]=7'd19;
 ease[24]=7'd20;
 ease[25]=7'd22;
 ease[26]=7'd23;
 ease[27]=7'd25;
 ease[28]=7'd26;
 ease[29]=7'd28;
 ease[30]=7'd29;
 ease[31]=7'd31;
 ease[32]=7'd32;
 ease[33]=7'd33;
 ease[34]=7'd35;
 ease[35]=7'd36;
 ease[36]=7'd38;
 ease[37]=7'd39;
 ease[38]=7'd41;
 ease[39]=7'd42;
 ease[40]=7'd44;
 ease[41]=7'd45;
 ease[42]=7'd47;
 ease[43]=7'd48;
 ease[44]=7'd49;
 ease[45]=7'd50;
 ease[46]=7'd52;
 ease[47]=7'd53;
 ease[48]=7'd54;
 ease[49]=7'd55;
 ease[50]=7'd56;
 ease[51]=7'd57;
 ease[52]=7'd58;
 ease[53]=7'd59;
 ease[54]=7'd60;
 ease[55]=7'd61;
 ease[56]=7'd61;
 ease[57]=7'd62;
 ease[58]=7'd62;
 ease[59]=7'd63;
 ease[60]=7'd63;
 ease[61]=7'd64;
 ease[62]=7'd64;
 ease[63]=7'd64;
 ease[64]=7'd64;
end
wire [8:0] camera_step=9'd256-({2'd0,ease[progress]}<<1)-{2'd0,ease[progress]};
wire accept=mem_req&&mem_ready;
 assign busy=state!=IDLE;
 assign mem_req=(state==FETCH&&issued<stride)||(state==WRITE&&issued<320)||(state==HWRITE&&issued<320);
 assign mem_write=state==WRITE||state==HWRITE;
 assign mem_addr=mem_write?((state==HWRITE?history_out:out_address)+issued):row_address+issued;
 assign mem_wdata=state==HWRITE?result_q[63:32]:result_q[31:0];
 // BRAM write/read are outside the control reset path.
 always @(posedge clk)begin
  if(mem_rvalid&&state>=FETCH&&state<=DRAIN)case(channel)
   0:line0[returned]<=mem_rdata;1:line1[returned]<=mem_rdata;
   2:line2[returned]<=mem_rdata;3:line3[returned]<=mem_rdata;
  endcase
  q0<=line0[blank_x(vx0,onat,opor)?9'd0:sx0[9:1]];
  q1<=line1[blank_x(vx1,onat,opor)?9'd0:sx1[9:1]];
  q2<=line2[blank_x(vx2,onat,opor)?9'd0:sx2[9:1]];
  q3<=line3[blank_x(x,nnat,npor)?9'd0:sx3[9:1]];
  if(valid_c&&x_c[0])result_line[x_c[9:1]]<={history_c,history_low,glow565(mixed_c,glow_c),low_pixel};
  result_q<=result_line[((state==WRITE||state==HWRITE)&&accept&&issued<319)?issued+1'b1:issued];
 end
 always @(posedge clk or posedge rst)
 if(rst)begin
  state<=IDLE;done<=0;history_on<=0;history_out<=0;history_low<=0;history_c<=0;left_pixel<=0;kind<=0;amount<=0;ob<=0;nb<=0;tb<=0;onat<=0;opor<=0;nnat<=0;npor<=0;
  y<=0;x<=0;channel<=0;issued<=0;returned<=0;stride<=0;row_address<=0;out_address<=0;
  step0<=256;step1<=256;step2<=256;load_step<=256;source_y<=0;virtual_y<=0;load_native<=0;load_portrait<=0;
  xf0<=0;xf1<=0;xf2<=0;row_warp<=0;
  valid_a<=0;valid_b<=0;valid_c<=0;x_a<=0;x_b<=0;x_c<=0;
  ax0<=0;ax1<=0;ax2<=0;ax3<=0;blank0<=0;blank1<=0;blank2<=0;blank3<=0;
  distance_a<=0;alpha_a<=0;alpha_b<=0;glow_a<=0;glow_b<=0;glow_c<=0;old_b<=0;new_b<=0;mixed_c<=0;low_pixel<=0;
 end else begin
  done<=0;valid_a<=state==PIXELS;valid_b<=valid_a;valid_c<=valid_b;
  ax0<=sx0;ax1<=sx1;ax2<=sx2;ax3<=sx3;
  blank0<=blank_x(vx0,onat,opor);blank1<=blank_x(vx1,onat,opor);
  blank2<=blank_x(vx2,onat,opor);blank3<=blank_x(x,nnat,npor);
  distance_a<=kind==4?burn_distance:(kind==5?ribbon_distance:band_distance);x_a<=x;alpha_a<=kind==3?push_alpha:fade_alpha;
  x_b<=x_a;
  old_b<=kind==4?(distance_a>=16?carbon_gray:p0):(amount==64?16'd0:(kind==1?radial_pixel:p0));
  new_b<=kind==4?(distance_a>=16?carbon_ash:carbon_gray):pn;
  alpha_b<=kind==4?carbon_alpha:(amount==64?6'd32:alpha_a);
  // Current sample and its three neighbours are aligned with x_a, one clock
  // after the line read; compute the contour-sensitive band in this stage.
  if(kind==2)begin
   if(amount==0)begin alpha_b<=0;glow_b<=0;end
   else if(amount==64)begin alpha_b<=32;glow_b<=0;end
   else begin
    if(flow_distance<=-64)alpha_b<=0;
    else if(flow_distance>=64)alpha_b<=32;
    else alpha_b<=(flow_distance+12'sd64)>>>2;
    if(contour)glow_b<=flow_glow>8?5'd31:(flow_glow<<1);
    else glow_b<=flow_glow;
   end
  end else if(kind==5)begin
   if(amount==0)begin alpha_b<=0;glow_b<=0;end
   else if(amount==64)begin alpha_b<=32;glow_b<=0;end
   else begin
    if(distance_a<=-16)alpha_b<=0;
    else if(distance_a>=16)alpha_b<=32;
    else alpha_b<=distance_a+12'sd16;
    glow_b<=ribbon_glow;
   end
  end else glow_b<=0;
  if(valid_a)left_pixel<=p0;
  history_c<=old_b;x_c<=x_b;mixed_c<={red_sum[9:5],green_sum[10:5],blue_sum[9:5]};glow_c<=glow_b;
  if(valid_c&&!x_c[0])begin low_pixel<=glow565(mixed_c,glow_c);history_low<=history_c;end
  case(state)
   IDLE:if(start)begin
    kind<=mode;amount<=progress;ob<=history_enable&&history_valid?history_base:old_base;nb<=new_base;tb<=target_base;
    history_on<=history_enable&&mode==1&&progress<64;history_out<=history_target;
    onat<=history_enable&&history_valid?1'b1:old_native;opor<=history_enable&&history_valid?1'b0:old_portrait;nnat<=new_native;npor<=new_portrait;
    // Push crops towards the center. Radial uses three different actual
    // image positions on each ray; it is not a generated ray overlay.
    step0<=mode==3?camera_step:(mode==5?(9'd256-(progress<32?{2'd0,progress}:9'd64-{2'd0,progress})):9'd256);
    // Feedback integrates many small radial samples over successive jobs,
    // turning isolated zoom ghosts into a longer, continuous image trail.
    step1<=history_enable?9'd256-({2'd0,phase_delta}<<1):9'd256-({2'd0,progress}<<1);
    step2<=history_enable?9'd256-({2'd0,phase_delta}<<2):9'd256-({2'd0,progress}<<1)-{2'd0,progress};
    if(mode==2||mode==4)begin step1<=256;step2<=256;end
    y<=0;out_address<=target_base;state<=SETUP;
   end
   SETUP:begin
    row_warp<=ribbon_product>>>5;
    channel<=amount==64&&kind!=4?2'd3:2'd0;state<=MAPROW;
   end
   MAPROW:begin
    if(channel==3)virtual_y<=y;else virtual_y<=row_position[16:8];
    if(kind==2||kind==4)begin
     if(channel==1)virtual_y<=y==0?9'd0:y-1'b1;
     else if(channel==2)virtual_y<=y==479?9'd479:y+1'b1;
    end
    load_native<=channel==3?nnat:onat;load_portrait<=channel==3?npor:opor;state<=ADDR;
   end
   ADDR:begin
    source_y<=load_native?virtual_y:(load_portrait?portrait_source_y:virtual_y>>1);
    stride<=load_native?320:(load_portrait?90:160);state<=PREP;
   end
   PREP:begin
    row_address<=(channel==3?nb:ob)+row_offset;issued<=0;returned<=0;state<=FETCH;
   end
   FETCH:begin
    if(accept)begin issued<=issued+1'b1;if(issued==stride-1)state<=DRAIN;end
    if(mem_rvalid)returned<=returned+1'b1;
   end
   DRAIN:if(mem_rvalid)begin
    returned<=returned+1'b1;
    if(returned==stride-1)begin
     if(channel==3||(kind==4&&channel==2))begin
      x<=0;xf0<=kind==5?ripple_x_origin:old_x_origin;xf1<=(9'd256-step1)*18'd320;xf2<=(9'd256-step2)*18'd320;
      state<=PIXELS;
     end else begin channel<=kind==1||kind==2||kind==4?channel+1'b1:2'd3;state<=MAPROW;end
    end
   end
   PIXELS:begin
    xf0<=xf0+step0;xf1<=xf1+step1;xf2<=xf2+step2;
    if(x==639)begin x<=0;state<=FLUSH;end else x<=x+1'b1;
   end
   FLUSH:if(!valid_a&&!valid_b&&!valid_c)begin issued<=0;state<=WARM;end
   WARM:state<=WRITE;
   WRITE:if(accept)begin
    issued<=issued+1'b1;
    if(issued==319)begin
     if(history_on)begin issued<=0;state<=HWARM;end
     else if(y==479)begin state<=IDLE;done<=1;end
     else begin y<=y+1'b1;out_address<=out_address+21'd320;history_out<=history_out+21'd320;state<=SETUP;end
    end
   end
   HWARM:state<=HWRITE;
   HWRITE:if(accept)begin
    issued<=issued+1'b1;
    if(issued==319)begin
     if(y==479)begin state<=IDLE;done<=1;end
     else begin y<=y+1'b1;out_address<=out_address+21'd320;history_out<=history_out+21'd320;state<=SETUP;end
    end
   end
   default:state<=IDLE;
  endcase
 end
endmodule
