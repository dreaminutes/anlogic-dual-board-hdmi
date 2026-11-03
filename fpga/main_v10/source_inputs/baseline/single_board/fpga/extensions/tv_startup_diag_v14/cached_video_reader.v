`timescale 1ns/1ps
// BMP: 640x480 RGB565 -> 640x480, each source pixel once.
// GIF landscape: 320x240 -> 640x480, repeating each pixel/row twice.
// Portrait: 180x320 RGB565 -> centered 270x480, nearest-neighbor 3:2;
// x=185..454, source x=floor((x-185)*2/3), source y=floor(y*2/3).
// Every word stores the left/even pixel in low16. Portrait slots still have
// a 38400-word stride, but only their first 28800 words contain image data.
// frame_toggle MUST toggle at the start of vertical blank. Base and layout
// are captured together in mem_clk; the captured layout crosses to video_clk
// and settles during vertical blank before being frozen at the active frame.
// Old outstanding reads are drained before the FIFO starts a new frame.
// An active-region FIFO underflow discards the rest of that video frame;
// consuming again mid-frame would shift subsequent pixels after a missed pop.
module cached_video_reader (
    input wire mem_clk, input wire video_clk,
    input wire mem_rst, input wire video_rst,
    input wire frame_toggle, input wire video_de,
    input wire display_valid, input wire [20:0] display_base,
    input wire display_portrait, input wire display_native_still,
    input wire read_protect_enable,output reg [20:0] render_base,
    output reg [23:0] rgb, output reg committed, output reg underflow,
    output reg [15:0] underflow_count,
    output reg [15:0] read_mismatch_count,
    output wire mem_req, output wire [20:0] mem_addr,
    input wire mem_ready, input wire mem_rvalid, input wire [31:0] mem_rdata
);
    reg [2:0] frame_sync;
    reg [3:0] clear_count, pending;
    reg reading;
    reg [17:0] issued_words;
    reg [8:0] row_word;
    reg [8:0] out_row;
    reg [1:0] portrait_row_phase;
    reg frame_portrait, frame_protect, frame_native;
    reg [1:0] request_sample, response_sample;
    reg [3:0] reserved_words;
    reg [31:0] sample0, sample1;
    reg [20:0] next_addr;
    wire frame_event = frame_sync[2] != frame_sync[1];
    wire fifo_reset = mem_rst || video_rst || clear_count != 0 || !reading;
    wire fifo_empty, fifo_full;
    wire [8:0] fifo_used;
    wire [31:0] fifo_data;
    // Reserve FIFO space for a logical word on its FIRST accepted sample.
    // Physical pending counts all SDRAM reads; reserved_words counts complete
    // logical results still expected, including a partially issued triplet.
    wire [9:0] occupied = {1'b0, fifo_used} + {6'd0, reserved_words};
    reg [1:0] phase;
    reg [9:0] video_x;
    reg portrait0, portrait1, active_portrait, layout_armed;
    reg native0, native1, active_native;
    reg frame_discard;
    // Case equality gives unconnected/X/Z mode inputs a landscape fallback in
    // simulation; physical hardware mode inputs are ordinary 0/1 signals.
    wire requested_native = (display_native_still === 1'b1);
    wire requested_portrait = (display_portrait === 1'b1) && !requested_native;
    wire requested_protect = (read_protect_enable === 1'b1);
    wire pixel_region = video_de && (!active_portrait ||
        (video_x >= 10'd185 && video_x < 10'd455));
    wire word_last_pixel = active_native ? phase == 1 : (active_portrait ? phase == 2 : phase == 3);
    wire fifo_pop = pixel_region && committed && !frame_discard &&
        word_last_pixel && !fifo_empty;
    wire accept = mem_req && mem_ready;
    wire last_sample = !frame_protect || request_sample == 2;
    wire reserve_word = accept && (!frame_protect || request_sample == 0);
    wire current_response = mem_rvalid && reading && clear_count == 0 && !frame_event;
    wire fifo_push = current_response && (!frame_protect || response_sample == 2);
    wire [31:0] majority_data = (sample0 & sample1) |
        (sample0 & mem_rdata) | (sample1 & mem_rdata);
    wire [31:0] fifo_input = frame_protect ? majority_data : mem_rdata;
    wire [15:0] pixel565 = (active_native ? phase[0] : phase[1]) ? fifo_data[31:16] : fifo_data[15:0];
    wire last_row_word = frame_native ? row_word == 319 : (frame_portrait ? row_word == 89 : row_word == 159);
    wire [17:0] frame_read_words = frame_native ? 18'd153600 : (frame_portrait ? 18'd43200 : 18'd76800);
    assign mem_addr = next_addr;
    assign mem_req = reading && clear_count == 0 && !frame_event &&
        issued_words < frame_read_words && pending < 8 &&
        (occupied < 480 || (frame_protect && request_sample != 0));
    photo_read_fifo fifo(.rst(fifo_reset), .clkw(mem_clk), .clkr(video_clk),
        .we(fifo_push), .re(fifo_pop), .di(fifo_input), .dout(fifo_data),
        .empty_flag(fifo_empty), .full_flag(fifo_full), .wrusedw(fifo_used));

    always @(posedge mem_clk or posedge mem_rst) begin
        if (mem_rst) begin
            render_base<=0;frame_sync <= 0; clear_count <= 0; pending <= 0; reading <= 0;
            issued_words <= 0; row_word <= 0; out_row <= 0; next_addr <= 0;
            portrait_row_phase <= 0; frame_portrait <= 0; frame_protect <= 0; frame_native <= 0;
            request_sample <= 0; response_sample <= 0; reserved_words <= 0;
            sample0 <= 0; sample1 <= 0; read_mismatch_count <= 0;
        end else begin
            frame_sync <= {frame_sync[1:0], frame_toggle};
            case ({accept, mem_rvalid})
                2'b10: pending <= pending + 1'b1;
                2'b01: if (pending != 0) pending <= pending - 1'b1;
                default: pending <= pending;
            endcase
            if (current_response && frame_protect) begin
                case (response_sample)
                    0: begin sample0 <= mem_rdata; response_sample <= 1; end
                    1: begin sample1 <= mem_rdata; response_sample <= 2; end
                    default: begin
                        response_sample <= 0;
                        if ((sample0 != sample1 || sample1 != mem_rdata) &&
                            read_mismatch_count != 16'hffff)
                            read_mismatch_count <= read_mismatch_count + 1'b1;
                    end
                endcase
            end
            case ({reserve_word, fifo_push})
                2'b10: reserved_words <= reserved_words + 1'b1;
                2'b01: if (reserved_words != 0) reserved_words <= reserved_words - 1'b1;
                default: reserved_words <= reserved_words;
            endcase
            if (frame_event) begin
                clear_count <= 8; reading <= 0;
                issued_words <= 0; row_word <= 0; out_row <= 0;
                next_addr <= display_base;render_base<=display_base;
                frame_portrait <= requested_portrait; frame_native <= requested_native;
                // CAS3 is retained. Full resolution needs one read/word:
                // 3 x 153600 x 59.52 exceeds the 25 MHz SDRAM command budget.
                frame_protect <= requested_protect && !requested_native;
                portrait_row_phase <= 0; request_sample <= 0;
                response_sample <= 0; reserved_words <= 0;
            end else if (clear_count != 0) begin
                clear_count <= clear_count - 1'b1;
                // Continue holding reset until every old response has drained.
                if (clear_count == 1 && pending != 0) clear_count <= 1;
                else if (clear_count == 1) reading <= display_valid;
            end else if (accept) begin
                request_sample <= frame_protect && request_sample != 2
                    ? request_sample + 1'b1 : 2'd0;
                if (last_sample) begin
                issued_words <= issued_words + 1'b1;
                if (last_row_word) begin
                    row_word <= 0; out_row <= out_row + 1'b1;
                    if (frame_native) next_addr <= next_addr + 1'b1;
                    else if (frame_portrait) begin
                        // Output row groups 0,1,2 read source rows 0,0,1;
                        // the next group reads 2,2,3, and so on.
                        next_addr <= portrait_row_phase == 0
                            ? next_addr - 21'd89 : next_addr + 1'b1;
                        portrait_row_phase <= portrait_row_phase == 2
                            ? 2'd0 : portrait_row_phase + 1'b1;
                    end else begin
                        next_addr <= out_row[0] ? next_addr + 1'b1 : next_addr - 21'd159;
                    end
                end else begin row_word <= row_word + 1'b1; next_addr <= next_addr + 1'b1; end
                end
            end
        end
    end
    reg valid0, valid1, frame_previous;
    always @(posedge video_clk or posedge video_rst) begin
        if (video_rst) begin
            rgb <= 0; committed <= 0; underflow <= 0; underflow_count <= 0; phase <= 0;
            valid0 <= 0; valid1 <= 0; frame_previous <= 0;
            video_x <= 0; portrait0 <= 0; portrait1 <= 0;
            native0 <= 0; native1 <= 0; active_native <= 0;
            active_portrait <= 0; layout_armed <= 0; frame_discard <= 0;
        end else begin
            valid0 <= display_valid; valid1 <= valid0; frame_previous <= frame_toggle;
            portrait0 <= frame_portrait; portrait1 <= portrait0;
            native0 <= frame_native; native1 <= native0;
            if (frame_previous != frame_toggle) begin
                committed <= valid1; phase <= 0; video_x <= 0;
                frame_discard <= 0; layout_armed <= 1;
            end else begin
                if (!video_de) begin
                    video_x <= 0; phase <= 0;
                    // Keep sampling only during the opening vertical blank.
                    // Do not allow a later horizontal blank to change layout.
                    if (layout_armed) begin active_portrait <= portrait1; active_native <= native1; end
                end else begin
                    layout_armed <= 0;
                    if (video_x < 10'd639) video_x <= video_x + 1'b1;
                    if (!pixel_region) phase <= 0;
                    else if (committed && !frame_discard && !fifo_empty)
                        phase <= word_last_pixel ? 2'd0 : phase + 1'b1;
                end
                if (pixel_region && committed && !frame_discard && fifo_empty) begin
                    frame_discard <= 1; underflow <= 1;
                    if (underflow_count != 16'hffff) underflow_count <= underflow_count + 1'b1;
                end
            end
            rgb <= (pixel_region && committed && !frame_discard && !fifo_empty)
                ? {pixel565[15:11], pixel565[15:13], pixel565[10:5],
                   pixel565[10:9], pixel565[4:0], pixel565[4:2]} : 24'd0;
        end
    end
endmodule
