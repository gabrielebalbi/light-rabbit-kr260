###############################################################################
# add_axi_iic.tcl
# Aggiunge AXI IIC IP al block design esistente per gestire l'I2C SFP+
# KR260 (Zynq UltraScale+ ZU5EV), Vivado 2025.2
#
# Uso: vivado -mode batch -source ~/sfp_drp_kr260_sdm/scripts/add_axi_iic.tcl
###############################################################################

set prj_dir  "$env(HOME)/sfp_drp_kr260_sdm/vivado/sfp_drp_kr260_sdm"
set prj_name "sfp_drp_kr260_sdm"

# Pin SFP+ I2C sul KR260 carrier:
#   SOM240_2 B49 (SCL) -> package pin AB11
#   SOM240_2 B50 (SDA) -> package pin AC11
#   Verificato da: part0_pins.xml index 123/124, LVCMOS33 da kr260_carrier board.xml
#   NB: AD6 (ipotesi precedente) è il VRP di bank 64 — riservato DCI, non usabile
set SFP_SCL_PIN "AB11"
set SFP_SDA_PIN "AC11"
set SFP_IO_STD  "LVCMOS33"

# ---------------------------------------------------------------------------
# Apri progetto e block design
# ---------------------------------------------------------------------------
open_project ${prj_dir}/${prj_name}.xpr
open_bd_design [get_files design_1.bd]

# ---------------------------------------------------------------------------
# Rimuovi axi_iic_tmp e le porte esterne tmp_iic* lasciate da sessioni precedenti
# ---------------------------------------------------------------------------
foreach cell [get_bd_cells -quiet axi_iic_tmp] {
    delete_bd_objs [get_bd_intf_nets -quiet -of_objects $cell]
    delete_bd_objs $cell
}
foreach port [get_bd_intf_ports -quiet tmp_iic] {
    delete_bd_objs $port
}
foreach port [get_bd_ports -quiet -filter {NAME =~ tmp_iic*}] {
    delete_bd_objs $port
}

# Rimuovi axi_iic_sfp residuo da run precedenti interrotte (rende lo script
# rieseguibile). delete_bd_objs sulla cella stacca i suoi pin dai net condivisi
# (pl_clk0 ecc.) senza cancellare i net per gli altri blocchi.
foreach cell [get_bd_cells -quiet axi_iic_sfp] {
    delete_bd_objs $cell
    puts "INFO: rimosso axi_iic_sfp residuo"
}
foreach pname {sfp_iic IIC_0} {
    foreach port [get_bd_intf_ports -quiet $pname] {
        delete_bd_objs $port
        puts "INFO: rimossa porta esterna residua $pname"
    }
}

# Riporta NUM_MI dello SmartConnect al numero di MI effettivamente connessi
# (una run precedente può averlo già incrementato lasciando M01_AXI orfano)
set sc_clean [get_bd_cells -quiet smartconnect_0]
if {$sc_clean ne ""} {
    set n_mi [get_property CONFIG.NUM_MI $sc_clean]
    while {$n_mi > 1} {
        set idx [format "%02d" [expr {$n_mi - 1}]]
        set pin [get_bd_intf_pins -quiet ${sc_clean}/M${idx}_AXI]
        if {$pin ne "" && [get_bd_intf_nets -quiet -of_objects $pin] eq ""} {
            incr n_mi -1
        } else {
            break
        }
    }
    set_property CONFIG.NUM_MI $n_mi $sc_clean
    puts "INFO: SmartConnect NUM_MI riallineato a $n_mi"
}

puts "INFO: pulizia completata"

# ---------------------------------------------------------------------------
# Crea e configura AXI IIC IP
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic:2.1 axi_iic_sfp

# Filtro glitch a 25 cicli AXI (250 ns @100 MHz): con fronti lenti/ringing sul
# bus, 5 (50 ns) non basta — il core conta fronti SCL spuri e perde byte
# (sintomo visto sul campo: ACK intermittente 30-50%, dump EEPROM corrotti).
set_property -dict [list \
    CONFIG.C_SCL_INERTIAL_DELAY {25} \
    CONFIG.C_SDA_INERTIAL_DELAY {25} \
] [get_bd_cells axi_iic_sfp]

# Clock e reset: connettersi ai pin del PS (non al nome del net)
connect_bd_net [get_bd_pins axi_iic_sfp/s_axi_aclk] \
    [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]
connect_bd_net [get_bd_pins axi_iic_sfp/s_axi_aresetn] \
    [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0]

puts "INFO: AXI IIC clock/reset connessi"

# ---------------------------------------------------------------------------
# Connessione AXI via SmartConnect (usa singolo aclk/aresetn, nessun pin per-porta)
# ---------------------------------------------------------------------------
set sc [get_bd_cells smartconnect_0]
if {$sc eq ""} { error "smartconnect_0 non trovato nel BD" }

