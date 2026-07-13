# KR260 SFP+ DRP project constraints
# From KR260 schematic (xtp743):
#   Sheet 14: SFP+ uses GTH_DP2
#   Sheet 16: GTH_REFCLK0_C2M_P/N = 156.25 MHz (oscillator U90)
#
# Bonded GTHE4 sites on xck26-sfvc784 (KR260):
#   X0Y4=DP0, X0Y5=DP1, X0Y6=DP2(SFP+), X0Y7=DP3
#   GTHE4_COMMON_X0Y1 serves quad Y4-Y7

# --- GTH placement ---
set_property LOC GTHE4_CHANNEL_X0Y6 \
    [get_cells -hierarchical -filter {REF_NAME == GTHE4_CHANNEL}]

set_property LOC GTHE4_COMMON_X0Y1 \
    [get_cells -hierarchical -filter {REF_NAME == GTHE4_COMMON}]

# --- Reference clock: 156.25 MHz from KR260 U90 oscillator ---
create_clock -period 6.400 -name sfp_refclk \
    [get_ports sfp_refclk_p]

# --- Bitstream ---
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# IBUFDS_GTE4 is embedded in GTHE4_COMMON site (Quad 1)
set_property LOC GTHE4_COMMON_X0Y1     [get_cells -hierarchical -filter {REF_NAME == IBUFDS_GTE4}]

# --- TXOUTCLK (TXPRGDIVCLK via BUFG_GT) per frequenzimetro ---
# Frequenza approssimativa: 10312.5 Gbps / 64 ≈ 161.1 MHz → periodo 6.21 ns
# Aggiornare il periodo se si cambia line rate o PROGDIV ratio via GTH Wizard.
create_clock -period 6.210 -name txoutclk \
    [get_pins -hierarchical -filter {NAME =~ *u_bufg_txout/O}]

# --- CDC freq_counter: 3 false paths ---
# 1) Dati multi-bit: meas_cnt_latch (txoutclk) → freq_count (clk_pl_0)
#    Stabili per handshake toggle-synchronizer quando campionati.
set_false_path \
    -from [get_cells -hierarchical -filter {NAME =~ *meas_cnt_latch_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *freq_count_reg*}]

# 2) Sincronizzatore 2-FF gate_en: clk_pl_0 → txoutclk
#    Ingresso metastabile per definizione; Vivado non deve timarlo.
set_false_path \
    -to [get_cells -hierarchical -filter {NAME =~ *gate_en_meas_sync_reg*}]

# 3) Sincronizzatore 2-FF toggle result: txoutclk → clk_pl_0
set_false_path \
    -to [get_cells -hierarchical -filter {NAME =~ *tog_ref_sync_reg*}]
