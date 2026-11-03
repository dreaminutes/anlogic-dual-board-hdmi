`timescale 1ns/1ps
// 50 MHz, open-row controller, burst length 1 / CAS3.
// All initialization/precharge/activation/refresh/write recovery intervals
// retain at least their25MHz wall time; physical CAS remains3 cycles.
// One column command per clock on a row hit; reads are pipelined.
// The SDRAM samples commands on the opposite half-cycle. CL3 drives DQ
// after the second following RAM edge; sample at the third logic edge.
// The previous CL2 configuration put this sampling edge one cycle too late.
module db_av3_sdram(input clk,ram_clk,rst,
 input req,write,input [20:0] address,input [31:0] din,
 output ready,output reg initialized,read_valid,output reg [31:0] dout);
reg [4:0] state;reg [15:0] timer;reg [9:0] refresh_timer;
reg [10:0] ra;reg [1:0] ba;reg ras,cas,we,drive;reg [31:0] data;
reg [3:0] open_bank;reg [10:0] bank_row[0:3];
reg [1:0] target_bank;reg [10:0] target_row;
reg [2:0] read_pipe;reg [2:0] write_guard;
wire [31:0] dq;
// Bijective bank hash: physical bank XORs logical row bits2:1.
// Row/column, capacity, CAS and all command protection times are unchanged.
wire[1:0]address_bank=address[9:8]^address[12:11];
// Compare the four open rows in parallel before bank selection. This removes
// the bank-row multiplexer from the address->ready combinational chain.
(* syn_keep=1 *)wire[3:0]row_match;
assign row_match[0]=open_bank[0]&&bank_row[0]==address[20:10];
assign row_match[1]=open_bank[1]&&bank_row[1]==address[20:10];
assign row_match[2]=open_bank[2]&&bank_row[2]==address[20:10];
assign row_match[3]=open_bank[3]&&bank_row[3]==address[20:10];
wire hit=(address_bank==0&&row_match[0])||(address_bank==1&&row_match[1])||
         (address_bank==2&&row_match[2])||(address_bank==3&&row_match[3]);
// Start early enough to drain reads/precharge before the 15.6 us deadline.
// Timer measures actual refresh-command intervals, not recovery completion.
wire refresh_due=refresh_timer>=680;
assign ready=state==9&&hit&&!refresh_due&&(write?(read_pipe==0):(write_guard==0));
assign dq=drive?data:32'bz;
EG_PHY_SDRAM_2M_32 ram(.clk(ram_clk),.ras_n(ras),.cas_n(cas),.we_n(we),
 .addr(ra),.ba(ba),.dq(dq),.cs_n(1'b0),
 .dm0(1'b0),.dm1(1'b0),.dm2(1'b0),.dm3(1'b0),.cke(1'b1));
always @(posedge clk)data<=din;
integer i;
always @(posedge clk or posedge rst)
if(rst)begin
 state<=0;timer<=0;refresh_timer<=0;ra<=0;ba<=0;ras<=1;cas<=1;we<=1;
 drive<=0;open_bank<=0;target_bank<=0;target_row<=0;
 initialized<=0;read_pipe<=0;write_guard<=0;read_valid<=0;dout<=0;
 for(i=0;i<4;i=i+1)bank_row[i]<=0;
end else begin
 ras<=1;cas<=1;we<=1;drive<=0;
 read_pipe<={read_pipe[1:0],req&&ready&&!write};
 read_valid<=read_pipe[2];if(read_pipe[2])dout<=dq;
 if(write_guard!=0)write_guard<=write_guard-1'b1;
 if(initialized&&refresh_timer<1023)refresh_timer<=refresh_timer+1'b1;
 case(state)
  0:if(timer==30000)begin timer<=0;state<=1;end else timer<=timer+1'b1;
  1:begin ras<=0;we<=0;ra<=11'h400;timer<=0;state<=2;end
  2:if(timer==7)begin timer<=0;state<=3;end else timer<=timer+1'b1;
  3:begin ras<=0;cas<=0;timer<=0;state<=4;end
  4:if(timer==15)begin timer<=0;state<=5;end else timer<=timer+1'b1;
  5:begin ras<=0;cas<=0;timer<=0;state<=6;end
  6:if(timer==15)begin timer<=0;state<=7;end else timer<=timer+1'b1;
  7:begin ras<=0;cas<=0;we<=0;ba<=0;ra<=11'h030;timer<=0;state<=8;end
  8:if(timer==7)begin initialized<=1;refresh_timer<=0;state<=9;end
     else timer<=timer+1'b1;
  9:begin
   if(refresh_due)state<=16;
   else if(req&&!hit)begin
    target_bank<=address_bank;target_row<=address[20:10];state<=10;
   end else if(req&&ready)begin
    cas<=0;we<=!write;ba<=address_bank;ra<={3'b000,address[7:0]};
    if(write)begin drive<=1;write_guard<=7;end
   end
  end
  10:if(read_pipe==0&&write_guard==0)begin
   if(open_bank[target_bank])begin
    ras<=0;we<=0;ra<=0;ba<=target_bank;open_bank[target_bank]<=0;
    timer<=0;state<=11;
   end else state<=12;
  end
  11:if(timer==7)state<=12;else timer<=timer+1'b1;
  12:begin ras<=0;ba<=target_bank;ra<=target_row;timer<=0;state<=13;
   bank_row[target_bank]<=target_row;open_bank[target_bank]<=1;end
  13:if(timer==5)state<=9;else timer<=timer+1'b1;
  16:if(read_pipe==0&&write_guard==0)begin
   ras<=0;we<=0;ra<=11'h400;open_bank<=0;timer<=0;state<=17;end
  17:if(timer==7)begin ras<=0;cas<=0;refresh_timer<=0;timer<=0;state<=18;end
     else timer<=timer+1'b1;
  18:if(timer==15)begin state<=9;end
     else timer<=timer+1'b1;
  default:state<=0;
 endcase
end
endmodule
