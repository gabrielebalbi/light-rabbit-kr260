# rebuild_v12.tcl — SOLO rebuild: la sola modifica e' la wrc.bram (stack 4096,
# an=0, cmd mdio). Riapre il progetto, reset_run synth_1 (rilegge g_dpram_initf),
# impl manuale come build_sdm.tcl, bitstream + app. NON ricrea IP.
set root $env(HOME)/kr260_wr_sdm_v14
set proj $root/project_1/project_1.xpr
set out  $root/project_1/project_1.runs/impl_1

open_project $proj
puts "=== bram letta dal synth: g_dpram_initf ==="
puts "  [get_property generic [current_fileset]]"

puts "=== reset_run synth_1 (forza rilettura bram) ==="
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
  error "SYNTH FAILED: [get_property STATUS [get_runs synth_1]]"
}

open_run synth_1 -name synth_1
file mkdir $out
puts "=== opt_design ===";      opt_design
puts "=== place_design ===";    place_design
puts "=== phys_opt_design ==="; phys_opt_design
puts "=== route_design ===";    route_design

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "WNS = $wns ns"
report_timing_summary -file $out/sdm_timing.rpt -warn_on_violation

write_checkpoint -force $out/kr260_wr_sdm.dcp
write_bitstream  -force $out/kr260_wr_sdm.bit
catch { write_debug_probes -force $out/kr260_wr_sdm.ltx }

puts "=== make_kr260_app.sh -> kr260_wr_sdm ==="
if {[catch {exec bash $env(HOME)/kr260_wr_psen/scripts/make_kr260_app.sh \
              $out/kr260_wr_sdm.bit kr260_wr_sdm \
              $root/app/kr260_wr_sdm >@stdout 2>@stderr} err]} {
  puts "WARNING: app packaging failed: $err"
}
puts "=== SDM_BUILD_DONE_V14 WNS=$wns ==="
