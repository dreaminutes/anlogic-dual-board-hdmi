cd [file dirname [info script]]
file mkdir build
if {[catch {
 import_device eagle_s20.db -package EG4S20BG256
 import_db build/native_gate.db
 set_param place seed 74
 set_param place effort high
 set_param place opt_timing high
 set_param route effort routability
 set_param route post_route_opt high
 set_param route fix_hold high
 create_bound v10_dq22 -mode fixed -width 12 -height 20 -origin {1 8}
 add_cells_to_bound -verbose -bound v10_dq22 -cells {core/memory/data_reg[22]}
 place
 phys_opt -post_place -effort ultra
 export_db build/native_place.db
 route
 fix_hold
 export_db build/native_pr.db
 update_timing -mode final
 report_timing_summary -file build/timing.rpt
 report_timing_status -file build/timing_status.rpt
 check_timing -verbose -file build/coverage_checks.rpt
 report_timing_exception -file build/exceptions.rpt
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
