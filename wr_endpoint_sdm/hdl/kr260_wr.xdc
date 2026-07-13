# ============================================================
# kr260_wr.xdc — KR260 White Rabbit PTP node constraints
# Target: xck26-sfvc784-2LV-c
# ============================================================

# ------------------------------------------------------------
# SFP+ 156.25 MHz reference clock
# GTH_REFCLK0 (U90 oscillator -> Quad X0Y1 = bank 224, refclk0)
# Schematic net GTH_REFCLK0_C2M_P/N -> SOM240_2 C3 (P) / C4 (N)
# Package pad MGTREFCLK0P/N_224 -> FPGA pins Y6 (P) / Y5 (N)
# ------------------------------------------------------------
set_property PACKAGE_PIN Y6 [get_ports sfp_refclk_p]

# ------------------------------------------------------------
# SFP+ GTH serial data
# GTH_DP2 = GTHE4_CHANNEL_X0Y6 (Quad X0Y1 = bank 224, channel 2)
# RX (SFP RD, net GTH_DP2_C2M) -> SOM240_2 B1/B2 -> MGTHRXP2/N_224 = T2/T1
# TX (SFP TD, net GTH_DP2_M2C) -> SOM240_2 B5/B6 -> MGTHTXP2/N_224 = R4/R3
# (only the P pin is constrained; the N pin is implied by the GT pair)
# ------------------------------------------------------------
set_property PACKAGE_PIN T2 [get_ports sfp_rx_p]
set_property PACKAGE_PIN R4 [get_ports sfp_tx_p]

create_clock -period 6.400 -name clk_sfp_ref [get_ports sfp_refclk_p]

