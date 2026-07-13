# rebuild_v15.tcl — v15 = v14 (fix DAC 20 bit + bitslide) + LED1/LED2 sulla cage SFP
#   LED1 = G8 = tm_time_valid   |   LED2 = F7 = heartbeat fabric
# HDL-only: reset_run synth_1, impl manuale, bitstream + app. NON ricrea IP,
# NON ricostruisce wrc.bram.
set root $env(HOME)/kr260_wr_sdm_v15
set proj $root/project_1/project_1.xpr
set out  $root/project_1/project_1.runs/impl_1

open_project $proj

puts "=== reset_run synth_1 ==="
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

# controllo esplicito che i due LED nuovi siano davvero piazzati
foreach p {led1_o led2_o led_link_o led_act_o} {
  puts "PIN CHECK: $p -> [get_property PACKAGE_PIN [get_ports $p]] ([get_property IOSTANDARD [get_ports $p]])"
}

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "WNS = $wns ns"
report_timing_summary -file $out/sdm_timing_v15.rpt -warn_on_violation

write_checkpoint -force $out/kr260_wr_sdm_v15.dcp
write_bitstream  -force $out/kr260_wr_sdm_v15.bit
catch { write_debug_probes -force $out/kr260_wr_sdm_v15.ltx }

puts "=== make_kr260_app.sh -> kr260_wr_sdm_app_v15 ==="
if {[catch {exec bash $env(HOME)/kr260_wr_psen/scripts/make_kr260_app.sh \
              $out/kr260_wr_sdm_v15.bit kr260_wr_sdm_app_v15 \
              $root/app/kr260_wr_sdm_app_v15 >@stdout 2>@stderr} err]} {
  puts "WARNING: app packaging failed: $err"
}
puts "=== SDM_BUILD_DONE_V15 WNS=$wns ==="
