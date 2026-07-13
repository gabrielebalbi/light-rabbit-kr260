# create_project.tcl — KR260 SFP+ SDM exercise project (Vivado 2025.2)
# Usage: cd ~/sfp_drp_kr260_sdm && vivado -mode batch -source scripts/create_project.tcl
#
# AXI address map:
#   0xA0000000  axi_drp_bridge_0      DRP GTHE4_CHANNEL
#   0xA0010000  axi_iic_sfp           I2C SFP+ (aggiunto da add_axi_iic.tcl)
#   0xA0020000  axi_drp_bridge_common DRP GTHE4_COMMON (SDM/QPLL registers)
#   0xA0030000  freq_counter_0        frequenzimetro TXPRGDIVCLK

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

set ps  [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config { apply_board_preset "1" } $ps
set_property CONFIG.PSU__USE__M_AXI_GP0 {1} $ps
set_property CONFIG.PSU__USE__M_AXI_GP1 {0} $ps

# SmartConnect: 1 SI, 3 MI (DRP_CH, DRP_COMMON, FREQ_CNT); add_axi_iic.tcl aggiunge IIC
set sc  [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_0]
set_property CONFIG.NUM_SI {1} $sc
set_property CONFIG.NUM_MI {3} $sc

# AXI DRP bridge GTHE4_CHANNEL
set drp [create_bd_cell -type module -reference axi_drp_bridge axi_drp_bridge_0]

# AXI DRP bridge GTHE4_COMMON (registri SDM QPLL0)
set drpc [create_bd_cell -type module -reference axi_drp_bridge axi_drp_bridge_common]

# Frequenzimetro
set fc [create_bd_cell -type module -reference freq_counter freq_counter_0]

# ----------------------------------------------------------------
# Porte esterne — DRP CHANNEL
# ----------------------------------------------------------------
create_bd_port -dir O              drpclk
create_bd_port -dir O -from 9  -to 0 drpaddr
create_bd_port -dir O -from 15 -to 0 drpdi
create_bd_port -dir I -from 15 -to 0 drpdo
create_bd_port -dir O              drpen
create_bd_port -dir O              drpwe
create_bd_port -dir I              drprdy

# Porte esterne — DRP COMMON
create_bd_port -dir O -from 9  -to 0 drpcomm_addr
create_bd_port -dir O -from 15 -to 0 drpcomm_di
create_bd_port -dir I -from 15 -to 0 drpcomm_do
create_bd_port -dir O              drpcomm_en
create_bd_port -dir O              drpcomm_we
create_bd_port -dir I              drpcomm_rdy

# Porta esterna — TXOUTCLK da BUFG_GT nel top (input clock per il frequenzimetro)
create_bd_port -dir I -type clk txoutclk_i
set_property CONFIG.FREQ_HZ 161000000 [get_bd_ports txoutclk_i]

# ----------------------------------------------------------------
# Connessioni AXI
# ----------------------------------------------------------------
connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM0_FPD] \
                    [get_bd_intf_pins $sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $sc/M00_AXI] [get_bd_intf_pins $drp/S_AXI]
connect_bd_intf_net [get_bd_intf_pins $sc/M01_AXI] [get_bd_intf_pins $drpc/S_AXI]
connect_bd_intf_net [get_bd_intf_pins $sc/M02_AXI] [get_bd_intf_pins $fc/S_AXI]

# ----------------------------------------------------------------
# Clock e reset
# ----------------------------------------------------------------
# pl_clk0 → aclk del PS, SmartConnect, tutti e tre i bridge AXI, porta drpclk
connect_bd_net [get_bd_pins $ps/pl_clk0] \
               [get_bd_pins $ps/maxihpm0_fpd_aclk] \
               [get_bd_pins $sc/aclk] \
               [get_bd_pins $drp/s_axi_aclk] \
               [get_bd_pins $drpc/s_axi_aclk] \
               [get_bd_pins $fc/s_axi_aclk] \
               [get_bd_ports drpclk]

connect_bd_net [get_bd_pins $ps/pl_resetn0] \
               [get_bd_pins $sc/aresetn] \
               [get_bd_pins $drp/s_axi_aresetn] \
               [get_bd_pins $drpc/s_axi_aresetn] \
               [get_bd_pins $fc/s_axi_aresetn]

# drpclk del bridge COMMON è la stessa porta drpclk (stesso pl_clk0)
connect_bd_net [get_bd_pins $drpc/drpclk] [get_bd_ports drpclk]

# TXOUTCLK → meas_clk del frequenzimetro
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

set seg_ch [get_bd_addr_segs \
    -of_objects [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    -filter {NAME =~ *axi_drp_bridge_0*}]
if {$seg_ch ne ""} {
    set_property offset 0xA0000000 $seg_ch
    set_property range  64K         $seg_ch
    puts "INFO: DRP CH  @ 0xA0000000"
}

set seg_comm [get_bd_addr_segs \
    -of_objects [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    -filter {NAME =~ *axi_drp_bridge_common*}]
if {$seg_comm ne ""} {
    set_property offset 0xA0020000 $seg_comm
    set_property range  64K         $seg_comm
    puts "INFO: DRP COMMON @ 0xA0020000"
}

set seg_fc [get_bd_addr_segs \
    -of_objects [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    -filter {NAME =~ *freq_counter_0*}]
if {$seg_fc ne ""} {
    set_property offset 0xA0030000 $seg_fc
    set_property range  64K         $seg_fc
    puts "INFO: FREQ_CNT @ 0xA0030000"
}

validate_bd_design
save_bd_design

# ============================================================
# 3. Genera wrapper BD, imposta top
# ============================================================
make_wrapper -files [get_files design_1.bd] -top
set wrapper [glob $proj_dir/sfp_drp_kr260_sdm.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v]
add_files -norecurse $wrapper
set_property top top_sfp_drp [current_fileset]
update_compile_order -fileset sources_1

puts "============================================================"
puts "Progetto pronto: $proj_dir"
puts "Mappa AXI:"
puts "  0xA0000000  DRP GTHE4_CHANNEL"
puts "  0xA0010000  AXI IIC SFP+  (da add_axi_iic.tcl)"
puts "  0xA0020000  DRP GTHE4_COMMON (SDM/QPLL)"
puts "  0xA0030000  Frequenzimetro TXPRGDIVCLK"
puts "Nota: FREQ_HZ di txoutclk_i impostato a 161 MHz (approx per 10.3125 Gbps / 64 bit)."
puts "      Aggiornare se si cambia line rate via GTH Wizard."
puts "Apri: vivado $proj_dir/sfp_drp_kr260_sdm.xpr"
puts "============================================================"