set n_mi [get_property CONFIG.NUM_MI $sc]
set new_mi_idx [format "%02d" $n_mi]
set_property CONFIG.NUM_MI [expr {$n_mi + 1}] $sc

connect_bd_intf_net \
    [get_bd_intf_pins ${sc}/M${new_mi_idx}_AXI] \
    [get_bd_intf_pins axi_iic_sfp/S_AXI]

puts "INFO: AXI IIC connesso a M${new_mi_idx}_AXI dello SmartConnect"

# ---------------------------------------------------------------------------
# Porta IIC esterna (SCL/SDA inout)
# ---------------------------------------------------------------------------
make_bd_intf_pins_external [get_bd_intf_pins axi_iic_sfp/IIC]
set_property NAME sfp_iic [get_bd_intf_ports IIC_0]

puts "INFO: interfaccia sfp_iic esposta come porta esterna"

# ---------------------------------------------------------------------------
# Address assignment — forza 0xA0010000 (dopo DRP bridge a 0xA0000000)
# ---------------------------------------------------------------------------
assign_bd_address [get_bd_addr_segs axi_iic_sfp/S_AXI/Reg]

set seg [get_bd_addr_segs \
    -of_objects [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    -filter {NAME =~ *axi_iic_sfp*}]
if {$seg ne ""} {
    set_property offset 0xA0010000 $seg
    set_property range  64K         $seg
    puts "INFO: AXI IIC base address = 0xA0010000"
} else {
    puts "WARN: segmento indirizzo IIC non trovato — verificare manualmente in Address Editor"
}

# ---------------------------------------------------------------------------
# Valida e salva
# ---------------------------------------------------------------------------
validate_bd_design
save_bd_design
puts "INFO: BD validato e salvato"

# ---------------------------------------------------------------------------
# Rigenera wrapper HDL
# ---------------------------------------------------------------------------
generate_target all [get_files design_1.bd]

# Rigenera il wrapper del BD (ha nuove porte sfp_iic_*) ma il top del progetto
# resta top_sfp_drp: è lui che istanzia design_1_wrapper E gth_sfp_wrapper (GTH).
# Impostare design_1_wrapper come top scarterebbe il transceiver dal bitstream!
make_wrapper -files [get_files design_1.bd] -top
set wrapper_dir "${prj_dir}/${prj_name}.gen/sources_1/bd/design_1/hdl"
set wrapper_file "${wrapper_dir}/design_1_wrapper.v"
if {[file exists $wrapper_file]} {
    add_files -norecurse $wrapper_file
}
set_property top top_sfp_drp [current_fileset]

# ---------------------------------------------------------------------------
# XDC per pin SFP I2C — aggiunto al constraint set esistente
# ---------------------------------------------------------------------------
set xdc_path "${prj_dir}/sfp_iic_pins.xdc"
set fh [open $xdc_path w]
puts $fh "# SFP+ I2C pin constraints — KR260 carrier, SOM240_2 B49/B50, bank 64"
puts $fh "# SCL: ${SFP_SCL_PIN}  SDA: ${SFP_SDA_PIN}  (LVCMOS33, pull-up verso PL_3V3 sul carrier)"
puts $fh "set_property -dict {PACKAGE_PIN ${SFP_SCL_PIN} IOSTANDARD ${SFP_IO_STD}} \[get_ports sfp_iic_scl_io\]"
puts $fh "set_property -dict {PACKAGE_PIN ${SFP_SDA_PIN} IOSTANDARD ${SFP_IO_STD}} \[get_ports sfp_iic_sda_io\]"
puts $fh "# Pull-up interni FPGA: i fronti di salita sul campo sono marginali"
puts $fh "# (ACK intermittente) — aiutano i pull-up del carrier se deboli/assenti"
puts $fh "set_property PULLUP TRUE \[get_ports sfp_iic_scl_io\]"
puts $fh "set_property PULLUP TRUE \[get_ports sfp_iic_sda_io\]"
close $fh

add_files -fileset constrs_1 -norecurse $xdc_path
puts "INFO: XDC scritto in $xdc_path"

# ---------------------------------------------------------------------------
# Reset tutti i run (incluso IP run) e rebuild bitstream
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

# ---------------------------------------------------------------------------
# Fine
# ---------------------------------------------------------------------------
set bit_path "${prj_dir}/${prj_name}.runs/impl_1/top_sfp_drp.bit"
puts "\n### BUILD COMPLETATA ###"
puts "Bitstream: $bit_path"
puts "AXI IIC base address: 0xA0010000 (64K range)"
puts "Port names in XDC: sfp_iic_scl_io, sfp_iic_sda_io"
puts "\nCopia su KR260:"
puts "  scp $bit_path ubuntu@<KR260_IP>:~/Desktop/claudio/sfp_drp/top_sfp_drp.bit"

close_project
