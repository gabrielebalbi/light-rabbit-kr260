###############################################################################
# build_all.tcl — KR260 SFP+ SDM: crea progetto, BD completo, genera bitstream
#
# Uso: cd ~/sfp_drp_kr260_sdm && vivado -mode batch -source scripts/build_all.tcl
#
# AXI address map:
#   0xA0000000  axi_drp_bridge_0      DRP GTHE4_CHANNEL
#   0xA0010000  axi_iic_sfp           I2C SFP+ (SCL AB11, SDA AC11)
#   0xA0020000  axi_drp_bridge_common DRP GTHE4_COMMON (SDM/QPLL0)
#   0xA0030000  freq_counter_0        frequenzimetro TXPRGDIVCLK
#
# Note:
#   QPLL0_SDM_CFG0 @ DRP 0x0020, CFG1 @ 0x0021, CFG2 @ 0x0024 (UG576 v1.7.1)
#   TXPRGDIVCLK ≈ 161 MHz per 10.3125 Gbps, PROGDIV=64
###############################################################################

set root_dir [file normalize [pwd]]
set proj_dir $root_dir/vivado/sfp_drp_kr260_sdm
set rtl_dir  $root_dir/rtl
set xdc_dir  $root_dir/constraints

# ============================================================
# 1. Crea progetto
# ============================================================
create_project sfp_drp_kr260_sdm $proj_dir -part xck26-sfvc784-2LV-c -force
set_property board_part      xilinx.com:kr260_som:part0:1.1 [current_project]
set_property target_language Verilog [current_project]

add_files -norecurse [list \
    $rtl_dir/axi_drp_bridge.v \
    $rtl_dir/freq_counter.v   \
    $rtl_dir/gth_sfp_wrapper.v \
    $rtl_dir/top_sfp_drp.v]
add_files -fileset constrs_1 -norecurse $xdc_dir/kr260_sfp.xdc
update_compile_order -fileset sources_1

# ============================================================
# 2. Block Design
# ============================================================
create_bd_design "design_1"

# --- PS ---
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config { apply_board_preset "1" } $ps
set_property CONFIG.PSU__USE__M_AXI_GP0 {1} $ps
set_property CONFIG.PSU__USE__M_AXI_GP1 {0} $ps

# --- SmartConnect: 1 SI, 4 MI (CH, COMMON, FC, IIC) ---
set sc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_0]
set_property CONFIG.NUM_SI {1} $sc
set_property CONFIG.NUM_MI {4} $sc

# --- RTL module references ---
set drp  [create_bd_cell -type module -reference axi_drp_bridge axi_drp_bridge_0]
set drpc [create_bd_cell -type module -reference axi_drp_bridge axi_drp_bridge_common]
set fc   [create_bd_cell -type module -reference freq_counter    freq_counter_0]

# --- AXI IIC SFP+ ---
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic:2.1 axi_iic_sfp
set_property -dict [list \
    CONFIG.C_SCL_INERTIAL_DELAY {25} \
    CONFIG.C_SDA_INERTIAL_DELAY {25} \
    CONFIG.C_GPO_WIDTH           {1} \
] [get_bd_cells axi_iic_sfp]

# ----------------------------------------------------------------
# Porte esterne BD
# ----------------------------------------------------------------
# DRP CHANNEL
create_bd_port -dir O              drpclk
create_bd_port -dir O -from 9  -to 0 drpaddr
create_bd_port -dir O -from 15 -to 0 drpdi
create_bd_port -dir I -from 15 -to 0 drpdo
create_bd_port -dir O              drpen
create_bd_port -dir O              drpwe
create_bd_port -dir I              drprdy

# DRP COMMON
create_bd_port -dir O -from 9  -to 0 drpcomm_addr
create_bd_port -dir O -from 15 -to 0 drpcomm_di
create_bd_port -dir I -from 15 -to 0 drpcomm_do
create_bd_port -dir O              drpcomm_en
create_bd_port -dir O              drpcomm_we
create_bd_port -dir I              drpcomm_rdy

# TXOUTCLK input (da BUFG_GT nel top → meas_clk del frequenzimetro)
create_bd_port -dir I -type clk txoutclk_i
set_property CONFIG.FREQ_HZ 161000000 [get_bd_ports txoutclk_i]

# SFP IIC (SCL/SDA inout)
make_bd_intf_pins_external [get_bd_intf_pins axi_iic_sfp/IIC]
set_property NAME sfp_iic [get_bd_intf_ports IIC_0]

