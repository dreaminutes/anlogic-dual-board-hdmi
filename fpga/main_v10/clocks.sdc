create_clock -name clk50 -period 20 [get_ports {clk}]
derive_clocks
# Low-speed cable inputs only enter the clk50 synchronizers.
set_false_path -from [get_ports {sw0 reserved[*] forward_clk link_valid link_data[*]}]
set_false_path -to [get_ports {led[*]}]
# Async return inputs on TX use three-stage synchronizers. This is a local
# one-period output arrival budget, not external synchronous setup timing.
set_output_delay -clock clk50 -max 0 [get_ports {credit_out command_out}]
set_output_delay -clock clk50 -min 0 [get_ports {credit_out command_out}]
# Startup/standby reset is static during a run. FIFO reset has local release
# guards; exceptions here apply only to reset/standby controls.
set_false_path -through [get_nets -hier {rst_start core/transport_reset core/receiver/input_reset core/framebuffer/fifo_reset}]
# Mechanical enable also gates only standby outputs/reset.
set_false_path -through [get_nets {enable}]

# New frame-tagged metadata mailbox: held until the video-domain blanking
# consumer acknowledges. Only coincident-edge cross-domain HOLD is excluded;
# data setup paths remain timed. Source/destination buffers were stall/flush tested.

# Capture FIFO Gray pointers cross only into their first synchronizer stage.
# Setup remains timed; coincident-edge hold is inapplicable to asynchronous CDC.
set_false_path -hold -through [get_nets -hier {core/receiver/capture/queue/wgray* core/receiver/capture/queue/overflow}] -to [get_clocks {clk50}]
set_false_path -hold -through [get_nets -hier {core/receiver/capture/queue/rgray*}] -to [get_clocks {vpll/pll_inst.clkc[2]}]
# Capture reset asserts asynchronously and releases through local synchronizers.
set_false_path -through [get_nets -hier {core/receiver/capture/sample_reset[2]}]

# Same immutable acknowledged194-bit bundle as existing raster metadata.
# Only coincident-edge cross-domain HOLD is excluded; setup remains timed.

# Same immutable acknowledged profile bundle;all setup stays timed.
set_false_path -from [get_ports {sw1}]
set_false_path -hold -through [get_nets -hier {core/audio_fifo/wgray*}] -to [get_clocks {vpll/pll_inst.clkc[0]}]
set_false_path -hold -through [get_nets -hier {core/audio_fifo/rgray*}] -to [get_clocks {clk50}]

set_false_path -from [get_ports {col[*] sw7}]
set_false_path -to [get_ports {row[*]}]
set_false_path -hold -through [get_nets -hier {panel/settings_transfer/held* panel/settings_transfer/request panel/status_transfer/held* panel/status_transfer/request}] -to [get_clocks {vpll/pll_inst.clkc[0]}]
set_false_path -hold -through [get_nets -hier {panel/settings_transfer/ack panel/status_transfer/ack}] -to [get_clocks {clk50}]

# New acknowledged playback/grant bundles and file FIFO. Only asynchronous
# coincident-edge hold checks are excluded; all data setup stays timed.
set_false_path -hold -through [get_nets -hier {core/playback_settings/held* core/playback_settings/request core/grant_to_control/ack core/receiver/engine/blob_fifo/wgray*}] -to [get_clocks {memory_pll/pll_inst.clkc[0]}]
set_false_path -hold -through [get_nets -hier {core/playback_settings/ack core/grant_to_control/held* core/grant_to_control/request core/receiver/engine/blob_fifo/rgray*}] -to [get_clocks {clk50}]

# Content-FPS immutable16-bit acknowledged bundle, mem->video. Setup remains timed.
set_false_path -hold -through [get_nets -hier {core/rate_to_video/held* core/rate_to_video/request}] -to [get_clocks {vpll/pll_inst.clkc[0]}]
set_false_path -hold -through [get_nets -hier {core/rate_to_video/ack}] -to [get_clocks {memory_pll/pll_inst.clkc[0]}]

# Game mode adds one asynchronous mechanical INPUT into the existing50MHz
# scanner. The immutable five-bit game/key bundle uses the same acknowledged
# transfer; only coincident-edge CDC hold is excepted, setup remains timed.
set_false_path -from [get_ports {sw6}]
set_false_path -hold -through [get_nets -hier {panel/game_transfer/held* panel/game_transfer/request}] -to [get_clocks {vpll/pll_inst.clkc[0]}]
set_false_path -hold -through [get_nets -hier {panel/game_transfer/ack}] -to [get_clocks {clk50}]

# Debounced asynchronous mechanical music input.
set_false_path -from [get_ports {sw5}]

# Acknowledged immutable audio control, word and playback-position bundles.
set_false_path -hold -through [get_nets -hier {core/audio_control_cdc/held* core/audio_control_cdc/request core/audio_response_cdc/held* core/audio_response_cdc/request core/audio_request_cdc/ack core/audio_position_cdc/ack}] -to [get_clocks {vpll/pll_inst.clkc[0]}]
set_false_path -hold -through [get_nets -hier {core/audio_control_cdc/ack core/audio_response_cdc/ack core/audio_request_cdc/held* core/audio_request_cdc/request core/audio_position_cdc/held* core/audio_position_cdc/request}] -to [get_clocks {memory_pll/pll_inst.clkc[0]}]

# The static SDRAM-initialized qualifier is used solely as transport reset.
# Match its bit explicitly: optimized aliases of transport_reset may disappear.
set init_reset_root [get_nets -hier {core/init_sync[2]}]
if {[llength $init_reset_root]!=1} {error {Missing unique transport initialization reset origin}}
set_false_path -through $init_reset_root

# Static memory-domain reset into the clk50 FIFO side has local release guards.
# Exclude only coincident-edge removal; recovery and all data paths stay timed.
set_false_path -hold -through [get_nets -hier {u_rs_mem/sync1}] -to [get_clocks {clk50}]

# The memory-startup reset crosses into the250MHz capture FIFO's local
# async-assert / synchronized-release guards. It is static during transfer.
set capture_reset_roots [get_nets -hier {u_rs_mem/sync0 u_rs_mem/sync1}]
if {[llength $capture_reset_roots]<1} {error {Missing memory startup reset roots}}
set_false_path -through $capture_reset_roots -to [get_clocks {vpll/pll_inst.clkc[2]}]

# Mechanical SW4 enters only the dedicated two-stage input synchronizer.
set_false_path -from [get_ports {sw4}]
