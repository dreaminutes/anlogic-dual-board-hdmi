cd [file dirname [info script]]
file mkdir build
if {[catch {
 import_device eagle_s20.db -package EG4S20BG256
source read_sources.tcl
elaborate -top db_neon_reference_main_board
read_adc pins.adc
read_sdc clocks.sdc
set_param gate map_mode area_prior
 optimize_rtl
 optimize_gate
 legalize_phy_inst
 export_db build/native_gate.db
 write_verilog build/mapped_gate.v
 report_area
 puts {PACKAGE_SYNTHESIS_COMPLETE}
} message]} {
 puts "PACKAGE_BUILD_FAILED: $message"
 exit 1
}
exit 0
