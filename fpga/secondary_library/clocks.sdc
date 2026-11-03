create_clock -name clk50 -period 20 [get_ports {clk}]
derive_clocks
# Mechanical switch and reserved level sensing only enter synchronizers.
set_false_path -from [get_ports {sw0 reserved[*]}]
# Human-visible LED outputs have no external synchronous receiver.
set_false_path -to [get_ports {led[*]}]
# Only the first stage of the four independent diagnostic level synchronizers.

# Test enable is an asynchronous reset / output-enable level, held static
# during a run. This does not cut packet data paths to the cable pads.
set_false_path -through [get_nets {enable}]
# Counter starts at zero: clk50 rising #2 toggles link high, #4 low,
# #6 high. SDC source edge numbering includes both polarities, so
# edges 3/7/11 encode +20ns/+60ns/+100ns from the first clk50 rise.
create_generated_clock -name link_internal -source [get_ports {clk}] -master_clock clk50 -edges {1 3 5} [get_nets {link_clk}]
create_generated_clock -name link_pad -source [get_nets {link_clk}] -master_clock link_internal -divide_by 1 [get_ports {forward_clk}]
# Receiver samples rising edge; transmitter launches falling edge. Conservative
# 30ns external setup/hold budget at the forwarded clock pad, 12.5MHz diagnostic only.
set_output_delay -clock link_pad -max 12 [get_ports {link_data[*] link_valid}]
set_output_delay -clock link_pad -min -12 [get_ports {link_data[*] link_valid}]
set_false_path -to [get_ports {forward_clk}]
set_false_path -from [get_ports {credit_in command_in}]
# Bundled-independent diagnostic levels enter only the first LED synchronizer;
# source nets are selected because native packing can rename the entry cell.
set_false_path -through [get_nets {echo_seen loaded card_initialized failed overflow}] -to [get_clocks {clk50}]
# Transport reset is held until enable; each output frame is immutable only during its lease.
set_false_path -through [get_nets -hier {rst_start tx_reset mem_rst loader/backend_reset read_bridge/sr[2] read_bridge/dr[2] read_bridge/control/sr[2] read_bridge/control/dr[2] loader/bridge/reset_request loader/bridge/fifo_reset_sd[1]}]
# Handshake bundles are held until completion. Only coincident-edge HOLD
# checks crossing domains are inapplicable; all setup paths remain timed.
# FIFO Gray pointers likewise enter their two-stage synchronizers.
set_false_path -hold -through [get_nets -hier {read_bridge/control/held_data* read_bridge/control/ack}] -to [get_clocks {link_internal}]
set_false_path -hold -through [get_nets -hier {read_bridge/control/held_address* read_bridge/control/request}] -to [get_clocks {memory_pll/pll_inst.clkc[0]}]
set_false_path -hold -through [get_nets -hier {loader/files/reader/sd_sec_read_addr* loader/files/reader/sd_sec_read loader/bridge/fifo/rgray*}] -to [get_clocks {sd_pll/pll_inst.clkc[0]}]
set_false_path -hold -through [get_nets -hier {loader/bridge/fifo/wgray* loader/init_committed loader/bridge/overflow}] -to [get_clocks {memory_pll/pll_inst.clkc[0]}]
# Propagate the actual50MHz clock through the physical SCK mux/pad.
# Card launches on falling SCK and captures CMD on rising SCK.
# Actual output delay is included by the generated pad clock; no assumed
# clock-flight bound is substituted for routed clock/pad propagation.
create_generated_clock -name sd_sck_pad -source [get_nets -hier {loader/backend/controller/fast_clk}] -master_clock {sd_pll/pll_inst.clkc[1]} -divide_by 1 -invert [get_ports {sd_dclk}]
set_input_delay -clock sd_sck_pad -clock_fall -max 15 [get_ports {sd_cmd sd_dat[*]}]
set_input_delay -clock sd_sck_pad -clock_fall -min 2.5 [get_ports {sd_cmd sd_dat[*]}]
# The selected input sample is26ns after launch; next data launches20ns
# later. Setup2 alone retains the real hold check at this late sample.
# A paired hold1 would wrongly move that hold check one full period earlier.
set_multicycle_path 2 -setup -from [get_ports {sd_cmd sd_dat[*]}] -to [get_clocks {sd_pll/pll_inst.clkc[2]}]
set_output_delay -clock sd_sck_pad -max 7 [get_ports {sd_cmd}]
set_output_delay -clock sd_sck_pad -min -3 [get_ports {sd_cmd}]
# SCK is a propagated clock endpoint,not a synchronous data output.
set_false_path -to [get_ports {sd_dclk}]
set_false_path -through [get_nets -hier {sd_reset reset_sd/sr* loader/backend_reset}]
# Terminal fault flag is synchronized; error code is held before3-stage
# flag crossing authorizes capture. Only coincident hold at receiving bank
# is inapplicable. All internal setup and other hold paths stay timed.
set_false_path -hold -through [get_nets -hier {loader/fault_seen loader/fault_code_hold*}] -to [get_clocks {memory_pll/pll_inst.clkc[0]}]

