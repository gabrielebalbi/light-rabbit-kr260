# v16 — TDC a catena di carry
# Ingresso esterno: E10 = PMOD1 pin fisico 3 (bank 45 HD, 3.3 V)
set_property PACKAGE_PIN E10 [get_ports tdc_hit_pmod_i]
set_property IOSTANDARD LVCMOS33 [get_ports tdc_hit_pmod_i]
set_false_path -from [get_ports tdc_hit_pmod_i]

# Il clock del TDC (375 MHz, MMCM dentro tdc_0, riferito a TXUSRCLK2) e' un
# dominio a se': tutti i passaggi da/verso gli altri domini sono gestiti nel
# modulo (XPM FIFO asincrona, doppi FF ASYNC_REG, toggle-sync). Dichiararlo
# asincrono rispetto ai gruppi gia' definiti in kr260_wr_sdm_clocks.xdc.
set_clock_groups -asynchronous -quiet \
    -group [get_clocks -quiet -of_objects [get_pins -hierarchical -quiet -filter {NAME =~ *tdc_0*u_bufg_tdc/O}]] \
    -group [get_clocks -quiet {clk_pl_0 clk_freerun_62m5 clk_sys_62m5}] \
    -group [get_clocks -quiet {txoutclk_out* *gtwiz_userclk_tx*}] \
    -group [get_clocks -quiet {rxoutclk_out* *gtwiz_userclk_rx*}] \
    -group [get_clocks -quiet -of_objects [get_pins -hierarchical -quiet -filter {NAME =~ *u_wr*cmp_bufg_dmtd/O}]]

# Cintura e bretelle: la catena di carry e il primo rank di cattura sono
# asincroni per costruzione (l'informazione di fase sta proprio li').
set_false_path -to [get_cells -hier -quiet -regexp {.*u_dl/therm_r1_reg.*}]

# Ring oscillator (u_ring, sorgente di calibrazione): loop combinatorio
# intenzionale, va esplicitamente permesso in DRC (altrimenti la synth lo
# spezza/rifiuta) e tolto dalla STA (non ha senso analizzare staticamente
# il timing di un anello libero che oscilla per costruzione).
set_property ALLOW_COMBINATORIAL_LOOPS TRUE \
    [get_nets -hier -quiet -regexp {.*u_ring/stage.*}]
set_false_path -through [get_pins -hier -quiet -regexp {.*u_ring/u_nand/O}]
