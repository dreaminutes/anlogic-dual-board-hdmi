cd [file dirname [info script]]
file mkdir build
if {[catch {
 import_device eagle_s20.db -package EG4S20BG256
source read_sources.tcl
elaborate -top db_library_secondary_board
read_adc pins.adc
read_sdc clocks.sdc

 puts {PACKAGE_VALIDATE_COMPLETE}
} message]} {
 puts "PACKAGE_BUILD_FAILED: $message"
 exit 1
}
exit 0