# Final seed31 SCK output arrival11.131ns+card14ns+PCB1ns=26.131ns.
# Round UP to26.25ns: stricter input setup requirement than parent26ns.
# Sample window remains30ns;minimum0/external hold/internal clocks unchanged.

# New count/LBA held together for entire legacysector request;setup stays timed.
set_false_path -hold -through [get_nets -hier {loader/files/reader/sd_sec_read_count*}] -to [get_clocks {sd_pll/pll_inst.clkc[0]}]

# Strict reanalysis: actual SCK arrival12.237ns + card14ns + PCB1ns =27.237ns.
# Round up to28ns; selected sample remains30ns, min0 and real hold retained.

# Registered diagnostic-only error level into the first LED synchronizer.
# Its packed entry name may differ from diag0; media/control paths stay timed.
set_false_path -through [get_nets {mem_error_status sender_failed}] -to [get_clocks {clk50}]

# Whole-sector scheduler holds address/count/owner until CDC completion.
set_false_path -hold -through [get_nets -hier {loader/scheduler/lba* loader/scheduler/count* loader/scheduler/audio loader/scheduler/request}] -to [get_clocks {sd_pll/pll_inst.clkc[0]}]
set_false_path -hold -through [get_nets -hier {audio_fifo/wgray*}] -to [get_clocks {link_internal}]
set_false_path -hold -through [get_nets -hier {audio_fifo/rgray*}] -to [get_clocks {memory_pll/pll_inst.clkc[0]}]

# Absolute song state is held and sampled through three memory-domain stages.


# BMP file FIFO and acknowledged full playback bundles retain immutable data
# through request/ack. All setup checks stay timed.
set_false_path -hold -through [get_nets -hier {file_fifo/wgray* control_to_link/held* control_to_link/request}] -to [get_clocks {link_internal}]
set_false_path -hold -through [get_nets -hier {file_fifo/rgray* control_to_memory/held* control_to_memory/request}] -to [get_clocks {memory_pll/pll_inst.clkc[0]}]
set_false_path -hold -through [get_nets -hier {control_to_memory/ack control_to_link/ack}] -to [get_clocks {clk50}]
# File sender terminal fault goes only into the first LED diagnostic bank.
set_false_path -through [get_nets {file_failed}] -to [get_clocks {clk50}]

# CMD data/OE update only on falling50MHz SCK,not on alternate100MHz edges.
# Unit regression asserts this temporal property across all HS read/fault corners.
# Move only the qualified OUTPUT hold launch by one100MHz cycle; real SD
# input setup/hold and every ordinary internal path retain their checks.
set_multicycle_path 1 -hold -start -from [get_clocks {sd_pll/pll_inst.clkc[0]}] -to [get_ports {sd_cmd}]
# Terminal fault asynchronously releases the CMD driver through its reset.
set_false_path -through [get_nets -hier {loader/backend/controller/command_reset}]

# HELLO-only protocol reset; actual byte/CRC data paths retain all checks.
set_false_path -through [get_nets -hier {transport/link/rst}]
