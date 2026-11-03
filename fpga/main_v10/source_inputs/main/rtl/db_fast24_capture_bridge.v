`timescale 1ns/1ps
// Dedicated250MHz10MHz-cable sampler, held candidate byte to unchanged64B asyncFIFO.
module db_fast24_capture_bridge(
 input wire capture_clk,clk50,rst,forward_clk,link_valid,input wire[7:0]link_data,
 output wire byte_valid,output wire[7:0]byte_data,output wire failed
);
 (* async_reg="true" *)reg[2:0]sample_reset;
 always @(posedge capture_clk or posedge rst)
  if(rst)sample_reset<=7;else sample_reset<={sample_reset[1:0],1'b0};
 wire pulse,valid;wire[7:0]data;wire full,empty,overrun;
 db_link25_input_filter sampler(.clk(capture_clk),.rst(sample_reset[2]),.forward_clk(forward_clk),
  .link_valid(link_valid),.link_data(link_data),.sample_pulse(pulse),.sample_valid(valid),.sample_data(data));
 db_cable10_capture_byte_fifo queue(.rst(rst),.wr_clk(capture_clk),.rd_clk(clk50),.wr_en(valid),.wr_data(data),
  .rd_en(!empty),.rd_data(byte_data),.full(full),.empty(empty),.overflow(overrun));
 (* async_reg="true" *)reg[2:0]fail_sync;
 always @(posedge clk50 or posedge rst)
  if(rst)fail_sync<=0;else fail_sync<={fail_sync[1:0],overrun};
 assign failed=fail_sync[2];
 assign byte_valid=!empty&&!failed&&!rst;
endmodule
