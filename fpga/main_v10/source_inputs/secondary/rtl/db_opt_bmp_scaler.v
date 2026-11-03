// Small BMPs use exact 4x/2x pixel replication, centered in the output.
// Bounded internal geometry for validated 1..4096 sources and 640x480 output.
// Raster-stream BMP scaler.  Only two horizontally scaled RGB888 rows are
// retained, so the source canvas never occupies SDRAM.  Pixels arrive in BMP
// file-row order; pixel_y is the normalized (top-to-bottom) source coordinate.
// The cache is a real 640x480 RGB565 framebuffer, low halfword first.
//
// Geometry and align-corners steps use Q16.  Interpolation uses the upper eight
// fractional bits and rounds each RGB888 separable pass to nearest.  A fitted
// dimension of one samples the source midpoint; a source dimension of one is
// repeated.  Metadata is latched at start.  ready may stall between any pixels.
// done pulses only after every source pixel and target write has completed.
module db_opt_bmp_scaler (
    input wire clk, input wire rst, input wire start,
    input wire [15:0] src_width, input wire [15:0] src_height,
    input wire top_down, input wire [20:0] target_base,
    input wire pixel_valid, output wire pixel_ready,
    input wire [15:0] pixel_x, input wire [15:0] pixel_y,
    input wire [23:0] pixel_rgb,
    output reg busy, output reg done, output reg error,
    output reg [7:0] error_code,
    output wire mem_req, output wire mem_write,
    output wire [20:0] mem_addr, output wire [31:0] mem_wdata,
    input wire mem_ready
);
    localparam [5:0] IDLE=0, GEOM_START=1, GEOM_WAIT=2,
        X_START=3, X_WAIT=4, Y_START=5, Y_WAIT=6, INIT=7,
        CLEAR=8, INGEST=9, H_MUL=10, H_STORE=11, H_NEXT=12,
        ROW_DONE=13, NEXT_ROW=14, EMIT_SETUP=15, V_PREP=16,
        V_READ=17, V_MUL=18, V_STORE=19, PACK=20, WRITE=21,
        OUT_ADVANCE=22, Y_ADVANCE=23, Y_NEXT=24, FINISH=25, H_PRODUCT=26,H_SUM=27,V_PRODUCT=28,V_SUM=29;
    localparam [7:0] ERR_DIMENSION=8'd1, ERR_TARGET_RANGE=8'd2,
        ERR_RASTER=8'd3, ERR_INTERNAL=8'd4;

    reg [5:0] state;
    reg [12:0] sw, sh;
    reg [9:0] fit_w, off_x;
    reg [8:0] fit_h, off_y;
    reg source_top_down;
    // Limit tiny images to 4x. Larger low-resolution images use exact 2x.
    // Other sizes retain the established RGB888 bilinear aspect-fit path.
    reg [1:0] small_shift;
    wire small_mode = |small_shift;
    reg [20:0] dst_base, bus_addr, row_word_base;
    reg [31:0] bus_wdata;
    reg [17:0] clear_index;
    reg [12:0] file_row, input_x, accepted_x;
    reg [9:0] hx, dy, out_x;
    reg row_h_done;
    reg [23:0] previous_pixel, current_pixel;
    reg [27:0] phase_x, phase_y, step_x, step_y;
    reg [16:0] hred, hgreen, hblue, vred, vgreen, vblue;
    reg [7:0] frac_y;
    reg bank_y0, bank_y1;
    reg [15:0] output_pixel, pending_low;

    // Two 640x24 synchronous-read RAMs.  Neither RAM contents nor their read
    // outputs are reset; all addresses needed by a row are written first.
    reg [23:0] line0 [0:639] /* fehdl force_ram=1, ram_style="bram" */;
    reg [23:0] line1 [0:639] /* fehdl force_ram=1, ram_style="bram" */;
    reg [23:0] line0_q, line1_q;
    reg [9:0] line_read_addr;
    always @(posedge clk) begin
        if (state == H_STORE) begin
            if (file_row[0]) line1[hx] <= {hred[15:8], hgreen[15:8], hblue[15:8]};
            else line0[hx] <= {hred[15:8], hgreen[15:8], hblue[15:8]};
        end
        if (state == V_READ) begin
            line0_q <= line0[line_read_addr];
            line1_q <= line1[line_read_addr];
        end
    end

    reg div_start;
    reg [31:0] div_num, div_den;
    wire div_done;
    wire [31:0] div_q;
    bmp_stream_divider divider(.clk(clk), .rst(rst), .start(div_start),
        .numerator(div_num), .denominator(div_den), .busy(),
        .done(div_done), .quotient(div_q));

    wire width_limited = sw * 32'd480 >= sh * 32'd640;
    wire [21:0] target_end = {1'b0, target_base} + 22'd153600;
    wire [27:0] initial_x = fit_w == 1 ? (({19'd0,sw}-1) << 15) : 0;
    wire [27:0] initial_y = fit_h == 1 ? (({19'd0,sh}-1) << 15) : 0;
    // Correct accumulated divider truncation at the last destination sample.
    wire [9:0] small_x = small_shift[1] ? {2'b0,hx[9:2]} : {1'b0,hx[9:1]};
    wire [9:0] small_y = small_shift[1] ? {2'b0,dy[9:2]} : {1'b0,dy[9:1]};
    wire [27:0] sample_x = small_mode ? {2'b0,small_x,16'd0} : (fit_w > 1 && hx == fit_w-1)
        ? (({19'd0,sw}-1) << 16) : phase_x;
    wire [27:0] sample_y = small_mode ? {2'b0,small_y,16'd0} : (fit_h > 1 && dy == fit_h-1)
        ? (({19'd0,sh}-1) << 16) : phase_y;
    wire [15:0] need_x0 = sample_x[27:16];
    wire [15:0] need_x1 = !small_mode && need_x0 < sw-1 ? need_x0+1'b1 : need_x0;
    wire [15:0] need_y0 = sample_y[27:16];
    wire [15:0] need_y1 = !small_mode && need_y0 < sh-1 ? need_y0+1'b1 : need_y0;
    wire [8:0] wx1 = {1'b0,sample_x[15:8]};
    wire [8:0] wx0 = 9'd256-wx1;
    wire [8:0] wy1 = {1'b0,frac_y};
    wire [8:0] wy0 = 9'd256-wy1;
    wire [23:0] horizontal_left = need_x0 == need_x1 ? current_pixel : previous_pixel;
    wire [23:0] vertical_top = bank_y0 ? line1_q : line0_q;
    wire [23:0] vertical_bottom = bank_y1 ? line1_q : line0_q;
    // Horizontal and vertical passes never overlap. Share one RGB multiplier
    // bank and use a*256 + (b-a)*w instead of two weighted products. Widen the
    // signed difference before multiplying; rounding remains exactly +128.
    wire [23:0] blend_a = state == H_MUL ? horizontal_left : vertical_top;
    wire [23:0] blend_b = state == H_MUL ? current_pixel : vertical_bottom;
    wire [7:0] blend_weight = state == H_MUL ? sample_x[15:8] : frac_y;
    wire signed [8:0] blend_dr = $signed({1'b0,blend_b[23:16]}) - $signed({1'b0,blend_a[23:16]});
    wire signed [8:0] blend_dg = $signed({1'b0,blend_b[15:8]}) - $signed({1'b0,blend_a[15:8]});
    wire signed [8:0] blend_db = $signed({1'b0,blend_b[7:0]}) - $signed({1'b0,blend_a[7:0]});
    reg[23:0]blend_base_r;
    reg signed[8:0]blend_dr_r,blend_dg_r,blend_db_r;
    reg[7:0]blend_weight_r;
    (* dsp_style="yes" *)reg signed[17:0]blend_pr,blend_pg,blend_pb;
    wire signed[17:0]blend_r=$signed({2'b0,blend_base_r[23:16],8'b0})+blend_pr+18'sd128;
    wire signed[17:0]blend_g=$signed({2'b0,blend_base_r[15:8],8'b0})+blend_pg+18'sd128;
    wire signed[17:0]blend_b_result=$signed({2'b0,blend_base_r[7:0],8'b0})+blend_pb+18'sd128;
    always@(posedge clk)begin
      if(rst)begin blend_base_r<=0;blend_dr_r<=0;blend_dg_r<=0;blend_db_r<=0;blend_weight_r<=0;blend_pr<=0;blend_pg<=0;blend_pb<=0;end
      else begin
       if(state==H_MUL||state==V_MUL)begin
        blend_base_r<=blend_a;blend_dr_r<=blend_dr;blend_dg_r<=blend_dg;blend_db_r<=blend_db;blend_weight_r<=blend_weight;
       end
       if(state==H_PRODUCT||state==V_PRODUCT)begin
        blend_pr<=blend_dr_r*$signed({1'b0,blend_weight_r});
        blend_pg<=blend_dg_r*$signed({1'b0,blend_weight_r});
        blend_pb<=blend_db_r*$signed({1'b0,blend_weight_r});
       end
      end
    end
    wire [15:0] expected_y = source_top_down ? file_row : sh-1-file_row;
    wire [15:0] dest_y = off_y + (source_top_down ? {6'd0,dy} : fit_h-1-dy);

    assign pixel_ready = state == INGEST;
    assign mem_req = state == CLEAR || state == WRITE;
    assign mem_write = mem_req;
    assign mem_addr = state == CLEAR ? dst_base+clear_index : bus_addr;
    assign mem_wdata = state == CLEAR ? 32'd0 : bus_wdata;

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE; busy <= 0; done <= 0; error <= 0; error_code <= 0;
            sw <= 0; sh <= 0; fit_w <= 0; fit_h <= 0; off_x <= 0; off_y <= 0;
            source_top_down <= 0; small_shift <= 0; dst_base <= 0; bus_addr <= 0;
            row_word_base <= 0; bus_wdata <= 0; clear_index <= 0;
            file_row <= 0; input_x <= 0; accepted_x <= 0;
            hx <= 0; dy <= 0; out_x <= 0; row_h_done <= 0;
            previous_pixel <= 0; current_pixel <= 0;
            phase_x <= 0; phase_y <= 0; step_x <= 0; step_y <= 0;
            hred <= 0; hgreen <= 0; hblue <= 0;
            vred <= 0; vgreen <= 0; vblue <= 0;
            frac_y <= 0; bank_y0 <= 0; bank_y1 <= 0;
            output_pixel <= 0; pending_low <= 0; line_read_addr <= 0;
            div_start <= 0; div_num <= 0; div_den <= 1;
        end else begin
            done <= 0;
            div_start <= 0;
            case (state)
                IDLE: if (start) begin
                    error <= 0; error_code <= 0;
                    if (src_width == 0 || src_height == 0 ||
                        src_width > 4096 || src_height > 4096) begin
                        busy <= 0; error <= 1; error_code <= ERR_DIMENSION; done <= 1;
                    end else if (target_end > 22'd2097152) begin
                        busy <= 0; error <= 1; error_code <= ERR_TARGET_RANGE; done <= 1;
                    end else begin
                        sw <= src_width; sh <= src_height;
                        if (src_width <= 160 && src_height <= 120) small_shift <= 2;
                        else if (src_width <= 320 && src_height <= 240) small_shift <= 1;
                        else small_shift <= 0;
                        source_top_down <= top_down; dst_base <= target_base;
                        busy <= 1; state <= GEOM_START;
                    end
                end
                GEOM_START: begin
                    if (small_mode) begin
                        fit_w <= small_shift[1] ? {sw[7:0],2'b0} : {sw[8:0],1'b0};
                        fit_h <= small_shift[1] ? {sh[6:0],2'b0} : {sh[7:0],1'b0};
                        step_x <= 0; step_y <= 0; state <= INIT;
                    end else begin
                    if (width_limited) begin
                        fit_w <= 640; div_num <= sh*32'd640; div_den <= sw;
                    end else begin
                        fit_h <= 480; div_num <= sw*32'd480; div_den <= sh;
                    end
                    div_start <= 1; state <= GEOM_WAIT;
                    end
                end
                GEOM_WAIT: if (div_done) begin
                    if (width_limited) fit_h <= div_q == 0 ? 16'd1 : div_q[15:0];
                    else fit_w <= div_q == 0 ? 16'd1 : div_q[15:0];
                    state <= X_START;
                end
                X_START: begin
                    if (fit_w == 1) begin step_x <= 0; state <= Y_START; end
                    else begin
                        div_num <= ({19'd0,sw}-1) << 16; div_den <= fit_w-1;
                        div_start <= 1; state <= X_WAIT;
                    end
                end
                X_WAIT: if (div_done) begin step_x <= div_q; state <= Y_START; end
                Y_START: begin
                    if (fit_h == 1) begin step_y <= 0; state <= INIT; end
                    else begin
                        div_num <= ({19'd0,sh}-1) << 16; div_den <= fit_h-1;
                        div_start <= 1; state <= Y_WAIT;
                    end
                end
                Y_WAIT: if (div_done) begin step_y <= div_q; state <= INIT; end
                INIT: begin
                    off_x <= (640-fit_w) >> 1; off_y <= (480-fit_h) >> 1;
                    hx <= 0; dy <= 0; file_row <= 0; input_x <= 0; accepted_x <= 0;
                    row_h_done <= 0; previous_pixel <= 0; current_pixel <= 0;
                    phase_x <= initial_x; phase_y <= initial_y;
                    clear_index <= 0; state <= CLEAR;
                end
                CLEAR: if (mem_ready) begin
                    if (clear_index == 18'd153599) state <= INGEST;
                    else clear_index <= clear_index+1'b1;
                end
                INGEST: if (pixel_valid) begin
                    if (pixel_x != input_x || pixel_y != expected_y) begin
                        busy <= 0; error <= 1; error_code <= ERR_RASTER;
                        done <= 1; state <= IDLE;
                    end else begin
                        previous_pixel <= current_pixel; current_pixel <= pixel_rgb;
                        accepted_x <= input_x;
                        input_x <= input_x == sw-1 ? 16'd0 : input_x+1'b1;
                        if (!row_h_done && input_x == need_x1) state <= H_MUL;
                        else if (input_x == sw-1) state <= ROW_DONE;
                    end
                end
                H_MUL:state<=H_PRODUCT;
                H_PRODUCT:state<=H_SUM;
                H_SUM: begin
                    hred <= blend_r[16:0];
                    hgreen <= blend_g[16:0];
                    hblue <= blend_b_result[16:0];
                    state <= H_STORE;
                end
                H_STORE: begin
                    if (hx == fit_w-1) begin
                        row_h_done <= 1;
                        state <= accepted_x == sw-1 ? ROW_DONE : INGEST;
                    end else begin
                        hx <= hx+1'b1; phase_x <= phase_x+step_x; state <= H_NEXT;
                    end
                end
                H_NEXT: begin
                    if (need_x1 == accepted_x) state <= H_MUL;
                    else state <= INGEST;
                end
                ROW_DONE: begin
                    if (dy < fit_h && file_row == need_y1) state <= EMIT_SETUP;
                    else if (file_row == sh-1) begin
                        if (dy == fit_h) state <= FINISH;
                        else begin
                            busy <= 0; error <= 1; error_code <= ERR_INTERNAL;
                            done <= 1; state <= IDLE;
                        end
                    end else state <= NEXT_ROW;
                end
                NEXT_ROW: begin
                    file_row <= file_row+1'b1; input_x <= 0;
                    hx <= 0; phase_x <= initial_x; row_h_done <= dy == fit_h;
                    state <= INGEST;
                end
                EMIT_SETUP: begin
                    out_x <= 0; frac_y <= sample_y[15:8];
                    bank_y0 <= need_y0[0]; bank_y1 <= need_y1[0];
                    row_word_base <= dst_base+dest_y*21'd320;
                    state <= V_PREP;
                end
                V_PREP: begin
                    if (out_x < off_x || out_x >= off_x+fit_w) begin
                        output_pixel <= 0; state <= PACK;
                    end else begin
                        line_read_addr <= out_x-off_x; state <= V_READ;
                    end
                end
                V_READ: state <= V_MUL;
                V_MUL:state<=V_PRODUCT;
                V_PRODUCT:state<=V_SUM;
                V_SUM: begin
                    vred <= blend_r[16:0];
                    vgreen <= blend_g[16:0];
                    vblue <= blend_b_result[16:0];
                    state <= V_STORE;
                end
                V_STORE: begin
                    output_pixel <= {vred[15:11],vgreen[15:10],vblue[15:11]};
                    state <= PACK;
                end
                PACK: begin
                    if (!out_x[0]) begin
                        pending_low <= output_pixel; state <= OUT_ADVANCE;
                    end else begin
                        bus_addr <= row_word_base+{12'd0,out_x[9:1]};
                        bus_wdata <= {output_pixel,pending_low}; state <= WRITE;
                    end
                end
                WRITE: if (mem_ready) state <= OUT_ADVANCE;
                OUT_ADVANCE: begin
                    if (out_x == 639) state <= Y_ADVANCE;
                    else begin out_x <= out_x+1'b1; state <= V_PREP; end
                end
                Y_ADVANCE: begin
                    dy <= dy+1'b1; phase_y <= phase_y+step_y;
                    state <= Y_NEXT;
                end
                Y_NEXT: begin
                    if (dy < fit_h && file_row == need_y1) state <= EMIT_SETUP;
                    else if (file_row == sh-1) begin
                        if (dy == fit_h) state <= FINISH;
                        else begin
                            busy <= 0; error <= 1; error_code <= ERR_INTERNAL;
                            done <= 1; state <= IDLE;
                        end
                    end else state <= NEXT_ROW;
                end
                FINISH: begin busy <= 0; done <= 1; state <= IDLE; end
                default: begin
                    busy <= 0; error <= 1; error_code <= ERR_INTERNAL;
                    done <= 1; state <= IDLE;
                end
            endcase
        end
    end
endmodule
