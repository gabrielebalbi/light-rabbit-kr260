# rebuild_v16.tcl — v16 = v15 + build_id (0xA0050000) + TDC carry (0xA0060000)
# Prima della synth inietta nel BD gli hash git correnti:
#   FW = sfp_drp_kr260_sdm (repo dei sorgenti custom)   SW = wrpc-sw (wrc.bram)
# HDL-only come la v15: reset synth_1, impl manuale, bitstream + app xmutil.
set root /home/labele/kr260_wr_sdm_v16
set proj $root/project_1/project_1.xpr
set out  $root/project_1/project_1.runs/impl_1

proc git_info {dir} {
  set h [exec git -C $dir rev-parse --short=8 HEAD]
  set dirty [expr {[string length [exec git -C $dir status --porcelain]] > 0}]
  return [list $h $dirty]
}
lassign [git_info /home/labele/sfp_drp_kr260_sdm] fw_hash fw_dirty
lassign [git_info /home/labele/wrpc-sw]           sw_hash sw_dirty
set flags [format %08x [expr {(16 << 24) | ($sw_dirty << 1) | $fw_dirty}]]
set ts    [format %08x [clock seconds]]
puts "BUILD_ID: fw=$fw_hash (dirty=$fw_dirty) sw=$sw_hash (dirty=$sw_dirty) flags=0x$flags"

open_project $proj

puts "=== inject build id nel BD ==="
open_bd_design [get_files wr_bd.bd]
set_property -dict [list \
  CONFIG.FW_GITHASH "32'h$fw_hash" \
  CONFIG.SW_GITHASH "32'h$sw_hash" \
  CONFIG.BUILD_TS   "32'h$ts" \
  CONFIG.FLAGS      "32'h$flags"] [get_bd_cells build_id_0]
save_bd_design
close_bd_design [current_bd_design]

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

foreach p {led1_o led2_o led_link_o led_act_o tdc_hit_pmod_i} {
  puts "PIN CHECK: $p -> [get_property PACKAGE_PIN [get_ports $p]] ([get_property IOSTANDARD [get_ports $p]])"
}
set n_c8 [llength [get_cells -hier -filter {REF_NAME == CARRY8 && NAME =~ *u_dl*}]]
puts "TDC CARRY8 CHAIN: $n_c8 blocchi (attesi 96)"

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "WNS = $wns ns"
report_timing_summary -file $out/sdm_timing_v16.rpt -warn_on_violation

write_checkpoint -force $out/kr260_wr_sdm_v16.dcp
write_bitstream  -force $out/kr260_wr_sdm_v16.bit
catch { write_debug_probes -force $out/kr260_wr_sdm_v16.ltx }

puts "=== make_kr260_app.sh -> kr260_wr_sdm_app_v16 ==="
if {[catch {exec bash /home/labele/kr260_wr_psen/scripts/make_kr260_app.sh \
              $out/kr260_wr_sdm_v16.bit kr260_wr_sdm_app_v16 \
              $root/app/kr260_wr_sdm_app_v16 >@stdout 2>@stderr} err]} {
  puts "WARNING: app packaging failed: $err"
}
puts "=== SDM_BUILD_DONE_V16 WNS=$wns ==="
