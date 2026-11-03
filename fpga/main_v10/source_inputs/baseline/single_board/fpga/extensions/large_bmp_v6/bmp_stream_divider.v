// Bounded restoring divider: all scaler numerators fit 28 bits and
// denominators are 1..4096. Keep the original handshake, without a wide ALU.
module bmp_stream_divider(input clk,rst,start,input [31:0] numerator,denominator,
 output reg busy,done,output [31:0] quotient);
 reg [27:0] dividend,q;
 reg [12:0] divisor;
 reg [13:0] remainder;
 reg [4:0] bit_count;
 wire [13:0] trial={remainder[12:0],dividend[27]};
 // Borrow from the widened subtract is the unsigned comparison result.
 wire [14:0] difference={1'b0,trial}-{2'b0,divisor};
 assign quotient={4'd0,q};
 always @(posedge clk)begin
  if(rst)begin busy<=0;done<=0;dividend<=0;q<=0;divisor<=1;remainder<=0;bit_count<=0;end
  else begin
   done<=0;
   if(start&&!busy)begin dividend<=numerator[27:0];divisor<=denominator[12:0];
    remainder<=0;q<=0;bit_count<=0;busy<=1;end
   else if(busy)begin
    dividend<={dividend[26:0],1'b0};
    if(!difference[14])begin remainder<=difference[13:0];q<={q[26:0],1'b1};end
    else begin remainder<=trial;q<={q[26:0],1'b0};end
    if(bit_count==27)begin busy<=0;done<=1;end else bit_count<=bit_count+1'b1;
   end
  end
 end
endmodule
