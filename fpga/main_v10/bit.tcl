cd [file dirname [info script]]
file mkdir build
if {[catch {
 import_device eagle_s20.db -package EG4S20BG256
import_db build/native_pr.db
update_timing -mode final
report_timing_status -file build/bit_timing_status.rpt
set f [open build/bit_timing_status.rpt r]
set timing [read $f]
close $f
foreach key {SWNS HWNS} {
 if {![regexp [format {%s: (-?[0-9.]+)ns} $key] $timing -> value] || $value <= 0} {error "Nonpositive $key"}
}
foreach key {STNS HTNS} {
 if {![regexp [format {%s: (-?[0-9.]+)ns} $key] $timing -> value] || $value != 0} {error "Nonzero $key"}
}
puts {PACKAGE_BIT_DRC_BEGIN}
report_route_status -drc
puts {PACKAGE_BIT_DRC_END}
bitgen -bit build/double_board_2_main_sw4_V10_TEST.bit

 puts {PACKAGE_BIT_COMPLETE}
} message]} {
 puts "PACKAGE_BUILD_FAILED: $message"
 exit 1
}
exit 0
