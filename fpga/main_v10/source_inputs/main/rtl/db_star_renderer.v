`timescale 1ns/1ps
// Procedural640x480 artwork and a single small distributed5x7 font lookup.
// One-pixel registered RGB matches the original panel DE/VS pipeline.
module db_star_renderer(input clk,rst,de,input[9:0]x,y,
 input[1:0]state,lives,input[2:0]level,input[11:0]score,
 input[9:0]player_x,star_x,rock_x,input[8:0]star_y,rock_y,input rock_visible,
 input[4:0]hit_flash,catch_flash,input[4:0]font_data,output wire[10:0]font_address,output wire[23:0]rgb);
 function[4:0]letter(input[3:0]line_id,input[5:0]index);begin
  case({line_id,index})
   10'd648:letter=5'd0;
   10'd451,10'd515,10'd579,10'd640,10'd657,10'd667:letter=5'd1;
   10'd452,10'd516,10'd658:letter=5'd2;
   10'd580,10'd668:letter=5'd3;
   10'd2,10'd6,10'd258,10'd321,10'd385,10'd456,10'd661:letter=5'd10;
   10'd5,10'd8,10'd65:letter=5'd11;
   10'd259,10'd325:letter=5'd12;
   10'd68,10'd131,10'd257,10'd324,10'd387,10'd391,10'd449,10'd513,10'd519,10'd523,10'd577,10'd583,10'd585,10'd643,10'd664,10'd671,10'd673:letter=5'd13;
   10'd644:letter=5'd14;
   10'd384,10'd652:letter=5'd15;
   10'd9,10'd653:letter=5'd16;
   10'd129,10'd651:letter=5'd17;
   10'd448,10'd512,10'd576:letter=5'd18;
   10'd128,10'd192,10'd642:letter=5'd19;
   10'd386,10'd522:letter=5'd20;
   10'd66,10'd389:letter=5'd21;
   10'd320,10'd660:letter=5'd22;
   10'd3,10'd67,10'd256,10'd392,10'd457,10'd518,10'd582,10'd650,10'd670:letter=5'd23;
   10'd0,10'd64,10'd132,10'd323,10'd454,10'd520,10'd584,10'd663,10'd672:letter=5'd24;
   10'd1,10'd7,10'd455,10'd458,10'd586,10'd645,10'd654,10'd674:letter=5'd25;
   10'd322,10'd521,10'd662:letter=5'd26;
   10'd130,10'd193,10'd390:letter=5'd27;
   10'd260,10'd450,10'd514,10'd578:letter=5'd28;
   default:letter=5'd31;
  endcase
 end endfunction
 function[15:0]star_row(input[3:0]v);begin
  case(v)
   0,1:star_row=16'h0180;2,3:star_row=16'h03c0;4:star_row=16'h07e0;
   5:star_row=16'hffff;6:star_row=16'h7ffe;7:star_row=16'h3ffc;
   8:star_row=16'h1ff8;9,10:star_row=16'h0ff0;11:star_row=16'h1ff8;
   12:star_row=16'h1e78;13:star_row=16'h3c3c;14:star_row=16'h381c;15:star_row=16'h300c;
  endcase
 end endfunction
 wire[9:0]pd=x-player_x,rx=x-rock_x,ry=y-{1'b0,rock_y};
 wire player_near=(pd[9:5]==0)||(pd[9:5]==31);
 wire rock_near=((rx[9:4]==0)||(rx[9:4]==63))&&((ry[9:4]==0)||(ry[9:4]==63));
 wire[5:0]pdx=pd[9]?(~pd[5:0]+6'd1):pd[5:0];
 wire[4:0]rdx=rx[9]?(~rx[4:0]+5'd1):rx[4:0],rdy=ry[9]?(~ry[4:0]+5'd1):ry[4:0];
 wire[9:0]sx=x-star_x+10'd8,sy=y-{1'b0,star_y}+10'd8;
 wire[15:0]star_bits=star_row(sy[3:0]);
 wire star_ink=sx<16&&sy<16&&star_bits[15-sx[3:0]];
 wire[6:0]bg_blue=7'd30+{3'd0,y[8:5]};
 reg[23:0]color;
 reg[9:0]heart_origin;reg heart_area,heart_live;wire[9:0]hx=x-heart_origin,hy=y-10'd44;
 wire[63:0]heart_bits=64'h66ffffff7e3c1800;
 wire heart_ink=heart_bits[63-{hy[3:1],hx[3:1]}];
 always@*begin
  heart_area=0;heart_origin=432;heart_live=lives>0;
  if(y>=44&&y<60)begin
   if(x>=432&&x<448)begin heart_area=1;heart_origin=432;heart_live=lives>0;end
   else if(x>=456&&x<472)begin heart_area=1;heart_origin=456;heart_live=lives>1;end
   else if(x>=480&&x<496)begin heart_area=1;heart_origin=480;heart_live=lives>2;end
  end
  color={8'h0b,8'h14,1'b0,bg_blue};
  if(x[5:0]==9&&y[5:0]==19&&y>=96&&y<408)color=24'h344b69;
  if(x>=24&&x<616&&y>=96&&y<454)begin
   if(x<26||x>=614||y==96||y>=452)color=24'h233b5d;
   if(y==414&&x[4:0]<8&&x>40&&x<600)color=24'h1b314c;
  end
  if(player_near&&y>=448&&y<451&&pdx<32)color=24'h172e48;
  if(star_ink)color=(sx>=6&&sx<=9&&sy>=5&&sy<=9)?24'hfff3bd:24'hffd166;
  if(rock_visible&&rock_near&&rdx<=11&&rdy<=11&&rdx+rdy<=18)begin
   color=(rdx>=9||rdy>=9||rdx+rdy>=16)?24'hff94a9:24'hbd425e;
   if(rdx==rdy&&rdx<6)color=24'hffe1e7;
  end
  if(player_near&&y>=424&&y<441&&pdx<24&&!(pdx>=20&&(y<428||y>=437)))begin
   color=(hit_flash!=0&&hit_flash[1])?24'hff8ba6:(catch_flash!=0?24'hc5fff0:24'h65dce8);
   if(y<427)color=24'hd7fcff;
   if(y>=429&&y<=432&&pdx>=6&&pdx<=9)color=24'h12283d;
  end
  if(player_near&&y>=417&&y<425&&pdx<14)color=24'h58a8ce;
  if(player_near&&y>=420&&y<424&&pdx<10)color=24'hb1f4ff;
  if(player_near&&y>=441&&y<446&&pdx<4)color=24'h6ae6ff;
  if(x>=24&&x<616&&y>=18&&y<80&&!((x<32||x>=608)&&(y<26||y>=72)))color=24'h12223b;
  if(y==79&&x>=40&&x<600)color=24'h24435f;
  if(heart_area&&heart_ink)color=heart_live?24'hfb839d:24'h30405b;
  if(state!=1&&x>=156&&x<484&&y>=176&&y<312)begin
   color=24'h13243c;
   if((x<158||x>=482||y<178||y>=310)&&x>=160&&x<480)
    color=state==3?24'hfb839d:24'h6bdce8;
  end
 end
 reg text_on,small_font;reg[9:0]ox,oy;reg[3:0]line_id;reg[1:0]digits;reg[23:0]text_color;
 always@*begin
  text_on=0;small_font=0;ox=0;oy=0;line_id=0;digits=0;text_color=24'hedf5ff;
  if(x>=40&&x<200&&y>=36&&y<50)begin text_on=1;ox=40;oy=36;line_id=0;text_color=24'h9eeaf2;end
  else if(x>=304&&x<344&&y>=26&&y<33)begin text_on=1;small_font=1;ox=304;oy=26;line_id=1;text_color=24'h8da7bf;end
  else if(x>=304&&x<368&&y>=44&&y<58)begin text_on=1;ox=304;oy=44;digits=1;end
  else if(x>=432&&x<472&&y>=26&&y<33)begin text_on=1;small_font=1;ox=432;oy=26;line_id=2;text_color=24'h8da7bf;end
  else if(x>=552&&x<568&&y>=26&&y<33)begin text_on=1;small_font=1;ox=552;oy=26;line_id=3;text_color=24'h8da7bf;end
  else if(x>=552&&x<568&&y>=44&&y<58)begin text_on=1;ox=552;oy=44;digits=2;text_color=24'hffd166;end
  else if(y>=464&&y<471&&x>=180&&x<460)begin text_on=1;small_font=1;ox=180;oy=464;line_id=10;text_color=24'h8da7bf;end
  if(state!=1)begin
   if(y>=208&&y<222)begin
    if(state==0&&x>=280&&x<360)begin text_on=1;ox=280;oy=208;line_id=4;end
    else if(state==2&&x>=272&&x<368)begin text_on=1;ox=272;oy=208;line_id=5;end
    else if(state==3&&x>=248&&x<392)begin text_on=1;ox=248;oy=208;line_id=6;text_color=24'hfb839d;end
   end
   else if(y>=256&&y<270)begin
    if(state==2&&x>=224&&x<416)begin text_on=1;ox=224;oy=256;line_id=8;text_color=24'h9eeaf2;end
    else if(state!=2&&x>=232&&x<408)begin text_on=1;ox=232;oy=256;line_id=state==3?9:7;text_color=24'h9eeaf2;end
   end
  end
 end
 wire[9:0]tx=x-ox,ty=y-oy;
 wire[5:0]index=small_font?tx[8:3]:{1'b0,tx[8:4]};
 wire[2:0]column=small_font?tx[2:0]:tx[3:1],line=small_font?ty[2:0]:ty[3:1];
 reg[4:0]character;
 always@*begin
  character=letter(line_id,index);
  if(digits==1)case(index[1:0])
   0:character={1'b0,score[11:8]};1:character={1'b0,score[7:4]};2:character={1'b0,score[3:0]};3:character=5'd0;
  endcase
  else if(digits==2)character=5'd1+level;
 end
 //1408+8*glyph+row, expressed without an adder. The32 glyph slots
 // exactly occupy previously blank words1408..1663 of the original ROM.
 assign font_address={1'b1,character[4],{2{!character[4]}},character[3:0],line};
 reg[23:0]base_q,text_q;reg text_valid_q;reg[2:0]column_q;
 always@(posedge clk or posedge rst)
 if(rst)begin base_q<=0;text_q<=0;text_valid_q<=0;column_q<=0;end
 else begin base_q<=de?color:24'd0;text_q<=text_color;text_valid_q<=de&&text_on&&column<5&&line<7;column_q<=column;end
 assign rgb=text_valid_q&&font_data[4-column_q]?text_q:base_q;
endmodule
