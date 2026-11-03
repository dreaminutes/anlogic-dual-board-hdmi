// Sequential GIF87a/GIF89a parser and LZW pixel decoder.
// Disposal metadata is supplied to the canvas compositor, which must implement
// restore-to-background (2) and restore-to-previous (3) before the next frame.
// Application extensions, including infinite loop requests, are skipped: the
// caller chooses whether to replay the GIF after the trailer.
module db_opt_gif_decoder #(
    parameter MAX_WIDTH=1280, parameter MAX_HEIGHT=960
)(
    input wire clk, input wire rst, input wire start,
    input wire byte_valid, input wire [7:0] byte_data, output wire byte_ready,
    output reg header_valid, output reg [15:0] canvas_width, canvas_height,
    output reg [23:0] background_rgb,
    output reg frame_begin, output reg frame_done,
    output reg [15:0] frame_delay_cs,
    output reg [2:0] frame_disposal,
    output reg [15:0] frame_left, frame_top, frame_width, frame_height,
    output reg frame_transparent,
    output wire pixel_valid, input wire pixel_ready,
    output wire [15:0] pixel_x, pixel_y,
    output wire [23:0] pixel_rgb, output wire pixel_transparent,
    output reg done, output reg error, output reg [7:0] error_code
);
    localparam IDLE=0, SIGNATURE=1, SCREEN=2, GLOBAL_MAP=3, BLOCK=4,
        EXT_LABEL=5, SKIP_SIZE=6, SKIP_DATA=7, GCE_SIZE=8, GCE_DATA=9,
        GCE_END=10, IMAGE=11, LOCAL_MAP=12, MIN_CODE=13,
        DATA_SIZE=14, DATA_BYTES=15, FRAME_WAIT=16, ENDED=17, FAILED=18;
    reg [4:0] state;
    reg [3:0] field;
    reg [7:0] packed_screen, background_index, packed_image;
    reg [23:0] global_palette[0:255] /* fehdl force_ram=1, ram_style="bram" */;
    reg [23:0] local_palette[0:255] /* fehdl force_ram=1, ram_style="bram" */;
    reg [23:0] global_color_q,local_color_q;
    reg palette_ready;
    reg [8:0] palette_size, palette_index;
    reg [1:0] palette_component;
    reg [23:0] palette_color;
    reg [7:0] remaining;
    reg [15:0] gce_delay;
    reg [2:0] gce_disposal;
    reg gce_transparent;
    reg [7:0] gce_transparent_index, transparent_index;
    reg use_local, have_global, interlaced;
    reg [15:0] col, row;
    // Frame height is fixed while pixels stream. Precompute saturated limits
    // in IMAGE, avoiding row increment -> compare -> row mux on every pixel.
    // For unsigned 16-bit row/height, row+8<height iff row<max(height-8,0).
    // The original unsized addition compares without 16-bit wraparound.
    reg [15:0] row_limit8, row_limit4;
    reg [1:0] interlace_pass;
    reg [31:0] pixels_seen, pixels_expected;
    reg lzw_finished;
    wire lzw_ready, lzw_valid, lzw_done, lzw_error;
    wire [7:0] lzw_index;
    wire taking=byte_valid && byte_ready;
    wire lzw_start=state==MIN_CODE && taking;
    wire accepting_pixels=(state==DATA_SIZE || state==DATA_BYTES || state==FRAME_WAIT);
    assign byte_ready=(state==DATA_BYTES)?(lzw_finished ? 1'b1:lzw_ready):
        (state!=IDLE && state!=FRAME_WAIT && state!=ENDED && state!=FAILED);
    assign pixel_valid=lzw_valid && palette_ready && accepting_pixels && !error;
    assign pixel_x=frame_left+col;
    assign pixel_y=frame_top+row;
    assign pixel_rgb=use_local ? local_color_q : global_color_q;
    assign pixel_transparent=frame_transparent && lzw_index==transparent_index;
    db_opt_gif_lzw lzw(
        .clk(clk),.rst(rst),.start(lzw_start),.min_code_size(byte_data[3:0]),
        .byte_valid(byte_valid && state==DATA_BYTES && !lzw_finished),
        .byte_data(byte_data),.byte_ready(lzw_ready),
        .index_valid(lzw_valid),.index_data(lzw_index),
        .index_ready(pixel_ready && palette_ready && accepting_pixels),.done(lzw_done),.error(lzw_error)
    );
    // The LZW output is held until the synchronous palette lookup is valid.
    // Keep RAM ports outside reset/FSM logic so TD maps them into block RAM.
    always @(posedge clk) begin
        global_color_q<=global_palette[lzw_index];
        local_color_q<=local_palette[lzw_index];
        if(!rst&&!start&&taking&&palette_component==2)begin
            if(state==GLOBAL_MAP)global_palette[palette_index[7:0]]<={palette_color[23:8],byte_data};
            if(state==LOCAL_MAP)local_palette[palette_index[7:0]]<={palette_color[23:8],byte_data};
        end
        if(rst||start||!lzw_valid||!accepting_pixels)palette_ready<=0;
        else if(pixel_valid&&pixel_ready)palette_ready<=0;
        else palette_ready<=1;
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE; field<=0; header_valid<=0; frame_begin<=0; frame_done<=0;
            done<=0; error<=0; error_code<=0; canvas_width<=0; canvas_height<=0;
            frame_left<=0; frame_top<=0; frame_width<=0; frame_height<=0;
            frame_delay_cs<=0; frame_disposal<=0; frame_transparent<=0;
            background_rgb<=0; background_index<=0; packed_screen<=0;
            packed_image<=0; palette_size<=0; palette_index<=0;
            palette_component<=0; palette_color<=0; remaining<=0;
            gce_delay<=0; gce_disposal<=0; gce_transparent<=0;
            gce_transparent_index<=0; transparent_index<=0; have_global<=0;
            use_local<=0; interlaced<=0; col<=0; row<=0; interlace_pass<=0; row_limit8<=0; row_limit4<=0;
            pixels_seen<=0; pixels_expected<=0; lzw_finished<=0;
        end else begin
            header_valid<=0; frame_begin<=0; frame_done<=0; done<=0;
            if(start) begin
                state<=SIGNATURE; field<=0; error<=0; error_code<=0;
                gce_delay<=0; gce_disposal<=0; gce_transparent<=0;
                have_global<=0; use_local<=0; background_rgb<=0;
                pixels_seen<=0; lzw_finished<=0;
            end else if(lzw_error && accepting_pixels) begin
                error<=1; error_code<=8'h06; state<=FAILED;
            end else begin
                if(lzw_done) lzw_finished<=1;
                if(pixel_valid && pixel_ready) begin
                    if(pixels_seen>=pixels_expected) begin
                        error<=1; error_code<=8'h07; state<=FAILED;
                    end else begin
                        pixels_seen<=pixels_seen+1;
                        if(col+1<frame_width) col<=col+1;
                        else begin
                            col<=0;
                            if(!interlaced) row<=row+1;
                            else case(interlace_pass)
                                0: if(row<row_limit8) row<=row+8;
                                   else if(frame_height>4) begin row<=4; interlace_pass<=1; end
                                   else if(frame_height>2) begin row<=2; interlace_pass<=2; end
                                   else begin row<=1; interlace_pass<=3; end
                                1: if(row<row_limit8) row<=row+8;
                                   else if(frame_height>2) begin row<=2; interlace_pass<=2; end
                                   else begin row<=1; interlace_pass<=3; end
                                2: if(row<row_limit4) row<=row+4;
                                   else begin row<=1; interlace_pass<=3; end
                                3: row<=row+2;
                            endcase
                        end
                    end
                end
                if(taking) case(state)
                    SIGNATURE: begin
                        if((field==0 && byte_data!="G") ||
                           (field==1 && byte_data!="I") ||
                           (field==2 && byte_data!="F") ||
                           (field==3 && byte_data!="8") ||
                           (field==4 && byte_data!="7" && byte_data!="9") ||
                           (field==5 && byte_data!="a")) begin
                            error<=1; error_code<=8'h01; state<=FAILED;
                        end else if(field==5) begin field<=0; state<=SCREEN; end
                        else field<=field+1;
                    end
                    SCREEN: begin
                        case(field)
                            0: canvas_width[7:0]<=byte_data;
                            1: canvas_width[15:8]<=byte_data;
                            2: canvas_height[7:0]<=byte_data;
                            3: canvas_height[15:8]<=byte_data;
                            4: packed_screen<=byte_data;
                            5: background_index<=byte_data;
                            6: begin
                                if(canvas_width==0 || canvas_height==0 ||
                                   canvas_width>MAX_WIDTH || canvas_height>MAX_HEIGHT) begin
                                    error<=1; error_code<=8'h02; state<=FAILED;
                                end else if(packed_screen[7]) begin
                                    palette_size<=9'h002 << packed_screen[2:0];
                                    palette_index<=0; palette_component<=0;
                                    have_global<=1; state<=GLOBAL_MAP;
                                end else begin header_valid<=1; state<=BLOCK; end
                            end
                        endcase
                        if(field!=6) field<=field+1;
                    end
                    GLOBAL_MAP,LOCAL_MAP: begin
                        if(palette_component==0) palette_color[23:16]<=byte_data;
                        if(palette_component==1) palette_color[15:8]<=byte_data;
                        if(palette_component==2) begin
                            if(state==GLOBAL_MAP) begin
                                if(palette_index==background_index)
                                    background_rgb<={palette_color[23:8],byte_data};
                            end
                            palette_component<=0;
                            if(palette_index+1==palette_size) begin
                                if(state==GLOBAL_MAP) begin header_valid<=1; state<=BLOCK; end
                                else state<=MIN_CODE;
                            end else palette_index<=palette_index+1;
                        end else palette_component<=palette_component+1;
                    end
                    BLOCK: begin
                        if(byte_data==8'h21) state<=EXT_LABEL;
                        else if(byte_data==8'h2c) begin state<=IMAGE; field<=0; end
                        else if(byte_data==8'h3b) begin done<=1; state<=ENDED; end
                        else begin error<=1; error_code<=8'h03; state<=FAILED; end
                    end
                    EXT_LABEL: if(byte_data==8'hf9) state<=GCE_SIZE; else state<=SKIP_SIZE;
                    SKIP_SIZE: if(byte_data==0) state<=BLOCK;
                               else begin remaining<=byte_data; state<=SKIP_DATA; end
                    SKIP_DATA: if(remaining==1) state<=SKIP_SIZE; else remaining<=remaining-1;
                    GCE_SIZE: if(byte_data!=4) begin error<=1; error_code<=8'h04; state<=FAILED; end
                              else begin field<=0; state<=GCE_DATA; end
                    GCE_DATA: begin
                        case(field)
                            0: begin gce_disposal<=byte_data[4:2]; gce_transparent<=byte_data[0]; end
                            1: gce_delay[7:0]<=byte_data;
                            2: gce_delay[15:8]<=byte_data;
                            3: begin gce_transparent_index<=byte_data; state<=GCE_END; end
                        endcase
                        field<=field+1;
                    end
                    GCE_END: if(byte_data==0) state<=BLOCK;
                             else begin error<=1; error_code<=8'h04; state<=FAILED; end
                    IMAGE: begin
                        case(field)
                            0: frame_left[7:0]<=byte_data;
                            1: frame_left[15:8]<=byte_data;
                            2: frame_top[7:0]<=byte_data;
                            3: frame_top[15:8]<=byte_data;
                            4: frame_width[7:0]<=byte_data;
                            5: frame_width[15:8]<=byte_data;
                            6: frame_height[7:0]<=byte_data;
                            7: frame_height[15:8]<=byte_data;
                            8: begin
                                row_limit8 <= (frame_height>16'd8) ? frame_height-16'd8 : 16'd0;
                                row_limit4 <= (frame_height>16'd4) ? frame_height-16'd4 : 16'd0;
                                packed_image<=byte_data; use_local<=byte_data[7]; interlaced<=byte_data[6];
                                frame_delay_cs<=gce_delay; frame_disposal<=gce_disposal;
                                frame_transparent<=gce_transparent; transparent_index<=gce_transparent_index;
                                if(frame_width==0 || frame_height==0 ||
                                    {1'b0,frame_left}+frame_width>canvas_width ||
                                    {1'b0,frame_top}+frame_height>canvas_height ||
                                    (!byte_data[7] && !have_global)) begin
                                    error<=1; error_code<=8'h05; state<=FAILED;
                                end else if(byte_data[7]) begin
                                    palette_size<=9'h002 << byte_data[2:0]; palette_index<=0;
                                    palette_component<=0; state<=LOCAL_MAP;
                                end else state<=MIN_CODE;
                            end
                        endcase
                        if(field!=8) field<=field+1;
                    end
                    MIN_CODE: begin
                        if(byte_data<2 || byte_data>8) begin
                            error<=1; error_code<=8'h06; state<=FAILED;
                        end else begin
                            frame_begin<=1; col<=0; row<=0; interlace_pass<=0;
                            pixels_seen<=0; pixels_expected<=frame_width*frame_height;
                            lzw_finished<=0; state<=DATA_SIZE;
                        end
                    end
                    DATA_SIZE: begin
                        if(byte_data==0) state<=FRAME_WAIT;
                        else begin remaining<=byte_data; state<=DATA_BYTES; end
                    end
                    DATA_BYTES: if(remaining==1) state<=DATA_SIZE; else remaining<=remaining-1;
                endcase
                if(state==FRAME_WAIT && lzw_finished) begin
                    if(pixels_seen!=pixels_expected) begin
                        error<=1; error_code<=8'h07; state<=FAILED;
                    end else begin
                        frame_done<=1; state<=BLOCK;
                        gce_delay<=0; gce_disposal<=0; gce_transparent<=0;
                    end
                end else if(state==FRAME_WAIT && !lzw_finished && lzw_ready) begin
                    // A zero-sized data sub-block ended the compressed stream.
                    // Requesting another byte now means the GIF lacked an EOI.
                    error<=1; error_code<=8'h08; state<=FAILED;
                end
            end
        end
    end
endmodule