# GTH transceiver placement — aggancia SOLO la primitiva GTHE4_CHANNEL
# (filtro per REF_NAME: evita di colpire le LUT derivate *_PRIM_INST_i_*).
# Questo XDC e' l'unica fonte di verita' per il LOC del canale (il default
# X0Y0 del template wizard e' disabilitato in gthe4_lp/gtwizard_ultrascale_2.xdc).
set_property LOC GTHE4_CHANNEL_X0Y6 \
    [get_cells -hierarchical -filter {REF_NAME == GTHE4_CHANNEL && NAME =~ *u_wr/cmp_gth/*}]
# ------------------------------------------------------------
# SFP I2C (MOD_DEF1 = SCL, MOD_DEF2 = SDA)
# SOM240_2 B49/B50 — package pins AB11/AC11
# Bus pilotato dal PS-side AXI IIC IP (scripts/add_axi_iic.tcl); le porte
# sfp_iic_scl_io/sfp_iic_sda_io provengono ora dal wrapper del block design.
# ------------------------------------------------------------
set_property PACKAGE_PIN AB11 [get_ports sfp_iic_scl_io]
set_property PACKAGE_PIN AC11 [get_ports sfp_iic_sda_io]
set_property IOSTANDARD LVCMOS33 [get_ports sfp_iic_scl_io]
set_property IOSTANDARD LVCMOS33 [get_ports sfp_iic_sda_io]
# Pull-up interni: i fronti di salita SFP sul campo sono marginali (ACK
# intermittenti) — aiutano se i pull-up del carrier sono deboli/assenti.
set_property PULLUP TRUE [get_ports sfp_iic_scl_io]
set_property PULLUP TRUE [get_ports sfp_iic_sda_io]

# ------------------------------------------------------------
# SFP TX disable (active-high to SFP module)
# SOM240_2 A47 — package pin Y10
# ------------------------------------------------------------
set_property PACKAGE_PIN Y10 [get_ports sfp_tx_disable]
set_property IOSTANDARD LVCMOS33 [get_ports sfp_tx_disable]

# ------------------------------------------------------------
# PPS output — PMOD1 IO8, LVCMOS33
# Package pin B11 = som240_1_c22 = HDA18 (bank 45, not clock-capable)
set_property PACKAGE_PIN B11 [get_ports pps_p_o]
set_property IOSTANDARD LVCMOS33 [get_ports pps_p_o]
# ------------------------------------------------------------

# ------------------------------------------------------------
# PPS replica on a clock-capable PMOD pin — PMOD1 IO6, LVCMOS33
# Package pin E12 = som240_1_b21 = HDA16_CC = IO_L8P_HDGC_45 (bank 45, HDGC)
set_property PACKAGE_PIN E12 [get_ports pps_pmod_o]
set_property IOSTANDARD LVCMOS33 [get_ports pps_pmod_o]
# ------------------------------------------------------------

# ------------------------------------------------------------
# Status LEDs — KR260 DS8 (LED0) = link, DS7 (LED1) = activity
set_property PACKAGE_PIN E8 [get_ports led_link_o]
set_property PACKAGE_PIN F8 [get_ports led_act_o]
set_property IOSTANDARD LVCMOS18 [get_ports led_link_o]
set_property IOSTANDARD LVCMOS18 [get_ports led_act_o]
# ------------------------------------------------------------

# ------------------------------------------------------------
# SFP-cage LEDs (v15) — LED1 = tm_time_valid, LED2 = fabric heartbeat
# G8 = som240_1_a12 = HPA13P = IO_L16P_T2U_N6_QBC_AD3P_66  (LED1)
# F7 = som240_1_a13 = HPA13N = IO_L16N_T2U_N7_QBC_AD3N_66  (LED2)
set_property PACKAGE_PIN G8 [get_ports led1_o]
set_property PACKAGE_PIN F7 [get_ports led2_o]
set_property IOSTANDARD LVCMOS18 [get_ports led1_o]
set_property IOSTANDARD LVCMOS18 [get_ports led2_o]
# ------------------------------------------------------------

# ------------------------------------------------------------
# Clock groups: the three independent clock domains in this design
#   clk_sfp_ref : 156.25 MHz SFP oscillator (GTH refclk)
#   pl_clk0     : 125 MHz PS PLL (DMTD reference, independent of SFP osc)
#   clk_sys     : 62.5 MHz derived from SFP refclk (via BUFG_GT + MMCM)
#   clk_dmtd    : ~62.5 MHz derived from pl_clk0 (toggle FF)
#
# clk_sys and clk_dmtd are asynchronous to each other; the WR DMTD
# discriminator intentionally exploits this phase drift.
# ------------------------------------------------------------
# Async group between SFP refclk and the DMTD toggle clock (derived from pl_clk0).
# The DMTD register may be anywhere in the hierarchy; use -quiet to suppress if absent.
set_clock_groups -asynchronous -quiet \
    -group [get_clocks -include_generated_clocks clk_sfp_ref] \
    -group [get_clocks -of_objects [get_pins -hierarchical -quiet -filter {NAME =~ *u_wr*cmp_bufg_dmtd/O}] -quiet]

# pl_clk0 (PS global clock) feeds the DMTD MMCM CLKIN1 -> backbone route.
set _dmtd_ckin [get_pins -hierarchical -quiet -filter {NAME =~ *u_wr*cmp_mmcm_dmtd*CLKIN1}]
if {[llength $_dmtd_ckin]} { set_property CLOCK_DEDICATED_ROUTE BACKBONE $_dmtd_ckin }

# OOC refclk constraint for GTHE4 Wizard (6.4 ns = 156.25 MHz)
# This is set in hdl/ip/gthe4_lp/phy_ref_clk_156m25/gtwizard_ultrascale_2_ooc.xdc
# but repeated here for in-context awareness.
# create_clock -period 6.4 [get_ports sfp_refclk_p]  -- already set above

# ------------------------------------------------------------
# False paths: async resets and open-drain I2C
# ------------------------------------------------------------
set_false_path -from [get_ports sfp_iic_scl_io]
set_false_path -from [get_ports sfp_iic_sda_io]
set_false_path -to   [get_ports sfp_iic_scl_io]
set_false_path -to   [get_ports sfp_iic_sda_io]
set_false_path -to   [get_ports sfp_tx_disable]

# ------------------------------------------------------------
# DRC severity overrides
# sfp_refclk_p/n: MGTREFCLK pads — LOC is implicit via IBUFDS_GTE4 placement
# ------------------------------------------------------------
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]

# ------------------------------------------------------------
# LAB bbfix7: clock del PHY su PMOD1 per misura frequenzimetro (toggle FF clk/2, bank 45 HD)
# tx_clk_pmod_o = TXUSRCLK2/2 -> 31.250000 MHz -> H12 = PMOD1 pin fisico 1 (HDA11)
# rx_clk_pmod_o = CDR/2       -> 31.25 MHz     -> B10 = PMOD1 pin fisico 2 (HDA15)
set_property PACKAGE_PIN H12 [get_ports tx_clk_pmod_o]
set_property PACKAGE_PIN B10 [get_ports rx_clk_pmod_o]
set_property IOSTANDARD LVCMOS33 [get_ports tx_clk_pmod_o]
set_property IOSTANDARD LVCMOS33 [get_ports rx_clk_pmod_o]
# uscite di sola misura: nessun requisito di timing
set_false_path -to [get_ports tx_clk_pmod_o]
set_false_path -to [get_ports rx_clk_pmod_o]
# ------------------------------------------------------------
