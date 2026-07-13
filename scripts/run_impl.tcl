open_project $env(HOME)/sfp_drp_kr260_sdm/vivado/sfp_drp_kr260_sdm/sfp_drp_kr260_sdm.xpr

# Reset ALL synthesis runs to pick up changed axi_drp_bridge.v
foreach r [get_runs -filter {IS_SYNTHESIS==1}] {
    puts "Resetting run: $r"
    reset_run $r
}

launch_runs synth_1 -jobs 8
wait_on_run synth_1
set prog [get_property PROGRESS [get_runs synth_1]]
set stat [get_property STATUS   [get_runs synth_1]]
puts "SYNTH: $stat  $prog"
if {$prog ne "100%"} { puts "ERROR: synthesis failed"; exit 1 }

launch_runs impl_1 -jobs 8
wait_on_run impl_1
set prog [get_property PROGRESS [get_runs impl_1]]
set stat [get_property STATUS   [get_runs impl_1]]
puts "IMPL: $stat  $prog"
if {$prog ne "100%"} { puts "ERROR: implementation failed"; exit 1 }

open_run impl_1
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "WNS = $wns ns"

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "Bitstream done."
set bit [glob -nocomplain $env(HOME)/sfp_drp_kr260_sdm/vivado/sfp_drp_kr260_sdm/sfp_drp_kr260_sdm.runs/impl_1/*.bit]
puts "Bitstream: $bit"
