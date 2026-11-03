`timescale 1ns/1ps
// One tagged stereo-word-sized response; requests cannot overrun memory.
// Each word is two mono PCM samples, requested once per~41.7us. No BRAM.
module db_library_audio_reader(
 input clk,rst,cache_valid,input[7:0]cache_generation,input[20:0]cache_samples,
 input[20:0]request_word,output mem_req,output[20:0]mem_addr,input mem_ready,mem_rvalid,input[31:0]mem_data,
 output reg[60:0]response
);
 reg waiting,request_pending;reg[20:0]request_address;reg[19:0]issued_word,last_word;reg[7:0]issued_generation,last_generation;reg fresh;
 wire[19:0]wanted=request_word[20]?20'd0:request_word[19:0];
 // Register arbitration request/address before the shared SDRAM ready path.
 assign mem_req=request_pending&&cache_valid&&!rst;
 assign mem_addr=request_address;
 always@(posedge clk or posedge rst)
 if(rst)begin waiting<=0;request_pending<=0;request_address<=21'h108000;issued_word<=0;last_word<=0;issued_generation<=0;last_generation<=0;fresh<=0;response<=0;end
 else begin
  if(!cache_valid)begin fresh<=0;request_pending<=0;end
  if(cache_valid&&!waiting&&!request_pending&&(!fresh||last_generation!=cache_generation||last_word!=wanted)&&{wanted,1'b0}<cache_samples)begin
   request_pending<=1;request_address<=21'h108000+{1'b0,wanted};issued_word<=wanted;issued_generation<=cache_generation;
  end
  if(mem_req&&mem_ready)begin waiting<=1;request_pending<=0;end
  if(mem_rvalid&&waiting)begin waiting<=0;last_word<=issued_word;last_generation<=issued_generation;fresh<=1;
   response<={1'b1,issued_generation,issued_word,mem_data};
  end
 end
endmodule
