module video_rgb_to_axis_640x480(
input I_clk,I_rst,I_vs,I_de,input [23:0] I_rgb,
output reg O_video_user,O_video_valid,O_video_last,output reg [23:0] O_video_data);
reg vs_d,arm;reg [9:0] x;
always @(posedge I_clk or posedge I_rst)
if(I_rst) begin vs_d<=0;arm<=1;x<=0;O_video_user<=0;
 O_video_valid<=0;O_video_last<=0;O_video_data<=0;end
else begin
 vs_d<=I_vs;
 O_video_valid<=I_de;O_video_data<=I_rgb;
 O_video_user<=I_de && arm;O_video_last<=I_de && (x==639);
 if(vs_d!=I_vs) arm<=1;
 if(I_de) begin x<=x+1'b1;arm<=0;end else x<=0;
end
endmodule