# Laser enable (GPO[0] dell'AXI IIC → top inverte → sfp_tx_disable)
create_bd_port -dir O -from 0 -to 0 sfp_laser_en
connect_bd_net [get_bd_pins axi_iic_sfp/gpo] [get_bd_ports sfp_laser_en]

# ----------------------------------------------------------------
# AXI connections
# ----------------------------------------------------------------
connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM0_FPD] \
                    [get_bd_intf_pins $sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $sc/M00_AXI] [get_bd_intf_pins $drp/S_AXI]
connect_bd_intf_net [get_bd_intf_pins $sc/M01_AXI] [get_bd_intf_pins $drpc/S_AXI]
connect_bd_intf_net [get_bd_intf_pins $sc/M02_AXI] [get_bd_intf_pins $fc/S_AXI]
connect_bd_intf_net [get_bd_intf_pins $sc/M03_AXI] \
                    [get_bd_intf_pins axi_iic_sfp/S_AXI]

# ----------------------------------------------------------------
# Clock e reset
# ----------------------------------------------------------------
connect_bd_net [get_bd_pins $ps/pl_clk0] \
               [get_bd_pins $ps/maxihpm0_fpd_aclk] \
               [get_bd_pins $sc/aclk] \
               [get_bd_pins $drp/s_axi_aclk] \
               [get_bd_pins $drpc/s_axi_aclk] \
               [get_bd_pins $fc/s_axi_aclk] \
               [get_bd_pins axi_iic_sfp/s_axi_aclk]

connect_bd_net [get_bd_pins $ps/pl_resetn0] \
               [get_bd_pins $sc/aresetn] \
               [get_bd_pins $drp/s_axi_aresetn] \
               [get_bd_pins $drpc/s_axi_aresetn] \
               [get_bd_pins $fc/s_axi_aresetn] \
               [get_bd_pins axi_iic_sfp/s_axi_aresetn]

# drpclk BD port: driven by drp/drpclk (output del bridge CH = s_axi_aclk = pl_clk0)
# drpc/drpclk e' anch'esso = pl_clk0 internamente; NON si connette al port per
# evitare multi-driver nel BD. Output di module reference non connesso e' OK (optimized away).
connect_bd_net [get_bd_pins $drp/drpclk] [get_bd_ports drpclk]

# TXOUTCLK → meas_clk frequenzimetro
connect_bd_net [get_bd_ports txoutclk_i] [get_bd_pins $fc/meas_clk]

# ----------------------------------------------------------------
# DRP CHANNEL segnali
# ----------------------------------------------------------------
connect_bd_net [get_bd_pins $drp/drpaddr] [get_bd_ports drpaddr]
connect_bd_net [get_bd_pins $drp/drpdi]   [get_bd_ports drpdi]
connect_bd_net [get_bd_ports drpdo]       [get_bd_pins $drp/drpdo]
connect_bd_net [get_bd_pins $drp/drpen]   [get_bd_ports drpen]
connect_bd_net [get_bd_pins $drp/drpwe]   [get_bd_ports drpwe]
connect_bd_net [get_bd_ports drprdy]      [get_bd_pins $drp/drprdy]

# ----------------------------------------------------------------
# DRP COMMON segnali
# ----------------------------------------------------------------
connect_bd_net [get_bd_pins $drpc/drpaddr] [get_bd_ports drpcomm_addr]
connect_bd_net [get_bd_pins $drpc/drpdi]   [get_bd_ports drpcomm_di]
connect_bd_net [get_bd_ports drpcomm_do]   [get_bd_pins $drpc/drpdo]
connect_bd_net [get_bd_pins $drpc/drpen]   [get_bd_ports drpcomm_en]
connect_bd_net [get_bd_pins $drpc/drpwe]   [get_bd_ports drpcomm_we]
connect_bd_net [get_bd_ports drpcomm_rdy]  [get_bd_pins $drpc/drprdy]

# ----------------------------------------------------------------
# Address assignment
# ----------------------------------------------------------------
assign_bd_address

