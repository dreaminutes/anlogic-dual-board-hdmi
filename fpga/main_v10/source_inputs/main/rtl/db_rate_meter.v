`timescale 1ns/1ps
// Counts actual presented content frames in two seconds of wall-clock time.
// Each event is 0.5 FPS in this window, so BCD needs no divide hardware.
// tick90 is the existing 90kHz tick; HDMI refreshes are never count events.
module db_rate_meter #(parameter WINDOW_TICKS=180000)(
 input wire clk,rst,tick90,active,paused,asset_changed,present,
 input wire[1:0]kind,
 output wire[15:0]info
);
 localparam TIMER_BITS=WINDOW_TICKS>1?$clog2(WINDOW_TICKS):1;
 reg[TIMER_BITS-1:0]timer;
 reg[11:0]count_bcd,fps_bcd;
 reg ready;
 reg observed_active;
 reg[1:0]observed_kind;
 function[11:0]add_half;
 input[11:0]value;
 begin
  if(value==12'h995)add_half=value;
  else if(value[3:0]==0)add_half={value[11:4],4'd5};
  else if(value[7:4]!=9)add_half={value[11:8],value[7:4]+4'd1,4'd0};
  else add_half={value[11:8]+4'd1,8'd0};
 end
 endfunction
 wire[11:0]next_count=present?add_half(count_bcd):count_bcd;
 // Publish identity and reading from the same edge. A new asset must never
 // enter the CDC mailbox with the previous asset's still-valid FPS.
 assign info={observed_active,observed_kind,ready,fps_bcd};
 always@(posedge clk or posedge rst)
  if(rst)begin observed_active<=0;observed_kind<=0;end
  else begin observed_active<=active;observed_kind<=kind;end
 always@(posedge clk or posedge rst)
  if(rst)begin timer<=0;count_bcd<=0;fps_bcd<=0;ready<=0;end
  else if(!active||kind==0||paused||asset_changed)begin
   timer<=0;count_bcd<=0;fps_bcd<=0;ready<=0;
  end else if(tick90&&timer==WINDOW_TICKS-1)begin
   timer<=0;count_bcd<=0;fps_bcd<=next_count;ready<=1;
  end else begin
   if(tick90)timer<=timer+1'b1;
   count_bcd<=next_count;
  end
endmodule
