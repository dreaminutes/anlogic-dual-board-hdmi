// One-shot registered power-on reset. SW0 is a standby control, not reset.
module media_power_reset(input clk,output rst);
reg [21:0] count=0;
(* syn_preserve=1, syn_keep=1 *) reg active=1'b1;
always @(posedge clk)begin
 if(active)begin
  if(count==22'd2499999)active<=1'b0;
  else count<=count+1'b1;
 end
end
assign rst=active;
endmodule
