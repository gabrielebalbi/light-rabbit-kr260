###############################################################################
# add_tx_disable.tcl
# Cabla il TX_DISABLE dell'SFP+ al GPO dell'AXI IIC già presente nel BD.
# KR260 (Zynq UltraScale+ ZU5EV), Vivado 2025.2
#
# Pin (da schematico xtp743 sheet 14 + part0_pins.xml index 82):
#   SFP pin 3 TX_DISABLE -> net HDB19 -> SOM240_2 A47 -> package pin Y10
#   IOSTANDARD LVCMOS33 (bank HDB, VCCO=PL_3V3), pull-up 4.7k R335 sul carrier
#
# Semantica: GPO[0] dell'AXI IIC (reg 0x124) = "laser enable".
#   Il top inverte: sfp_tx_disable = ~sfp_laser_en. GPO reset = 0 -> laser
#   spento al caricamento (stesso comportamento del bitstream attuale).
#
# Uso: vivado -mode batch -source ~/sfp_drp_kr260_sdm/scripts/add_tx_disable.tcl
###############################################################################

set prj_dir  "$env(HOME)/sfp_drp_kr260_sdm/vivado/sfp_drp_kr260_sdm"
set prj_name "sfp_drp_kr260_sdm"

set TX_DISABLE_PIN "Y10"
set TX_DISABLE_STD "LVCMOS33"

open_project ${prj_dir}/${prj_name}.xpr
open_bd_design [get_files design_1.bd]

# ---------------------------------------------------------------------------
# Pulizia idempotente: rimuovi porta sfp_laser_en residua da run precedenti
# ---------------------------------------------------------------------------
foreach port [get_bd_ports -quiet sfp_laser_en] {
    delete_bd_objs [get_bd_nets -quiet -of_objects $port]
    delete_bd_objs $port
    puts "INFO: rimossa porta sfp_laser_en residua"
}

# ---------------------------------------------------------------------------
# GPO dell'AXI IIC -> porta esterna del BD
# ---------------------------------------------------------------------------
set iic [get_bd_cells axi_iic_sfp]
if {$iic eq ""} { error "axi_iic_sfp non trovato nel BD" }
set_property CONFIG.C_GPO_WIDTH 1 $iic

create_bd_port -dir O -from 0 -to 0 sfp_laser_en
connect_bd_net [get_bd_pins axi_iic_sfp/gpo] [get_bd_ports sfp_laser_en]
puts "INFO: gpo -> porta esterna sfp_laser_en"

validate_bd_design
save_bd_design

# ---------------------------------------------------------------------------
# Rigenera wrapper. Il top del progetto RESTA top_sfp_drp (istanzia anche il
# GTH: impostare design_1_wrapper come top scarterebbe il transceiver!)
# ---------------------------------------------------------------------------
generate_target all [get_files design_1.bd]
make_wrapper -files [get_files design_1.bd] -top
set wrapper_file "${prj_dir}/${prj_name}.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v"
if {[file exists $wrapper_file]} { add_files -norecurse $wrapper_file }
set_property top top_sfp_drp [current_fileset]

# ---------------------------------------------------------------------------
# XDC per il pin TX_DISABLE
# ---------------------------------------------------------------------------
set xdc_path "${prj_dir}/sfp_tx_disable_pin.xdc"
set fh [open $xdc_path w]
puts $fh "# SFP+ TX_DISABLE — KR260 carrier: HDB19, SOM240_2 A47, pull-up 4.7k a PL_3V3"
puts $fh "set_property -dict {PACKAGE_PIN ${TX_DISABLE_PIN} IOSTANDARD ${TX_DISABLE_STD}} \[get_ports sfp_tx_disable\]"
close $fh
add_files -fileset constrs_1 -norecurse $xdc_path
puts "INFO: XDC scritto in $xdc_path"

# ---------------------------------------------------------------------------
# Reset di tutti i run (inclusi gli IP run) e rebuild completo
# ---------------------------------------------------------------------------
foreach r [get_runs -filter {IS_SYNTHESIS == 1}] { reset_run $r }
reset_run impl_1

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Sintesi fallita — controlla: ${prj_dir}/${prj_name}.runs/synth_1/runme.log"
}
puts "INFO: Sintesi completata"

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Implementation fallita — controlla: ${prj_dir}/${prj_name}.runs/impl_1/runme.log"
}

set bit_path "${prj_dir}/${prj_name}.runs/impl_1/top_sfp_drp.bit"
puts "\n### BUILD COMPLETATA ###"
puts "Bitstream: $bit_path"
puts "Controllo laser: AXI IIC GPO reg 0xA0010124, bit0: 1=laser ON, 0=OFF (default)"
puts "\nCopia su KR260:"
puts "  scp $bit_path ubuntu@<KR260_IP>:~/Desktop/claudio/sfp_drp/top_sfp_drp.bit"

close_project
