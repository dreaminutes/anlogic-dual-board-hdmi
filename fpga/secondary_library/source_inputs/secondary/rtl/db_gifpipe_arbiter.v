`timescale 1ns/1ps
// Memory-domain producer (canvas/scaler/raw frame) plus physical sender.
// Up to eight ordered SDRAM reads; responses retain their original owner.
// A waiting write drains accepted reads before issuing, so a continuous sender
// cannot starve the producer. Equal read contention is round-robin.
// Hard reset requires the SDRAM response pipeline to be reset at the same time.
// Live cancel blocks NEW commands but drains/routs accepted reads; never reset
// the owner queue on cancel. Memory responses must have >=1 cycle latency.
module db_gifpipe_arbiter(
 input wire clk,rst,cancel,batch_enable,gif_mode,
 input wire producer_req,producer_write,input wire[20:0]producer_address,input wire[31:0]producer_data,
 output wire producer_ready,producer_rvalid,output wire[31:0]producer_rdata,
 input wire sender_req,input wire[20:0]sender_address,
 output wire sender_ready,sender_rvalid,output wire[31:0]sender_rdata,
 output wire mem_req,mem_write,output wire[20:0]mem_address,output wire[31:0]mem_data,
 input wire mem_ready,mem_rvalid,input wire[31:0]mem_rdata,
 output wire writes_idle,sender_reads_idle,producer_reads_idle,memory_idle,
 output wire[3:0]pending_reads,output reg[31:0]unexpected_responses
);
 reg owner[0:7];reg[2:0]head,tail;reg[3:0]write_guard;
 reg[3:0]pending,sender_pending,producer_pending;reg prefer_sender;
 // Bound each contested phase to eight accepted commands. No new read
 // is issued during a write phase; the existing owner queue first drains.
 // Read phases end after eight sender reads or as soon as sender is absent.
 reg write_phase;reg[3:0]write_run,read_run;
 wire want_write=producer_req&&producer_write;
 wire write_barrier=want_write&&pending!=0;
 wire sender_eligible=(!gif_mode||write_guard==0)&&sender_req&&pending<8&&(batch_enable?(!want_write||!write_phase):!write_barrier);
 wire producer_eligible=producer_req&&(producer_write?(pending==0&&(!batch_enable||!sender_req||write_phase)):pending<8&&(!gif_mode||write_guard==0));
 wire select_sender=!rst&&!cancel&&sender_eligible&&(!producer_eligible||prefer_sender);
 wire select_producer=!rst&&!cancel&&producer_eligible&&!select_sender;
 assign mem_req=select_sender||select_producer;
 assign mem_write=select_producer&&producer_write;
 assign mem_address=select_sender?sender_address:producer_address;assign mem_data=producer_data;
 assign sender_ready=select_sender&&mem_ready;assign producer_ready=select_producer&&mem_ready;
 wire accepted=mem_req&&mem_ready;
 wire read_issue=accepted&&!mem_write;
 wire read_return=mem_rvalid&&pending!=0;
 wire return_sender=read_return&&owner[head];
 wire return_producer=read_return&&!owner[head];
 assign sender_rvalid=return_sender;assign producer_rvalid=return_producer;
 assign sender_rdata=mem_rdata;assign producer_rdata=mem_rdata;
 assign writes_idle=write_guard==0&&!(producer_req&&producer_write);
 assign sender_reads_idle=sender_pending==0&&!select_sender;
 assign producer_reads_idle=producer_pending==0&&!(select_producer&&!producer_write);
 assign memory_idle=pending==0&&write_guard==0&&!mem_req;
 assign pending_reads=pending;
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   head<=0;tail<=0;pending<=0;sender_pending<=0;producer_pending<=0;write_guard<=0;prefer_sender<=1;unexpected_responses<=0;write_phase<=1;write_run<=0;read_run<=0;
  end else begin
   if(write_guard!=0)write_guard<=write_guard-1'b1;
   if(cancel||!batch_enable||!sender_req)begin write_phase<=1;write_run<=0;read_run<=0;end
   else if(accepted)begin
    if(mem_write)begin
     if(!sender_req)begin write_phase<=1;write_run<=0;read_run<=0;end
     else if(write_run==7)begin write_phase<=0;write_run<=0;read_run<=0;end
     else write_run<=write_run+1'b1;
    end else if(select_sender)begin
     write_run<=0;
     if(write_phase)read_run<=0;
     else if(read_run==7)begin write_phase<=1;write_run<=0;read_run<=0;end
     else read_run<=read_run+1'b1;
    end
   end
   if(accepted)begin
    prefer_sender<=!select_sender;
    // 50MHz SDRAM uses seven-cycle write recovery; eight full
    // memory clocks retain160ns and cover the command/DQ opposite half-cycle.
    if(mem_write)write_guard<=8;
   end
   if(read_issue)begin owner[tail]<=select_sender;tail<=tail+1'b1;end
   if(read_return)head<=head+1'b1;
   case({read_issue,read_return})
    2'b10:pending<=pending+1'b1;2'b01:pending<=pending-1'b1;default:pending<=pending;
   endcase
   case({read_issue&&select_sender,return_sender})
    2'b10:sender_pending<=sender_pending+1'b1;2'b01:sender_pending<=sender_pending-1'b1;default:sender_pending<=sender_pending;
   endcase
   case({read_issue&&select_producer,return_producer})
    2'b10:producer_pending<=producer_pending+1'b1;2'b01:producer_pending<=producer_pending-1'b1;default:producer_pending<=producer_pending;
   endcase
   if(mem_rvalid&&pending==0)unexpected_responses<=32'd1;
  end
 end
endmodule
