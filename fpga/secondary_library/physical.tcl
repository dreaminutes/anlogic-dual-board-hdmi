cd [file dirname [info script]]
file mkdir build
if {[catch {
 import_device eagle_s20.db -package EG4S20BG256
import_db build/native_gate.db
read_adc placement.adc
 set_param place seed 31
 set_param place effort high
 set_param place opt_timing high
 set_param route effort high
 set_param route post_route_opt high
 place
 export_db build/native_place.db
 route
 fix_hold
 export_db build/native_pr.db
 update_timing -mode final
 report_timing_summary -file build/timing.rpt
 report_timing_status -file build/timing_status.rpt
 report_timing_path -from [get_ports {sd_cmd sd_dat[*]}] -path_num 300 -ep_num 300 -file build/sd_input_paths.rpt
 report_timing_path -to [get_ports {sd_dclk}] -path_num 30 -ep_num 30 -file build/sd_clock_output.rpt
 report_timing_path -to [get_ports {sd_cmd}] -path_num 30 -ep_num 30 -file build/sd_command_output.rpt
 report_timing_path -from [get_pins {sd_pll/pll_inst.clkc[1]}] -to [get_ports {sd_dclk}] -path_num 10 -ep_num 10 -file build/sd_fast_clock_flight.rpt
 report_timing_exception -file build/exceptions.rpt
 check_timing -verbose -file build/coverage_checks.rpt
 report_clock_utilization -file build/clocks.rpt
 report_route_status -drc -file build/drc.rpt
 report_area
 write_verilog build/final_physical.v
 puts {PACKAGE_PHYSICAL_COMPLETE}
} message]} {
 puts "PACKAGE_BUILD_FAILED: $message"
 exit 1
}
exit 0
