// Native3.3V SDHC/SDXC read-only diagnostic controller. No writes or erase.
// 100MHz logic:200kHz identification,25MHz negotiation,50MHz afterHSqualification. Card power-cycle required
// after SPI mode. A host reset/CMD0 cannot switch a card out of SPI mode.
module db_fast24_sd_controller #(
 parameter INIT_TIMEOUT=250000000,READ_TIMEOUT=30000000
)(input wire clk,fast_clk,sample_clk,rst,cmd_in,input wire[3:0]dat_in,
 output wire sd_clk,output wire cmd_out,cmd_oe,
 input wire hs_request,output reg hs_selected,query_checked,input wire read_request,input wire[31:0]read_lba,input wire[4:0]read_count,
 output reg initialized,failed,output reg[7:0]error_code,output reg[63:0]first_failure,
 output wire[7:0]byte_data,output wire byte_valid,
 output reg read_done,output wire read_ready,
 output wire block_done,block_failed,output reg count_known,count_supported,output wire multi_active,
 output reg[4:0]stage,output reg[15:0]rca,output reg[31:0]ocr
);
 // Related PLL clocks: engines100MHz,fast reference50MHz phase0,
 // input sampler50MHz phase6ns. Fast SCK is inverse fast reference.
 // Capture at26ns after a falling launch, before next data at>=28ns.
 reg[7:0]half_count;reg fast,slow_clk;
 reg fast_fall_sample;
 (* syn_keep=1,syn_preserve=1 *)reg fast_phase;
 // This half-cycle observation is fully timed, not an asynchronous CDC.
 always@(negedge clk or posedge rst)
  if(rst)fast_fall_sample<=0;else fast_fall_sample<=!fast_clk;
 // Predict the next physical edge through a full-cycle control register.
 // Only this single register sees the half-cycle PLL phase observation;
 // command, timeout and status fanout receives a complete100MHz period.
 always@(posedge clk or posedge rst)
  if(rst)fast_phase<=0;else fast_phase<=fast_fall_sample;
 wire rise_tick=hs_selected?fast_phase:(half_count==0&&!slow_clk);
 wire fall_tick=hs_selected?!fast_phase:(half_count==0&&slow_clk);
 // Counts2..16 reserve one adjacent guard sector. Overflow is possible
 // only in the last16 LBAs,so use a six-bit carry rather than two32-bit
 // subtract/compare chains. Count1 permits the final LBA as before.
 wire[5:0]request_tail_sum={2'b0,read_lba[3:0]}+{1'b0,read_count};
 wire request_bounds_ok=read_count!=0&&read_count<=16&&
  !(read_count>1&&(&read_lba[31:4])&&request_tail_sum>15);
 assign sd_clk=(rst||failed)?1'b0:(hs_selected?!fast_clk:slow_clk);
 always@(posedge clk or posedge rst)begin
  if(rst)begin slow_clk<=0;half_count<=249;end
  else if(failed||hs_selected)begin slow_clk<=0;half_count<=249;end
  else if(half_count==0)begin slow_clk<=!slow_clk;half_count<=fast?1:249;end
  else half_count<=half_count-1'b1;
 end
 reg sampled_cmd;reg[3:0]sampled_dat;
 always@(posedge sample_clk or posedge rst)
  if(rst)begin sampled_cmd<=1;sampled_dat<=15;end
  else begin sampled_cmd<=cmd_in;sampled_dat<=dat_in;end
 reg engine_cmd,sample_tick;reg[3:0]engine_dat;
 always@(posedge clk or posedge rst)begin
  if(rst)begin engine_cmd<=1;engine_dat<=15;sample_tick<=0;end
  else begin
   engine_cmd<=sampled_cmd;engine_dat<=sampled_dat;
   sample_tick<=hs_selected?fast_phase:(slow_clk&&half_count==1);
  end
 end
 reg go,arm;reg using_multi,open_ended,normal_stop;reg[9:0]resync_clocks;reg[4:0]target_count,completed_count;reg[7:0]abort_code;
 reg[5:0]cmd_index;reg[31:0]arg;reg[1:0]response_kind;
 wire command_busy,command_done,command_failed;wire[3:0]command_error;wire raw_byte_valid,raw_cmd_oe;
 wire[135:0]response;wire data_busy,data_done,data_failed;wire[3:0]data_error;
 wire command_reset=rst||failed;
 db_sd4_command command(.clk(clk),.rst(command_reset),.rise_tick(sample_tick),.fall_tick(fall_tick),.start(go),.index(cmd_index),.argument(arg),.response_type(response_kind),.cmd_in(engine_cmd),.cmd_out(cmd_out),.cmd_oe(raw_cmd_oe),.busy(command_busy),.done(command_done),.failed(command_failed),.error_code(command_error),.response(response));
 // Terminal failure must not keep clocking an unacknowledged read/stop.
 assign cmd_oe=raw_cmd_oe;
 db_av4_data_rx #(.TIMEOUT_CYCLES(READ_TIMEOUT)) data_rx(.clk(clk),.rst(rst),.rise_tick(sample_tick),.arm(arm),.auto_next(using_multi&&completed_count+1<target_count),.dat(engine_dat),.byte_data(byte_data),.byte_valid(raw_byte_valid),.block_done(data_done),.failed(data_failed),.error_code(data_error),.busy(data_busy));
 assign block_failed=data_failed;assign multi_active=using_multi;
 // Additional status receiver; ordinary512byte data path is unchanged.
 reg[3:0]step;
 reg status_arm,status_complete;reg[6:0]status_bytes;reg[15:0]hs_group1,hs_current,hs_busy;reg[3:0]hs_selection;reg[7:0]hs_version;
 reg[4:0]settle_clocks;
 wire[7:0]status_byte;wire status_byte_valid,status_done,status_failed;wire[3:0]status_error;
 db_sd6_status_rx #(.TIMEOUT_CYCLES(READ_TIMEOUT)) status_rx(.clk(clk),.rst(rst),.rise_tick(sample_tick),.arm(status_arm),.dat(engine_dat),.byte_data(status_byte),.byte_valid(status_byte_valid),.block_done(status_done),.failed(status_failed),.error_code(status_error),.busy());
 always@(posedge clk or posedge rst)begin
  if(rst)begin status_complete<=0;status_bytes<=0;hs_group1<=0;hs_current<=0;hs_busy<=0;hs_selection<=0;hs_version<=0;end
  else if(status_arm)begin status_complete<=0;status_bytes<=0;hs_group1<=0;hs_current<=0;hs_busy<=0;hs_selection<=0;hs_version<=0;end
  else begin
   if(status_byte_valid&&step>=13&&!failed)begin
    status_bytes<=status_bytes+1'b1;
    case(status_bytes)
     0:hs_current[15:8]<=status_byte;1:hs_current[7:0]<=status_byte;
     12:hs_group1[15:8]<=status_byte;13:hs_group1[7:0]<=status_byte;
     16:hs_selection<=status_byte[3:0];17:hs_version<=status_byte;
     28:hs_busy[15:8]<=status_byte;29:hs_busy[7:0]<=status_byte;
    endcase
   end
   if(status_done&&step>=13)status_complete<=1;
  end
 end
 localparam POWER=0,ISSUE=1,COMMAND_WAIT=2,SELECT_BUSY=3,READY=4,DATA_WAIT=5,ERROR=6,INIT_DELAY=7,ABORT_BUSY=8,RESYNC=9,STATUS_WAIT=10,STATUS_CHECK=11,FUNCTION_GAP=12,HS_ALIGN=13;
 reg[7:0]power_clocks;reg[27:0]init_timer;reg[24:0]read_timer;reg[16:0]poll_delay;
 reg[31:0]held_lba;reg first_failure_seen;
 wire reading=(stage==DATA_WAIT||stage==COMMAND_WAIT&&step==9)&&!failed;
 // CMD12 may truncate provisional DATA. Never expose abort/busy bits as bytes.
 assign byte_valid=raw_byte_valid&&reading;
 assign block_done=data_done&&reading;
 wire[31:0]status_bits=response[39:8];
 assign read_ready=initialized&&stage==READY&&!failed;
 task remember(input[7:0]code);begin
  if(!first_failure_seen)begin
   first_failure_seen<=1;
   first_failure<={status_bits,8'd0,stage[3:0],step,{2'd0,cmd_index},code};
  end
 end endtask
 task fail(input[7:0]code);begin remember(code);failed<=1;error_code<=code;stage<=ERROR;end endtask
 always@(posedge clk or posedge rst)begin
  if(rst)begin hs_selected<=0;query_checked<=0;status_arm<=0;settle_clocks<=0;first_failure<=0;first_failure_seen<=0;fast<=0;go<=0;arm<=0;cmd_index<=0;arg<=0;response_kind<=0;initialized<=0;failed<=0;error_code<=0;read_done<=0;stage<=POWER;step<=0;power_clocks<=0;init_timer<=0;read_timer<=0;poll_delay<=0;rca<=0;ocr<=0;held_lba<=0;using_multi<=0;open_ended<=0;normal_stop<=0;resync_clocks<=0;target_count<=1;completed_count<=0;abort_code<=0;count_known<=0;count_supported<=0;end
  else begin
   go<=0;arm<=0;status_arm<=0;read_done<=0;
   if(!initialized&&!failed)init_timer<=init_timer+1'b1;
   if(stage==COMMAND_WAIT&&(step==9||step==10||step==11||step==12||step>=13)||stage==DATA_WAIT||stage==SELECT_BUSY||stage==ABORT_BUSY||stage==STATUS_WAIT||stage==STATUS_CHECK||stage==FUNCTION_GAP||stage==HS_ALIGN)read_timer<=read_timer+1'b1;
   if(failed)begin stage<=ERROR;initialized<=0;end
   else if(!initialized&&!failed&&init_timer==INIT_TIMEOUT-1)fail(8'h01);
   else if((stage==COMMAND_WAIT&&(step==9||step==10||step==11||step==12||step>=13)||stage==DATA_WAIT||stage==SELECT_BUSY||stage==ABORT_BUSY||stage==STATUS_WAIT||stage==STATUS_CHECK||stage==FUNCTION_GAP||stage==HS_ALIGN)&&read_timer==READ_TIMEOUT-1)begin
    if(using_multi&&(stage==DATA_WAIT||stage==COMMAND_WAIT&&step==9))begin remember(8'h02);abort_code<=8'h02;step<=11;read_timer<=0;stage<=ISSUE;end
    else fail(8'h02);
   end
   else if(step>=13&&status_byte_valid&&status_bytes>=64)fail(8'h54);
   else if(step>=13&&status_done&&status_failed)fail({4'h7,status_error});
   else if(data_done&&data_failed&&using_multi&&(stage==DATA_WAIT||stage==COMMAND_WAIT&&step==9))begin
    remember({4'h3,data_error});abort_code<={4'h3,data_error};step<=11;read_timer<=0;stage<=ISSUE;
   end else if(data_done&&data_failed&&!using_multi&&(stage==DATA_WAIT||stage==COMMAND_WAIT&&step==9))fail({4'h3,data_error});
   else case(stage)
    POWER:if(rise_tick)begin if(power_clocks==79)begin step<=0;stage<=ISSUE;end else power_clocks<=power_clocks+1'b1;end
    ISSUE:if(!command_busy)begin
     go<=1;response_kind<=1;stage<=COMMAND_WAIT;
     case(step)
      0:begin cmd_index<=0;arg<=0;response_kind<=0;end
      1:begin cmd_index<=8;arg<=32'h1aa;end
      2:begin cmd_index<=55;arg<=0;end
      3:begin cmd_index<=41;arg<=32'h40ff8000;response_kind<=3;end
      4:begin cmd_index<=2;arg<=0;response_kind<=2;end
      5:begin cmd_index<=3;arg<=0;end
      6:begin cmd_index<=7;arg<={rca,16'd0};end
      7:begin cmd_index<=55;arg<={rca,16'd0};end
      8:begin cmd_index<=6;arg<=2;end
      9:begin cmd_index<=using_multi?18:17;arg<=held_lba;arm<=1;end
      10:begin cmd_index<=23;arg<={27'd0,target_count};end
      11:begin cmd_index<=12;arg<=0;end
      12:begin cmd_index<=13;arg<={rca,16'd0};end
      13:begin cmd_index<=6;arg<=32'h00fffff1;status_arm<=1;end
      14:begin cmd_index<=6;arg<=32'h80fffff1;status_arm<=1;end
      default:fail(8'h03);
     endcase
    end
    COMMAND_WAIT:if(command_done)begin
     if(command_failed)begin
      if(step==10&&command_error==1)begin
       // No response does not prove unsupported. Do not trust the pending count:
       // idle clocks then CRC-checked CMD13 cancels it and verifies TRAN/ready.
       resync_clocks<=0;read_timer<=0;stage<=RESYNC;
      end else if(step==9&&using_multi)begin remember({4'h1,command_error});abort_code<={4'h1,command_error};step<=11;read_timer<=0;stage<=ISSUE;end
      else fail({4'h1,command_error});
     end
     else if(step==10&&(status_bits&32'hfdffe008)==32'h00400000)begin
      // Explicit unsupported response also gets a clean checked TRAN boundary.
      resync_clocks<=0;read_timer<=0;stage<=RESYNC;
     end
     else if((step==2||step==6||step==7||step==8||step==9||step==10||step==11||step==12||step>=13)&&(status_bits&32'hfdffe008)!=0&&
      !(step==12&&(status_bits&32'hfdffe008)==32'h00400000))begin
      // SEND_STATUS may report the preceding unsupportedCMD23 flag once.
      // Only ILLEGAL_COMMAND is accepted here;CRC and all other errors remain fatal.
      if(step==9&&using_multi)begin remember(8'h20);abort_code<=8'h20;step<=11;read_timer<=0;stage<=ISSUE;end
      else fail(8'h20);
     end
     else if(step>=13&&(status_bits[12:9]!=4||!status_bits[8]))fail(8'h42);
     else case(step)
      0:begin step<=1;stage<=ISSUE;end
      1:if(status_bits[11:0]!=12'h1aa)fail(8'h21);else begin step<=2;stage<=ISSUE;end
      2,7:if(!status_bits[5])fail(8'h22);else begin step<=step+1'b1;stage<=ISSUE;end
      3:begin
       ocr<=status_bits;
       if(status_bits[31])begin if(!status_bits[30])fail(8'h23);else begin step<=4;stage<=ISSUE;end end
       else begin poll_delay<=0;stage<=INIT_DELAY;end
      end
      4:begin step<=5;stage<=ISSUE;end
      5:if(status_bits[31:16]==0||status_bits[15:13]!=0)fail(8'h24);else begin rca<=status_bits[31:16];step<=6;stage<=ISSUE;end
      6:begin read_timer<=0;stage<=SELECT_BUSY;end
      8:begin fast<=1;initialized<=1;stage<=READY;end
      9:stage<=DATA_WAIT;
      13,14:stage<=STATUS_WAIT;
      10:begin count_known<=1;count_supported<=1;using_multi<=1;open_ended<=0;step<=9;stage<=ISSUE;end
      11:begin read_timer<=0;stage<=ABORT_BUSY;end
      12:begin
       if(status_bits[12:9]!=4||!status_bits[8])fail(8'h45);
       else begin
        count_known<=1;count_supported<=0;using_multi<=1;open_ended<=1;
        step<=9;read_timer<=0;stage<=ISSUE;
       end
      end
      default:fail(8'h03);
     endcase
    end
    SELECT_BUSY:if(sample_tick&&engine_dat[0])begin step<=7;stage<=ISSUE;end
    INIT_DELAY:if(poll_delay==99999)begin step<=2;stage<=ISSUE;end else poll_delay<=poll_delay+1'b1;
    RESYNC:if(sample_tick)begin
     if(resync_clocks==1023)begin step<=12;read_timer<=0;stage<=ISSUE;end
     else resync_clocks<=resync_clocks+1'b1;
    end
    READY:if(hs_request&&!hs_selected)begin
     using_multi<=0;open_ended<=0;step<=13;read_timer<=0;stage<=ISSUE;
    end else if(read_request)begin
     if(!request_bounds_ok)fail(8'h43);
     else begin
      held_lba<=read_lba;target_count<=read_count;completed_count<=0;normal_stop<=0;
      using_multi<=read_count>1&&count_known&&!count_supported;
      open_ended<=read_count>1&&count_known&&!count_supported;
      step<=read_count>1&&(!count_known||count_supported)?10:9;read_timer<=0;stage<=ISSUE;
     end
    end
    DATA_WAIT:if(data_done)begin
     if(data_failed)fail({4'h3,data_error});
     else begin
      completed_count<=completed_count+1'b1;read_timer<=0;
      if(completed_count+1==target_count)begin
       if(open_ended)begin normal_stop<=1;step<=11;stage<=ISSUE;end
       else begin read_done<=1;stage<=READY;end
      end
      else if(!using_multi)begin held_lba<=held_lba+1'b1;step<=9;stage<=ISSUE;end
     end
    end
    ABORT_BUSY:if(sample_tick&&engine_dat[0])begin
     if(normal_stop)begin read_done<=1;normal_stop<=0;stage<=READY;end
     else fail(abort_code);
    end
    STATUS_WAIT:if(status_complete||status_done)begin
     if(status_failed)fail({4'h7,status_error});else stage<=STATUS_CHECK;
    end
    STATUS_CHECK:begin
     if(status_bytes!=64)fail(8'h54);
     else if(hs_version>1)fail(8'h52);
     else if(hs_current==0||hs_current>200)fail(8'h51);
     else if(!hs_group1[1]||(hs_version==1&&hs_busy[1]))fail(8'h50);
     else if(hs_selection!=1)fail(step==14?8'h55:8'h50);
     else begin if(step==13)query_checked<=1;settle_clocks<=0;stage<=FUNCTION_GAP;end
    end
    FUNCTION_GAP:if(fall_tick)begin
     // Sixteen physical falling SCK ticks after validated status END;specification>=8.
     // Commit on the physical falling edge,never mid-cycle after the receiver pipeline.
     if(settle_clocks==15)begin
      read_timer<=0;
      if(step==13)begin step<=14;stage<=ISSUE;end
      else stage<=HS_ALIGN;
     end else settle_clocks<=settle_clocks+1'b1;
    end
    // Both clocks are low at the mux handoff. The first low interval may
    // extend; no shortened high or low SCK pulse is permitted.
    HS_ALIGN:if(!fast_phase&&!slow_clk)begin hs_selected<=1;stage<=READY;end
    ERROR:begin initialized<=0;end
    default:fail(8'h03);
   endcase
  end
 end
endmodule
