# build_sdm.tcl — build kr260_wr_sdm (endpoint WR con steering QPLL0+SDM).
# Tree: kr260_wr_sdm_v1 (clone di v1). Vedi shared_handoff/SDM_KR260_DESIGN.md.
# Fasi: add sources -> IP sdm-eth -> BD edit (DRP COMMON + freq counter) ->
#       top=kr260_wr_sdm -> synth+impl -> bit + app (con wrc.bram embedded).
# Uso: vivado -mode batch -source build_sdm.tcl -log build_sdm.log

set root $env(HOME)/kr260_wr_sdm_v1
set proj $root/project_1/project_1.xpr
set runs $root/project_1/project_1.runs
set out  $runs/impl_1
set S    $root/project_1/project_1.srcs/sources_1/imports/kr260_wr_rxpol_exp

open_project $proj

# --- sorgenti nuovi (idempotente) ---
foreach f [list \
  $S/hdl/wr-cores/platform/xilinx/wr_gtp_phy/family7-gthe4-sdm/gtp_bitslide.vhd \
  $S/hdl/wr-cores/platform/xilinx/wr_gtp_phy/family7-gthe4-sdm/wr_gthe4_phy_family7_xilinx_ip.vhd \
  $S/hdl/board/xwrc_board_kr260_sdm.vhd \
  $S/hdl/top/kr260_wr/kr260_wr_sdm.vhd \
  $S/rtl/axi_drp_bridge.v \
  $S/rtl/freq_counter.v] {
  if {[llength [get_files -quiet [file tail $f]]] == 0} { add_files -norecurse $f }
}
update_compile_order -fileset sources_1

# --- IP GT wizard SDM-eth (X0Y6, 156.25, QPLL0 fracN) ---
# rigenerazione FORZATA se la refclk generata non e' 156.25 (bug ordine set_property)
set need_regen 0
if {[llength [get_ips -quiet gtwizard_v1_7_gthe4_sdm_eth]] == 0} {
  set need_regen 1
} elseif {[get_property CONFIG.TX_REFCLK_FREQUENCY [get_ips gtwizard_v1_7_gthe4_sdm_eth]] ne "156.249404"} {
  puts "=== IP con refclk SBAGLIATA: riconfiguro in-place (refclk+fracn insieme) ==="
  set_property -dict [list \
    CONFIG.RX_REFCLK_FREQUENCY {156.25} \
    CONFIG.TX_REFCLK_FREQUENCY {156.249404} \
    CONFIG.TX_QPLL_FRACN_NUMERATOR {4096} \
  ] [get_ips gtwizard_v1_7_gthe4_sdm_eth]
  reset_target all [get_ips gtwizard_v1_7_gthe4_sdm_eth]
}
if {$need_regen} { source $root/create-gth-sdm-eth-kr260.tcl }
# sintesi GLOBALE dell'IP (no OOC): il flusso scriptato con reconfig lasciava
# il checkpoint OOC stantio -> black box all'impl (IBUF su sfp_rx_p, LOC error)
set_property generate_synth_checkpoint false \
    [get_files gtwizard_v1_7_gthe4_sdm_eth.xci]
generate_target all [get_ips gtwizard_v1_7_gthe4_sdm_eth]
set p_ref [get_property CONFIG.TX_REFCLK_FREQUENCY [get_ips gtwizard_v1_7_gthe4_sdm_eth]]
puts "=== IP TX_REFCLK_FREQUENCY = $p_ref (atteso 156.249404) ==="
if {$p_ref ne "156.249404"} { error "REFCLK non applicata: $p_ref" }

