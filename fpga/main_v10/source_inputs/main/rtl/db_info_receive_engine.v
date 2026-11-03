`timescale 1ns/1ps
// V1.2 media record-to-memory engine, separate from the verified V1.1 path. Real controller/HDMI/UI/TF
// are deliberately outside this module. Armed epochs belong to their own
// domains and must arrive through the future master authorization handshake.
`include "db_media_metadata.vh"
module db_info_receive_engine(output wire[31:0] display_source_size,
 output wire cache_valid,cache_loading,output wire[6:0]cache_percent,output wire[31:0]cache_asset,output wire[20:0]cache_samples,output wire[7:0]cache_generation,
 output wire session_confirm_src,
 output wire pcm_write,output wire[15:0]pcm_data,input wire pcm_ready,input wire[12:0]pcm_free,
 input wire src_clk,mem_clk,transport_arst,main_rst,
 input wire [31:0] armed_epoch_src,armed_epoch_mem,
 input wire in_valid,input wire [7:0] in_data,output wire can_start,
 input wire [20:0] base0,base1,base2,
 input wire [2:0] hold_slots,input wire vblank_event,present_allow,
 output wire mem_req,output wire [20:0] mem_address,output wire [31:0] mem_data,
 input wire mem_ready,mem_done,memory_writes_idle,
 output wire display_valid,output wire [1:0] display_slot,
 output wire [31:0] display_frame_id,display_epoch,
 output wire receive_active,pending_valid,session_ready_mem,writes_idle,
 output wire [15:0] expected_row,
 output wire [31:0] crc_errors,rejected_records,rejected_rows,
 output wire [2:0] quarantine_slots,
 output wire display_metadata_valid,output wire[193:0]display_metadata,
 output wire asset_changed,static_transition,dynamic_continuation,output wire[31:0]metadata_errors,
 output wire transport_idle,output wire bmp_failed,output wire file_room,
 output wire monitor_begin,monitor_complete,monitor_present,monitor_cancel,
 output wire[31:0]monitor_epoch,monitor_frame,output wire[1:0]monitor_slot
);
 wire[31:0]packet_crc,packet_format,packet_timeout,packet_busy;
 assign crc_errors=packet_crc|packet_format|packet_timeout|packet_busy;
 wire sreset,dreset,packet_valid,packet_take,normal_take,blob_take;wire[10:0]normal_address,blob_address;wire [7:0]ptype,pflags,pdata;
 wire[31:0]pword;wire [31:0] pframe;wire [15:0]pseq,plen;wire[10:0]paddr;
 db_fps_packet_rx #(.MAX_PAYLOAD(1284)) packet_rx(.clk(src_clk),.rst(sreset),.in_valid(in_valid),.in_data(in_data),
  .can_start(can_start),.packet_valid(packet_valid),.packet_take(packet_take),.packet_type(ptype),.flags(pflags),
  .frame_id(pframe),.sequence_number(pseq),.payload_length(plen),.read_address(paddr),.read_data(pdata),.read_word(pword),
  .packet_committed(),.packet_dropped(),.crc_errors(packet_crc),.format_errors(packet_format),.timeout_errors(packet_timeout),.busy_errors(packet_busy));
 wire source_session;
 assign session_confirm_src=source_session;
 wire blob_type=ptype>=8'h30&&ptype<=8'h35;
 wire[10:0]blob_used;
 assign file_room=blob_used<256;
 wire blob_write,blob_full,blob_empty,blob_read,blob_error;wire[33:0]blob_data,blob_q;
 // One elastic token register separates synchronous BRAM decode from the
 // shared SDRAM address/ready path. Replace on consume: one word per cycle,
 // with exact token ordering and stable data throughout downstream stalls.
 reg blob_buffer_valid;reg[33:0]blob_buffer;
 wire blob_sink_read;
 assign blob_read=!blob_empty&&(!blob_buffer_valid||blob_sink_read);
 always@(posedge mem_clk or posedge main_rst)
 if(main_rst)begin blob_buffer_valid<=0;blob_buffer<=0;end
 else if(dreset)blob_buffer_valid<=0;
 else if(blob_read)begin blob_buffer<=blob_q;blob_buffer_valid<=1;end
 else if(blob_sink_read)blob_buffer_valid<=0;
 assign packet_take=blob_type?blob_take:normal_take;assign paddr=blob_type?blob_address:normal_address;
 db_library_blob_router blob(.clk(src_clk),.rst(sreset),.session_ready(source_session),.armed_epoch(armed_epoch_src),
 .packet_valid(packet_valid&&blob_type),.packet_type(ptype),.packet_flags(pflags),.packet_frame(pframe),.packet_sequence(pseq),.packet_length(plen),
 .packet_take(blob_take),.read_address(blob_address),.read_data(pdata),.fifo_write(blob_write),.fifo_data(blob_data),.fifo_full(blob_full),.failed(blob_error));
 db_full_word_fifo #(.AW(10)) blob_fifo(.rst(transport_arst||main_rst),.clkw(src_clk),.clkr(mem_clk),.we(blob_write),.re(blob_read),.di(blob_data),.dout(blob_q),.empty_flag(blob_empty),.full_flag(blob_full),.wrusedw(blob_used));
 wire row_source_valid,row_source_take,row_src_idle;
 wire[31:0]row_source_epoch,row_source_frame;wire[15:0]row_source_seq,row_source_length;
 wire[10:0]row_source_address;wire[7:0]row_source_data;
 wire cmd_valid,cmd_ready,cmd_done,cmd_ok;

 wire[7:0]cmd_type;wire[193:0]cmd_metadata;
 db_av2_record_router records(.pcm_write(pcm_write),.pcm_data(pcm_data),.pcm_ready(pcm_ready),.pcm_free(pcm_free),.clk(src_clk),.rst(sreset),.armed_epoch(armed_epoch_src),
  .packet_valid(packet_valid&&!blob_type),.packet_take(normal_take),.packet_type(ptype),.packet_flags(pflags),
  .packet_frame_id(pframe),.packet_sequence(pseq),.packet_length(plen),.packet_read_address(normal_address),.packet_read_data(pdata),
  .session_ready(source_session),.row_packet_valid(row_source_valid),.row_packet_take(row_source_take),
  .row_epoch(row_source_epoch),.row_frame_id(row_source_frame),.row_sequence(row_source_seq),.row_length(row_source_length),
  .row_read_address(row_source_address),.row_read_data(row_source_data),.rows_idle(row_src_idle),
  .command_valid(cmd_valid),.command_ready(cmd_ready),.command_done(cmd_done),.command_ok(cmd_ok),
  .command_type(cmd_type),.command_metadata(cmd_metadata),.rejected_records(rejected_records),.record_rejected());
 wire row_valid,row_take;wire[31:0]row_epoch,row_frame,row_data;
 wire[15:0]row_index,row_length;wire[8:0]row_address;
 db_fps_row_mailbox_cdc rows(.src_clk(src_clk),.dst_clk(mem_clk),.arst(transport_arst),
  .src_reset_active(sreset),.dst_reset_active(dreset),
  .row_packet_valid(row_source_valid),.row_packet_take(row_source_take),.packet_epoch(row_source_epoch),
  .packet_frame_id(row_source_frame),.packet_row(row_source_seq),.packet_length(row_source_length),
  .packet_read_address(row_source_address),.packet_read_data(row_source_data),.packet_word_data(pword),.src_idle(row_src_idle),.discarded_packets(),
  .row_valid(row_valid),.row_take(row_take),.row_epoch(row_epoch),.row_frame_id(row_frame),.row_index(row_index),
  .row_length(row_length),.row_read_address(row_address),.row_read_data(row_data));
 wire dst_cmd_valid,dst_cmd_take,dst_cmd_ok;wire[201:0]dst_cmd;
 db_command_cdc #(.WIDTH(202)) commands(.src_clk(src_clk),.dst_clk(mem_clk),.arst(transport_arst),
  .src_valid(cmd_valid),.src_ready(cmd_ready),.src_data({cmd_type,cmd_metadata}),
  .src_done(cmd_done),.src_ok(cmd_ok),.dst_valid(dst_cmd_valid),.dst_take(dst_cmd_take),.dst_ok(dst_cmd_ok),.dst_data(dst_cmd));

 wire[7:0]command_kind=dst_cmd[201:194];wire[193:0]command_meta=dst_cmd[193:0];
 wire[31:0]command_epoch=command_meta[`DB_MEDIA_EPOCH],command_frame=command_meta[`DB_MEDIA_WIRE_FRAME];
 wire begin_ready,end_ready,session_start,begin_valid,end_valid,command_abort;
 wire raw_metadata_valid,raw_metadata_ready,raw_complete,raw_end_valid,raw_end_ready,raw_busy,raw_failed;
 wire[193:0]raw_metadata;wire[31:0]raw_end_epoch,raw_end_frame;
 wire raw_req,raw_write,normal_req,normal_ready,normal_done,normal_idle;wire[20:0]raw_addr,normal_addr;wire[31:0]raw_data,normal_data;
 reg[7:0]raw_drain;
 always@(posedge mem_clk or posedge main_rst)if(main_rst)raw_drain<=0;else raw_drain<={raw_drain[6:0],raw_req&&mem_ready&&!normal_req};
 wire raw_idle=raw_drain==0;
 assign writes_idle=normal_idle&&raw_idle&&memory_writes_idle;
 assign mem_req=normal_req||raw_req;assign mem_address=normal_req?normal_addr:raw_addr;assign mem_data=normal_req?normal_data:raw_data;
 assign normal_ready=mem_ready;
 db_tune_write_retirement normal_retire(.clk(mem_clk),.rst(main_rst),.accepted(normal_req&&normal_ready),.done(normal_done));
 assign bmp_failed=raw_failed||blob_error;

 wire[31:0]raw_source_size;
 reg[31:0]slot_size0,slot_size1,slot_size2;
 always@(posedge mem_clk or posedge main_rst)
 if(main_rst)begin slot_size0<=0;slot_size1<=0;slot_size2<=0;end
 else if(dreset||session_start)begin slot_size0<=0;slot_size1<=0;slot_size2<=0;end
 else if(raw_metadata_ready)case(receive_slot)
  0:slot_size0<=raw_source_size;1:slot_size1<=raw_source_size;2:slot_size2<=raw_source_size;
 endcase
 assign display_source_size=display_valid&&display_metadata_valid&&display_metadata[193:192]==0?
  (display_slot==0?slot_size0:display_slot==1?slot_size1:slot_size2):32'd0;
 wire[31:0]receive_frame;wire[1:0]receive_slot;
 reg negotiated;reg[31:0]session_epoch;
 assign session_ready_mem=negotiated&&session_epoch==armed_epoch_mem&&!dreset;
 wire epoch_ok=command_epoch==armed_epoch_mem;
 wire hello_ok=command_kind==8'h03&&epoch_ok&&command_frame==0;
 wire media_ok=command_kind==8'h13&&epoch_ok&&session_ready_mem&&command_meta[`DB_MEDIA_KIND]<=2&&command_meta[`DB_MEDIA_DURATION]!=0&&
  (command_meta[`DB_MEDIA_KIND]!=0||command_meta[`DB_MEDIA_CONTENT_FRAME]==0);
 wire ending_ok=command_kind==8'h12&&epoch_ok&&session_ready_mem;
 wire complete_lease=receive_active&&receive_frame==command_frame&&expected_row==480;
 wire allowed=hello_ok||media_ok||ending_ok;
 assign dst_cmd_take=dst_cmd_valid&&!dreset&&(!allowed||(hello_ok&&writes_idle)||(media_ok&&begin_ready&&!raw_busy)||(ending_ok&&(!complete_lease||end_ready)));
 assign dst_cmd_ok=dst_cmd_take&&(hello_ok||(media_ok&&begin_ready&&!raw_busy)||(ending_ok&&complete_lease&&end_ready));
 // No guard-ready -> take -> session-start loop: HELLO starts independently.
 assign session_start=dst_cmd_valid&&!dreset&&hello_ok&&writes_idle;
 assign begin_valid=dst_cmd_valid&&!dreset&&media_ok&&!raw_busy;
 assign end_valid=dst_cmd_valid&&!dreset&&ending_ok&&complete_lease;
 assign command_abort=dst_cmd_valid&&!dreset&&ending_ok&&receive_active&&receive_frame==command_frame&&!complete_lease;
 always @(posedge mem_clk or posedge main_rst)
  if(main_rst)begin negotiated<=0;session_epoch<=0;end
  else if(dreset)negotiated<=0;
  else if(session_start)begin negotiated<=1;session_epoch<=command_epoch;end
 wire row_committed,row_failed;wire[31:0]committed_epoch,committed_frame;
 wire[15:0]committed_row,committed_length;
 wire[20:0]receive_base=receive_slot==0?base0:receive_slot==1?base1:base2;
 db_pipelined_row_pixel_writer writer(.clk(mem_clk),.rst(main_rst),.abort_request(dreset),
  .row_valid(row_valid),.row_take(row_take),.row_epoch(row_epoch),.row_frame_id(row_frame),.row_index(row_index),.row_length(row_length),
  .row_read_address(row_address),.row_read_data(row_data),.lease_active(receive_active&&session_ready_mem),
  .lease_epoch(session_epoch),.lease_frame_id(receive_frame),.lease_expected_row(expected_row),.lease_base(receive_base),
  .mem_req(normal_req),.mem_address(normal_addr),.mem_data(normal_data),.mem_ready(normal_ready),.mem_done(normal_done),
  .writes_idle(normal_idle),.row_committed(row_committed),.row_failed(row_failed),.committed_epoch(committed_epoch),
  .committed_frame_id(committed_frame),.committed_row(committed_row),.committed_length(committed_length),.rejected_rows(rejected_rows));
 db_info_blob_sink bitmap(.source_size(raw_source_size),.cache_valid(cache_valid),.cache_loading(cache_loading),.cache_percent(cache_percent),.cache_asset(cache_asset),.cache_samples(cache_samples),.cache_generation(cache_generation),.clk(mem_clk),.rst(dreset||main_rst),.fifo_data(blob_buffer),.fifo_empty(!blob_buffer_valid),.fifo_read(blob_sink_read),
 .metadata_valid(raw_metadata_valid),.metadata_ready(raw_metadata_ready),.metadata(raw_metadata),.target_base(receive_base),.target_slot(receive_slot),
 .mem_req(raw_req),.mem_write(raw_write),.mem_address(raw_addr),.mem_data(raw_data),.mem_ready(mem_ready&&!normal_req),.writes_idle(raw_idle&&normal_idle&&memory_writes_idle),
 .whole_complete(raw_complete),.end_valid(raw_end_valid),.end_ready(raw_end_ready),.end_frame(raw_end_frame),.end_epoch(raw_end_epoch),.busy(raw_busy),.failed(raw_failed));
 // Acknowledge the actual registered lease admission, with matching identity.
 // This separates guard admission from BMP scaler control by one clock.
 assign raw_metadata_ready=monitor_begin&&raw_metadata_valid&&receive_frame==raw_metadata[`DB_MEDIA_WIRE_FRAME];
 assign raw_end_ready=end_ready;
 db_full_media_frame_guard #(.IDLE_TIMEOUT_CYCLES(200000000)) guard(.clk(mem_clk),.rst(main_rst),.session_start(session_start),.new_epoch(command_epoch),.session_cancel(dreset||!session_ready_mem),
  .abort_frame(row_failed||command_abort||raw_failed),.writes_idle(writes_idle),.hold_slots(hold_slots),
  .metadata_valid(begin_valid||(raw_metadata_valid&&!raw_metadata_ready)),.metadata_ready(begin_ready),.metadata(raw_metadata_valid?raw_metadata:command_meta),
  .whole_complete(raw_complete),.write_activity(raw_req&&mem_ready&&!normal_req),.row_valid(row_committed),.row_epoch(committed_epoch),.row_frame_id(committed_frame),.row_index(committed_row),.row_bytes(committed_length),.row_write_ok(1'b1),
  .end_valid(end_valid||raw_end_valid),.end_ready(end_ready),.end_epoch(raw_end_valid?raw_end_epoch:command_epoch),.end_frame_id(raw_end_valid?raw_end_frame:command_frame),.end_bytes(32'd614400),.end_rows(16'd480),
  .vblank_event(vblank_event),.present_allow(present_allow&&session_ready_mem),
  .receive_active(receive_active),.receive_slot(receive_slot),.receive_frame_id(receive_frame),.expected_row(expected_row),
  .pending_valid(pending_valid),.pending_slot(),.pending_frame_id(),.pending_metadata_valid(),.pending_metadata(),
  .display_valid(display_valid),.display_slot(display_slot),.display_frame_id(display_frame_id),.display_epoch(display_epoch),
  .display_metadata_valid(display_metadata_valid),.display_metadata(display_metadata),
  .quarantine_slots(quarantine_slots),.begin_accepted(monitor_begin),.frame_completed(monitor_complete),.frame_presented(monitor_present),.frame_rejected(),.rejected_count(),.timeout_count(),
  .metadata_rejected(),.rejected_metadata_count(metadata_errors),.asset_changed(asset_changed),.static_transition(static_transition),.dynamic_continuation(dynamic_continuation));
 assign transport_idle=row_src_idle&&!packet_valid&&!row_source_valid&&!cmd_valid&&cmd_ready;
 assign monitor_cancel=dreset;assign monitor_epoch=session_epoch;assign monitor_frame=receive_frame;assign monitor_slot=receive_slot;
endmodule

