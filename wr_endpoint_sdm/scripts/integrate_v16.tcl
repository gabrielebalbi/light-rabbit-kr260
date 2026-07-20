# integrate_v16.tcl — una tantum: aggiunge build_id (0xA0050000) e tdc_carry
# (0xA0060000) al BD della v16, crea le porte, assegna gli indirizzi, rigenera
# il wrapper. Il top VHDL e' gia' stato editato a mano (porte tdc_*).
set root    /home/labele/kr260_wr_sdm_v16
set staging /home/labele/kr260_wr_sdm_v16_staging
set rtl_dst $root/project_1/project_1.srcs/sources_1/imports/kr260_wr_rxpol_exp/rtl
set xdc_dst $root/project_1/project_1.srcs/constrs_1/imports/hdl/top/kr260_wr

open_project $root/project_1/project_1.xpr

# --- sorgenti nuovi ---------------------------------------------------------
foreach f {build_id.v tdc_carry.v tdc_delayline.v} {
  file copy -force $staging/rtl/$f $rtl_dst/$f
}
add_files -fileset sources_1 [list $rtl_dst/build_id.v $rtl_dst/tdc_carry.v $rtl_dst/tdc_delayline.v]
file copy -force $staging/tdc_v16.xdc $xdc_dst/tdc_v16.xdc
add_files -fileset constrs_1 $xdc_dst/tdc_v16.xdc
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
update_compile_order -fileset sources_1

# --- BD ---------------------------------------------------------------------
open_bd_design [get_files wr_bd.bd]
foreach c {wb_bridge_0 drp_common_0 fmeter_0} {
  if {[catch {update_module_reference [get_bd_cells $c]} e]} {
    puts "NOTE: refresh $c saltato: $e"
  }
}

set bid [create_bd_cell -type module -reference build_id  build_id_0]
set tdc [create_bd_cell -type module -reference tdc_carry tdc_0]

# smartconnect: +2 master
set sc [get_bd_cells smartconnect_0]
set n  [get_property CONFIG.NUM_MI $sc]
set_property CONFIG.NUM_MI [expr {$n + 2}] $sc
set mi_bid [format "M%02d_AXI" $n]
set mi_tdc [format "M%02d_AXI" [expr {$n + 1}]]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/$mi_bid] [get_bd_intf_pins build_id_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/$mi_tdc] [get_bd_intf_pins tdc_0/s_axi]

# clock/reset AXI: ci si aggancia alle reti esistenti passando un pin GIA'
# connesso (fmeter) + i pin nuovi. NB: passare l'oggetto rete posizionalmente
# NON funziona (la rete viene ignorata e nasce una rete nuova senza sorgente).
connect_bd_net [get_bd_pins fmeter_0/s_axi_aclk] \
  [get_bd_pins build_id_0/s_axi_aclk] [get_bd_pins tdc_0/s_axi_aclk]
connect_bd_net [get_bd_pins fmeter_0/s_axi_aresetn] \
  [get_bd_pins build_id_0/s_axi_aresetn] [get_bd_pins tdc_0/s_axi_aresetn]

# porte verso il top; il clock di riferimento del TDC e' la porta fmeter_clk
# gia' esistente (TXUSRCLK2, WR-disciplinato)
create_bd_port -dir I tdc_hit_pmod
create_bd_port -dir I tdc_pps

# clock del TDC: la porta fmeter_clk e' gia' connessa a fmeter_0/meas_clk ->
# porta + pin nuovo si aggancia alla rete esistente
connect_bd_net [get_bd_ports fmeter_clk] [get_bd_pins tdc_0/clk_ref_62m5]

connect_bd_net [get_bd_ports tdc_hit_pmod] [get_bd_pins tdc_0/tdc_hit_pmod]
connect_bd_net [get_bd_ports tdc_pps]      [get_bd_pins tdc_0/pps_i]

# indirizzi
assign_bd_address -target_address_space /zynq_ultra_ps_e_0/Data \
  [get_bd_addr_segs build_id_0/s_axi/reg0] -offset 0xA0050000 -range 4K
assign_bd_address -target_address_space /zynq_ultra_ps_e_0/Data \
  [get_bd_addr_segs tdc_0/s_axi/reg0] -offset 0xA0060000 -range 4K

validate_bd_design
save_bd_design

# wrapper rigenerato (il top lo istanzia come componente: l'entity deve combaciare)
make_wrapper -files [get_files wr_bd.bd] -top -force
update_compile_order -fileset sources_1

puts "ADDR MAP:"
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces /zynq_ultra_ps_e_0/Data]] {
  puts [format "  %-28s %s  %s" [get_property NAME $seg] [get_property OFFSET $seg] [get_property RANGE $seg]]
}
puts "V16_INTEGRATION_DONE"
close_project