# --- BD edit: smartconnect 2->4 MI, axi_drp_bridge COMMON + freq_counter ---
open_bd_design [get_files wr_bd.bd]
if {[llength [get_bd_cells -quiet drp_common_0]] == 0} {
  puts "=== BD edit: aggiungo drp_common_0 + fmeter_0 ==="
  set_property CONFIG.NUM_MI {4} [get_bd_cells smartconnect_0]
  create_bd_cell -type module -reference axi_drp_bridge drp_common_0
  create_bd_cell -type module -reference freq_counter  fmeter_0

  # clock/reset: dominio pl_clk0/pl_resetn0 del PS (come lo smartconnect)
  connect_bd_net [get_bd_pins drp_common_0/s_axi_aclk] \
      [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]
  connect_bd_net [get_bd_pins drp_common_0/s_axi_aresetn] \
      [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0]
  connect_bd_net [get_bd_pins fmeter_0/s_axi_aclk] \
      [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]
  connect_bd_net [get_bd_pins fmeter_0/s_axi_aresetn] \
      [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0]

  # AXI: smartconnect M02 -> drp_common_0, M03 -> fmeter_0
  connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M02_AXI] \
      [lindex [get_bd_intf_pins drp_common_0/*] 0]
  connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M03_AXI] \
      [lindex [get_bd_intf_pins fmeter_0/*] 0]

  # DRP master del bridge -> porte esterne del BD (verso il PHY nel fabric)
  create_bd_port -dir O -from 9  -to 0 drpc_addr
  connect_bd_net [get_bd_ports drpc_addr] [get_bd_pins drp_common_0/drpaddr]
  create_bd_port -dir O -from 15 -to 0 drpc_di
  connect_bd_net [get_bd_ports drpc_di]   [get_bd_pins drp_common_0/drpdi]
  create_bd_port -dir O drpc_en
  connect_bd_net [get_bd_ports drpc_en]   [get_bd_pins drp_common_0/drpen]
  create_bd_port -dir O drpc_we
  connect_bd_net [get_bd_ports drpc_we]   [get_bd_pins drp_common_0/drpwe]
  create_bd_port -dir I -from 15 -to 0 drpc_do
  connect_bd_net [get_bd_ports drpc_do]   [get_bd_pins drp_common_0/drpdo]
  create_bd_port -dir I drpc_rdy
  connect_bd_net [get_bd_ports drpc_rdy]  [get_bd_pins drp_common_0/drprdy]

  # clock misurato dal frequenzimetro (tx clk del GT, dal fabric)
  create_bd_port -dir I -type clk fmeter_clk
  connect_bd_net [get_bd_ports fmeter_clk] [get_bd_pins fmeter_0/meas_clk]

  # indirizzi: stessi del progetto esercizio sfp_drp_kr260_sdm
  assign_bd_address
  foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces zynq_ultra_ps_e_0/Data]] {
    if {[string match *drp_common_0* $seg]} {
      set_property offset 0xA0020000 $seg; set_property range 4K $seg
    } elseif {[string match *fmeter_0* $seg]} {
      set_property offset 0xA0030000 $seg; set_property range 4K $seg
    }
  }
}

# --- BD edit XVC: debug_bridge AXI-to-BSCAN @0xA0040000 (v5) ---
if {[llength [get_bd_cells -quiet debug_bridge_0]] == 0} {
  puts "=== BD edit: aggiungo debug_bridge_0 (XVC) ==="
  set_property CONFIG.NUM_MI {5} [get_bd_cells smartconnect_0]
  create_bd_cell -type ip -vlnv xilinx.com:ip:debug_bridge debug_bridge_0
  # DEBUG_MODE 2 = From AXI to BSCAN. NB: con un bridge master nel design il
  # dbg_hub automatico NON viene inserito (Chipscope 16-336): serve il secondo
  # bridge in modalita' "From BSCAN to Debug Hub" (DEBUG_MODE 1) che fa da hub.
  set_property CONFIG.C_DEBUG_MODE {2} [get_bd_cells debug_bridge_0]
  connect_bd_net [get_bd_pins debug_bridge_0/s_axi_aclk] \
      [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]
  connect_bd_net [get_bd_pins debug_bridge_0/s_axi_aresetn] \
      [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0]
  connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M04_AXI] \
      [get_bd_intf_pins debug_bridge_0/S_AXI]
  assign_bd_address
  foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces zynq_ultra_ps_e_0/Data]] {
    if {[string match *debug_bridge_0* $seg]} {
      set_property offset 0xA0040000 $seg; set_property range 64K $seg
    }
  }
}
# bridge#2 = hub per le ILA istanziate (coppia canonica PG245 per XVC)
if {[llength [get_bd_cells -quiet debug_bridge_1]] == 0} {
  puts "=== BD edit: aggiungo debug_bridge_1 (BSCAN->DebugHub) ==="
  # fixup bridge_0: via il BSCAN_MUX=2 del tentativo "only debug master"
  # (Chipscope 16-336: non supportato) e 1 porta BSCAN master esplicita
  catch { set_property CONFIG.C_BSCAN_MUX {1} [get_bd_cells debug_bridge_0] }
  catch { set_property CONFIG.C_NUM_BS_MASTER {1} [get_bd_cells debug_bridge_0] }
  create_bd_cell -type ip -vlnv xilinx.com:ip:debug_bridge debug_bridge_1
  set_property CONFIG.C_DEBUG_MODE {1} [get_bd_cells debug_bridge_1]
  puts "  intf bridge_0: [get_bd_intf_pins -quiet debug_bridge_0/*]"
  puts "  intf bridge_1: [get_bd_intf_pins -quiet debug_bridge_1/*]"
  puts "  pin  bridge_1: [get_bd_pins -quiet debug_bridge_1/*]"
  connect_bd_intf_net [get_bd_intf_pins debug_bridge_0/m0_bscan] \
      [get_bd_intf_pins debug_bridge_1/S_BSCAN]
  # clock del hub XSDB: free-running pl_clk0
  connect_bd_net [get_bd_pins debug_bridge_1/clk] \
      [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]
}
validate_bd_design
save_bd_design
generate_target all [get_files wr_bd.bd]

# --- IP ila_sdm (istanziata nel top; flusso a istanza = compatibile col bridge) ---
if {[llength [get_ips -quiet ila_sdm]] == 0} {
  puts "=== creo IP ila_sdm ==="
  create_ip -name ila -vendor xilinx.com -library ip -module_name ila_sdm
  set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {5} \
    CONFIG.C_DATA_DEPTH {4096} \
    CONFIG.C_ADV_TRIGGER {true} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_PROBE0_WIDTH {25} \
    CONFIG.C_PROBE1_WIDTH {16} \
    CONFIG.C_PROBE2_WIDTH {1} \
    CONFIG.C_PROBE3_WIDTH {16} \
    CONFIG.C_PROBE4_WIDTH {25}] [get_ips ila_sdm]
}
generate_target all [get_ips ila_sdm]

# --- top + esclusioni ---
set_property top kr260_wr_sdm [current_fileset]
# la vecchia targettoIla.xdc (net LPDC) non deve entrare nella build SDM
foreach x [get_files -quiet targettoIla.xdc] {
  catch {set_property IS_ENABLED false $x}
}
# clock groups SDM (gtwiz_userclk_* asincroni vs pl_clk0/dmtd/refclk)
set sdmxdc $root/project_1/project_1.srcs/constrs_1/imports/hdl/top/kr260_wr/kr260_wr_sdm_clocks.xdc
if {[llength [get_files -quiet kr260_wr_sdm_clocks.xdc]] == 0} {
  add_files -fileset constrs_1 -norecurse $sdmxdc
}
# XDC del vecchio IP LPDC (gthe4_lp): riferiscono celle GT non piu' presenti
foreach x [get_files -quiet -of_objects [get_filesets constrs_1] *gthe4_lp*] {
  catch {set_property IS_ENABLED false $x}
  puts "disabilitato constraint LPDC: $x"
}

# --- synth ---
puts "=== synth_1 ==="
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
  error "SYNTH FAILED: [get_property STATUS [get_runs synth_1]]"
}

# --- impl (flusso manuale come build_bbfix) ---
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
# probes per la ILA istanziata (letta via XVC)
catch { write_debug_probes -force $out/kr260_wr_sdm.ltx }
puts "BIT: $out/kr260_wr_sdm.bit"

puts "=== make_kr260_app.sh -> kr260_wr_sdm ==="
if {[catch {exec bash $env(HOME)/kr260_wr_psen/scripts/make_kr260_app.sh \
              $out/kr260_wr_sdm.bit kr260_wr_sdm \
              $root/app/kr260_wr_sdm >@stdout 2>@stderr} err]} {
  puts "WARNING: app packaging failed: $err"
} else {
  puts "=== app: $root/app/kr260_wr_sdm ==="
}
puts "=== SDM_BUILD_DONE WNS=$wns ==="