foreach {filter base} {
    {NAME =~ *axi_drp_bridge_0*}      0xA0000000
    {NAME =~ *axi_iic_sfp*}           0xA0010000
    {NAME =~ *axi_drp_bridge_common*} 0xA0020000
    {NAME =~ *freq_counter_0*}        0xA0030000
} {
    set seg [get_bd_addr_segs \
        -of_objects [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
        -filter $filter]
    if {$seg ne ""} {
        set_property offset $base $seg
        set_property range  64K   $seg
        puts "INFO: $filter @ $base"
    } else {
        puts "WARN: segmento non trovato per $filter"
    }
}

validate_bd_design
save_bd_design

# ============================================================
# 3. Genera wrapper HDL, imposta top
# ============================================================
generate_target all [get_files design_1.bd]
make_wrapper -files [get_files design_1.bd] -top
set wrapper [glob $proj_dir/sfp_drp_kr260_sdm.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v]
add_files -norecurse $wrapper
set_property top top_sfp_drp [current_fileset]
update_compile_order -fileset sources_1

# ============================================================
# 4. XDC pin constraints (IIC + TX_DISABLE)
# ============================================================
set xdc_iic "${proj_dir}/sfp_iic_pins.xdc"
set fh [open $xdc_iic w]
puts $fh "# SFP+ I2C — KR260 carrier: SOM240_2 B49 (SCL) B50 (SDA), bank 64, LVCMOS33"
puts $fh "set_property -dict {PACKAGE_PIN AB11 IOSTANDARD LVCMOS33} \[get_ports sfp_iic_scl_io\]"
puts $fh "set_property -dict {PACKAGE_PIN AC11 IOSTANDARD LVCMOS33} \[get_ports sfp_iic_sda_io\]"
puts $fh "set_property PULLUP TRUE \[get_ports sfp_iic_scl_io\]"
puts $fh "set_property PULLUP TRUE \[get_ports sfp_iic_sda_io\]"
close $fh
add_files -fileset constrs_1 -norecurse $xdc_iic
puts "INFO: XDC IIC -> $xdc_iic"

set xdc_tx "${proj_dir}/sfp_tx_disable_pin.xdc"
set fh [open $xdc_tx w]
puts $fh "# SFP+ TX_DISABLE — KR260 carrier: HDB19, SOM240_2 A47, LVCMOS33, pull-up 4.7k"
puts $fh "set_property -dict {PACKAGE_PIN Y10 IOSTANDARD LVCMOS33} \[get_ports sfp_tx_disable\]"
close $fh
add_files -fileset constrs_1 -norecurse $xdc_tx
puts "INFO: XDC TX_DIS -> $xdc_tx"

# ============================================================
# 5. Sintesi
# ============================================================
puts "\n### AVVIO SINTESI ###"
launch_runs synth_1 -jobs 8
wait_on_run synth_1
set prog [get_property PROGRESS [get_runs synth_1]]
set stat [get_property STATUS   [get_runs synth_1]]
puts "SYNTH: $stat  $prog"
if {$prog ne "100%"} {
    error "Sintesi fallita — log: ${proj_dir}/sfp_drp_kr260_sdm.runs/synth_1/runme.log"
}

# ============================================================
# 6. Implementation + Bitstream
# ============================================================
puts "\n### AVVIO IMPLEMENTATION ###"
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set prog [get_property PROGRESS [get_runs impl_1]]
set stat [get_property STATUS   [get_runs impl_1]]
puts "IMPL: $stat  $prog"
if {$prog ne "100%"} {
    error "Implementation fallita — log: ${proj_dir}/sfp_drp_kr260_sdm.runs/impl_1/runme.log"
}

# ============================================================
# 7. Timing summary e report
# ============================================================
open_run impl_1
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "WNS = $wns ns"

set bit [glob -nocomplain ${proj_dir}/sfp_drp_kr260_sdm.runs/impl_1/top_sfp_drp.bit]
puts "\n### BUILD COMPLETATA ###"
puts "Bitstream: $bit"
puts ""
puts "Mappa AXI:"
puts "  0xA0000000  DRP GTHE4_CHANNEL"
puts "  0xA0010000  AXI IIC SFP+ (SCL AB11, SDA AC11)"
puts "  0xA0020000  DRP GTHE4_COMMON (SDM: CFG0@0x20, CFG1@0x21, CFG2@0x24)"
puts "  0xA0030000  Frequenzimetro (GATE@0x00, CNT@0x04, STATUS@0x08)"
puts ""
puts "Copia su KR260:"
puts "  scp $bit ubuntu@<KR260_IP>:~/sfp_drp_sdm.bit"
puts "  ssh ubuntu@<KR260_IP> 'sudo xmutil unloadapp && sudo fpgautil -b ~/sfp_drp_sdm.bit'"

close_project
