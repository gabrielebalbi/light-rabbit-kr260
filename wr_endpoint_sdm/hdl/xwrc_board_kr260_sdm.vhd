-------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 (KR260 SDM port — Light Rabbit su KR260)
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0+
-------------------------------------------------------------------------------
-- Title      : WRPC board wrapper for KR260 — QPLL+SDM steering (fase 1)
-- Project    : kr260_wr_sdm (vedi shared_handoff/SDM_KR260_DESIGN.md)
-------------------------------------------------------------------------------
-- Architettura (fase 1, un solo quad GT, refclk U90 156.25 FISSA):
--   - PHY = wr_gthe4_phy_family7_xilinx_ip UFFICIALE, g_use_qpll_sdm=TRUE:
--     TX su QPLL0 fracN+SDM (sterzata dal DPLL), RX su QPLL1 intera (N=64).
--     8b10b HARDWARE del GT, 16-bit, buffer bypass (come ZCU102 "Light Rabbit"
--     e axau15). NIENTE LPDC.
--   - clk_sys = FREE-RUNNING (pl_clk0/2): il WRPC parte prima del GT ed e' lui
--     a rilasciare rst_i del PHY (architettura ufficiale axau15/zcu10x; con
--     clk_sys=tx_out si crea uno stallo uovo-gallina, visto sul banco 3/7).
--   - clk_ref = tx_out_clk del GT (TXPRGDIVCLK 62.5, segue la QPLL0 sterzata).
--   - DPLL DAC -> packing SDM stile axau15: sdm = base_i + (dac<<3 | "011").
--     base_i runtime (EMIO) per centrare la banda: N_eff=64.000 esatto e' al
--     BORDO frazionario con refclk fissa (vedi design doc, sez. Numerologia).
--   - DMTD: MMCM da PS pl_clk0 con fine-PS sterzato dal DAC HPLL (shim
--     mmcm_psen_dac, INVARIATO dal design v1 validato al banco).
--   - freerun del GT = pl_clk0/2 (indipendente dall'oscillatore SFP).
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.gencores_pkg.all;
use work.wrcore_pkg.all;
use work.wishbone_pkg.all;
use work.wr_fabric_pkg.all;
use work.endpoint_pkg.all;
use work.streamers_pkg.all;
use work.wr_xilinx_pkg.all;
use work.wr_board_pkg.all;

library unisim;
use unisim.vcomponents.all;

entity xwrc_board_kr260_sdm is
  generic (
    g_simulation                : integer              := 0;
    g_with_external_clock_input : boolean              := FALSE;
    g_fabric_iface              : t_board_fabric_iface := PLAIN;
    g_dpram_initf               : string               := "default_xilinx";
    g_diag_id                   : integer              := 0;
    g_diag_ver                  : integer              := 0;
    g_diag_ro_size              : integer              := 0;
    g_diag_rw_size              : integer              := 0);
  port (
    -- Active-low asynchronous reset (from PS pl_resetn0)
    areset_n_i       : in  std_logic;
    -- 125 MHz from PS pl_clk0 (freerun GT + sorgente MMCM DMTD)
    clk_125m_dmtd_i  : in  std_logic;
    -- 156.25 MHz differential SFP refclk (KR260 oscillator U90, FISSO)
    clk_sfp_ref_p_i  : in  std_logic;
    clk_sfp_ref_n_i  : in  std_logic;
    -- 62.5 MHz system clock output (= tx_out_clk del GT dopo il lock)
    clk_sys_62m5_o   : out std_logic;
    rst_sys_62m5_n_o : out std_logic;
    -- "PLL locked" complessivo (tx QPLL/userclk + MMCM DMTD) per gate AXI-WB
    pll_locked_o     : out std_logic;
    -- SDM runtime control (EMIO): parola base sommata al DAC DPLL
    sdm_base_i       : in  std_logic_vector(24 downto 0) := (others => '0');
    -- v7: polarita' TX runtime via EMIO 52 (Caso B: coppia TX invertita)
    tx_polarity_i    : in  std_logic := '0';
    -- Stato per EMIO: 0=tx_locked 1=dmtd_locked 2=phy_rdy 3=sdm_toggle,
    -- 15..4 = sdm_word(24 downto 13) (mirror parte alta parola SDM)
    sdm_stat_o       : out std_logic_vector(15 downto 0);
    -- Debug largo per ILA (XVC): 24..0=sdm_word, 40..25=dac_dpll_data, 41=dac_dpll_load
    sdm_dbg_o        : out std_logic_vector(41 downto 0);
    -- v9: debug phy16 per ILA (RX su rx_clk, TX su clk_ref)
    phy_rx_dbg_o     : out std_logic_vector(23 downto 0);
    phy_tx_dbg_o     : out std_logic_vector(17 downto 0);
    -- Clock di misura per PMOD (forwarding nel top, toggle /2)
    rx_rec_clk_o     : out std_logic;
    tx_usr_clk_o     : out std_logic;
    -- DRP del GTHE4_COMMON (QPLL0_FBDIV, SDM_CFG*) via axi_drp_bridge nel BD
    drp_common_clk_i  : in  std_logic := '0';
    drp_common_addr_i : in  std_logic_vector(15 downto 0) := (others => '0');
    drp_common_di_i   : in  std_logic_vector(15 downto 0) := (others => '0');
    drp_common_en_i   : in  std_logic := '0';
    drp_common_we_i   : in  std_logic := '0';
    drp_common_do_o   : out std_logic_vector(15 downto 0);
    drp_common_rdy_o  : out std_logic;
    -- SFP+ GTH serial data
    sfp_txp_o        : out std_logic;
    sfp_txn_o        : out std_logic;
    sfp_rxp_i        : in  std_logic;
    sfp_rxn_i        : in  std_logic;
    -- SFP management
    sfp_det_i        : in  std_logic := '1';
    sfp_sda_i        : in  std_logic;
    sfp_sda_o        : out std_logic;
    sfp_scl_i        : in  std_logic;
    sfp_scl_o        : out std_logic;
    sfp_tx_fault_i   : in  std_logic := '0';
    sfp_tx_disable_o : out std_logic;
    sfp_los_i        : in  std_logic := '0';
    -- UART
    uart_rxd_i       : in  std_logic := '1';
    uart_txd_o       : out std_logic;
    -- Wishbone slave (from PS AXI via xwb_axi4lite_bridge)
    wb_slave_i       : in  t_wishbone_slave_in  := cc_dummy_slave_in;
    wb_slave_o       : out t_wishbone_slave_out;
    -- Timing outputs
    pps_p_o          : out std_logic;
    pps_led_o        : out std_logic;
    led_link_o       : out std_logic;
    led_act_o        : out std_logic;
    tm_link_up_o     : out std_logic;
    tm_time_valid_o  : out std_logic;
    tm_tai_o         : out std_logic_vector(39 downto 0);
    tm_cycles_o      : out std_logic_vector(27 downto 0));
end entity xwrc_board_kr260_sdm;

architecture struct of xwrc_board_kr260_sdm is

  ---------------------------------------------------------------------------
  -- Clocks
  ---------------------------------------------------------------------------
  signal clk_gth_ref      : std_logic;  -- IBUFDS_GTE4 O (156.25, refclk QPLL)
  signal clk_freerun_62m5 : std_logic;  -- pl_clk0/2 (init GT, indip. da U90)
  signal clk_sys          : std_logic;  -- = clk_freerun (free-running, dominio WRPC)
  signal clk_ref          : std_logic;  -- tx_out_clk del GT (62.5 sterzato, dominio ref)
  signal clk_dmtd         : std_logic;  -- MMCM DMTD 62.5 fine-PS

  -- DMTD MMCM (identico a v1)
  signal clk_dmtd_pll    : std_logic;
  signal clk_dmtd_fb     : std_logic;
  signal dmtd_locked     : std_logic;
  signal dmtd_psen       : std_logic;
  signal dmtd_psincdec   : std_logic;
  signal dmtd_psdone     : std_logic;

  -- WR SoftPLL DAC outputs
  signal dac_hpll_data   : std_logic_vector(19 downto 0);
  signal dac_hpll_load   : std_logic;
  signal dac_dpll_data   : std_logic_vector(19 downto 0);
  signal dac_dpll_load   : std_logic;

  -- SDM (packing stile axau15 + base runtime)
  signal sdm_word         : std_logic_vector(24 downto 0) := (others => '0');
  -- ultimo valore DAC caricato dal softpll (init centro scala = offset zero):
  -- serve al calcolo CONTINUO di sdm_word (fix out_sdm8: la base EMIO deve
  -- agire anche quando il softpll non scrive mai il DAC, es. loopback)
  signal dac_dpll_last    : std_logic_vector(19 downto 0) := x"80000";
  signal sdm_toggle       : std_logic := '0';
  -- fix out_sdm10 (v6): il GTHE4 campiona SDM0DATA SOLO su una transizione di
  -- SDM0TOGGLE (UG576). Prima il toggle derivava da dac_dpll_load -> in
  -- loopback (softpll muto) la sdm_word nuova non veniva MAI caricata nel
  -- modulatore. Ora: change-detect su sdm_word + sequenza 0->1->0 di 64 cicli
  -- (pattern del riferimento gthe4_sdm.vhd) con dato congelato in sdm_word_sent.
  signal sdm_word_sent    : std_logic_vector(24 downto 0) := (others => '0');
  signal sdm_cnt          : unsigned(5 downto 0) := (others => '0');

  ---------------------------------------------------------------------------
  -- Resets
  ---------------------------------------------------------------------------
  signal tx_locked       : std_logic;
  signal phy_rdy         : std_logic;
  signal phy_dbg         : std_logic_vector(15 downto 0);
  signal pll_arst        : std_logic;
  signal rstlogic_arst   : std_logic;
  signal rst_clk_in      : std_logic_vector(1 downto 0);
  signal rst_n_out       : std_logic_vector(1 downto 0);
  signal rst_sys_n       : std_logic;

  ---------------------------------------------------------------------------
  -- PHY <-> WR core
  ---------------------------------------------------------------------------
  signal phy16_to_wrc   : t_phy_16bits_to_wrc;
  signal phy16_from_wrc : t_phy_16bits_from_wrc;

begin

  ---------------------------------------------------------------------------
  -- 156.25 MHz SFP refclk: O diretto al GT (QPLL refclk); ODIV2 inutilizzato
  ---------------------------------------------------------------------------
  cmp_ibufds_gth : IBUFDS_GTE4
    generic map (
      REFCLK_EN_TX_PATH  => '0',
      REFCLK_HROW_CK_SEL => "00",
      REFCLK_ICNTL_RX    => "00")
    port map (
      I     => clk_sfp_ref_p_i,
      IB    => clk_sfp_ref_n_i,
      CEB   => '0',
      O     => clk_gth_ref,
      ODIV2 => open);

  ---------------------------------------------------------------------------
  -- Freerun 62.5 per l'init del GT: pl_clk0 (125) / 2 — indipendente da U90
  ---------------------------------------------------------------------------
  cmp_freerun_div : BUFGCE_DIV
    generic map (BUFGCE_DIVIDE => 2)
    port map (I => clk_125m_dmtd_i, CLR => '0', CE => '1',
              O => clk_freerun_62m5);

  -- Architettura ufficiale (axau15/zcu10x): clk_sys = free-running di board,
  -- clk_ref = tx_out del GT. Domini SEPARATI (nel v1 coincidevano via MMCM).
  clk_sys <= clk_freerun_62m5;

  ---------------------------------------------------------------------------
  -- DMTD clock: PS pl_clk0 -> MMCM (x8 /16) -> 62.5 MHz fine-phase steerable
  -- (INVARIATO dal v1: sterzato dal DAC HPLL via mmcm_psen_dac)
  ---------------------------------------------------------------------------
  pll_arst <= not areset_n_i;

  cmp_mmcm_dmtd : MMCME4_ADV
    generic map (
      BANDWIDTH            => "OPTIMIZED",
      CLKFBOUT_MULT_F      => 8.000000,
      CLKFBOUT_PHASE       => 0.000000,
      CLKFBOUT_USE_FINE_PS => "FALSE",
      CLKIN1_PERIOD        => 8.000000,
      CLKIN2_PERIOD        => 0.000000,
      CLKOUT0_DIVIDE_F     => 16.000000,
      CLKOUT0_DUTY_CYCLE   => 0.500000,
      CLKOUT0_PHASE        => 0.000000,
      CLKOUT0_USE_FINE_PS  => "TRUE",
      COMPENSATION         => "INTERNAL",
      DIVCLK_DIVIDE        => 1,
      IS_CLKFBIN_INVERTED  => '0',
      IS_CLKIN1_INVERTED   => '0',
      IS_CLKIN2_INVERTED   => '0',
      IS_CLKINSEL_INVERTED => '0',
      IS_PSEN_INVERTED     => '0',
      IS_PSINCDEC_INVERTED => '0',
      IS_PWRDWN_INVERTED   => '0',
      IS_RST_INVERTED      => '0',
      REF_JITTER1          => 0.010000,
      REF_JITTER2          => 0.010000,
      SS_EN                => "FALSE",
      SS_MODE              => "CENTER_HIGH",
      SS_MOD_PERIOD        => 10000,
      STARTUP_WAIT         => "FALSE")
    port map (
      CLKFBOUT  => clk_dmtd_fb,
      CLKOUT0   => clk_dmtd_pll,
      CLKFBIN   => clk_dmtd_fb,
      CLKIN1    => clk_125m_dmtd_i,
      CLKIN2    => '0',
      CLKINSEL  => '1',
      DADDR     => (others => '0'), DCLK => '0',
      DEN       => '0', DI => (others => '0'),
      DO        => open, DRDY => open, DWE => '0',
      CDDCREQ   => '0',
      LOCKED    => dmtd_locked,
      -- segno helper invertito come in v1 (railava a y_min)
      PSCLK     => clk_sys, PSEN => dmtd_psen, PSINCDEC => (not dmtd_psincdec),
      PSDONE    => dmtd_psdone,
      PWRDWN    => '0', RST => pll_arst);

  cmp_bufg_dmtd : BUFG
    port map (I => clk_dmtd_pll, O => clk_dmtd);

  -- HPLL DAC shim: SoftPLL helper 16-bit -> fine phase shift MMCM DMTD
  cmp_psen_dac_hpll : entity work.mmcm_psen_dac
    generic map (
      g_acc_bits => 18)
    port map (
      clk_sys_i  => clk_sys,
      rst_n_i    => rst_sys_n,
      dac_data_i => dac_hpll_data(15 downto 0),  -- helper invariato: low-16 = bit passati oggi (reg HW 16b troncava il word 20b)
      dac_load_i => dac_hpll_load,
      psclk_o    => open,
      psen_o     => dmtd_psen,
      psincdec_o => dmtd_psincdec,
      psdone_i   => dmtd_psdone);

  ---------------------------------------------------------------------------
  -- DPLL DAC -> parola SDM QPLL0.
  -- Frazione QPLL = SDM_DATA/2^24 (verificato su axau15: init 262143 con
  -- refclk 124.975605 e N=80 => N_eff = 80.015625 = 10 GHz ESATTI).
  -- Packing CENTRATO e CLAMPATO (diverso da axau15 che e' assoluto):
  --   sdm = clamp( base + (dac-32768)*8 , 0, 2^25-1 )
  -- => escursione DAC = +/-0.015625 di frazione = +/-244 ppm di line rate
  --    attorno a base/2^24; base runtime (EMIO) per centrare il punto di
  --    lavoro (con U90 fisso: FBDIV=64+base~0 se osc lento; FBDIV=63 via DRP
  --    + base~0.97*2^24 se osc veloce). Passo: ~7.5e-3 ppm/LSB DAC.
  ---------------------------------------------------------------------------
  p_dac_to_sdm : process(clk_sys)
    variable v_sum : signed(26 downto 0);
  begin
    if rising_edge(clk_sys) then
      -- campiona il DAC del softpll quando viene scritto
      if dac_dpll_load = '1' then
        dac_dpll_last <= dac_dpll_data;
      end if;

      -- calcolo CONTINUO (fix out_sdm8): prima era dentro
      -- "if sdm_toggle_shift(0)='1'" e a softpll fermo (loopback, nessun
      -- dac_dpll_load) la base EMIO non arrivava MAI a sdm_word
      v_sum := signed(resize(unsigned(sdm_base_i), 27)) +
               shift_right(resize(signed('0' & dac_dpll_last) - 524288, 27), 5);
      if v_sum < 0 then
        sdm_word <= (others => '0');
      elsif v_sum > 33554431 then              -- 2^25-1
        sdm_word <= (others => '1');
      else
        sdm_word <= std_logic_vector(resize(unsigned(v_sum), 25));
      end if;

      -- handshake verso il GT (fix out_sdm10): quando sdm_word cambia,
      -- congela il dato in sdm_word_sent e genera il toggle 0->1->0
      -- (64 cicli: 63..48 dato stabile, 47..16 toggle=1, 15..0 toggle=0;
      -- il modulatore campiona su ENTRAMBI i fronti a dato fermo)
      if sdm_cnt = 0 then
        if sdm_word /= sdm_word_sent then
          sdm_word_sent <= sdm_word;
          sdm_cnt <= (others => '1');
        end if;
      else
        if sdm_cnt(5 downto 4) = "00" then
          sdm_toggle <= '0';
        elsif sdm_cnt(5 downto 4) /= "11" then
          sdm_toggle <= '1';
        end if;
        sdm_cnt <= sdm_cnt - 1;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Reset sequencer: aspetta lock GT TX (userclk attivo) e MMCM DMTD
  ---------------------------------------------------------------------------
  -- NIENTE tx_locked qui: clk_sys e' free-running, il WRPC deve partire PRIMA
  -- del GT (e' lui a rilasciare rst_i del PHY: altrimenti stallo uovo-gallina,
  -- visto sul banco 3/7: FREQ_CNT=0, vUART muto).
  rstlogic_arst  <= (not areset_n_i) or (not dmtd_locked);
  rst_clk_in(0)  <= clk_sys;
  rst_clk_in(1)  <= clk_dmtd;

  cmp_reset : gc_reset_multi_aasd
    generic map (
      g_CLOCKS  => 2,
      g_RST_LEN => 16)
    port map (
      arst_i  => rstlogic_arst,
      clks_i  => rst_clk_in,
      rst_n_o => rst_n_out);

  rst_sys_n        <= rst_n_out(0);
  rst_sys_62m5_n_o <= rst_sys_n;
  pll_locked_o     <= tx_locked and dmtd_locked;

  ---------------------------------------------------------------------------
  -- GTHE4 WR PHY (UFFICIALE, xilinx_ip): 8b10b HW, 16-bit, QPLL SDM
  -- TX: QPLL0 fracN (VCO 10 GHz, N=64+frac) sterzata via sdm_word
  -- RX: QPLL1 intera (N=64) — il CDR insegue il partner
  ---------------------------------------------------------------------------
  cmp_gth : entity work.wr_gthe4_phy_family7_xilinx_ip
    generic map (
      g_simulation         => g_simulation,
      g_use_qpll_sdm       => TRUE,
      g_use_gclk_as_refclk => FALSE)
    port map (
      clk_gth_i        => clk_gth_ref,
      clk_freerun_i    => clk_freerun_62m5,
      tx_out_clk_o     => clk_ref,
      tx_locked_o      => tx_locked,
      tx_sdm_data_i    => sdm_word_sent,  -- v6: dato CONGELATO durante il toggle
      tx_polarity_i    => tx_polarity_i,  -- v7
      tx_sdm_toggle_i  => sdm_toggle,
      tx_data_i        => phy16_from_wrc.tx_data,
      tx_k_i           => phy16_from_wrc.tx_k,
      tx_disparity_o   => phy16_to_wrc.tx_disparity,
      tx_enc_err_o     => phy16_to_wrc.tx_enc_err,
      rx_rbclk_o       => phy16_to_wrc.rx_clk,
      rx_data_o        => phy16_to_wrc.rx_data,
      rx_k_o           => phy16_to_wrc.rx_k,
      rx_enc_err_o     => phy16_to_wrc.rx_enc_err,
      rx_bitslide_o    => phy16_to_wrc.rx_bitslide,
      rst_i            => phy16_from_wrc.rst,
      loopen_i         => "000",
      debug_i          => x"0000",
      debug_o          => phy_dbg,
      drp_common_clk_i  => drp_common_clk_i,
      drp_common_addr_i => drp_common_addr_i,
      drp_common_di_i   => drp_common_di_i,
      drp_common_en_i   => drp_common_en_i,
      drp_common_we_i   => drp_common_we_i,
      drp_common_do_o   => drp_common_do_o,
      drp_common_rdy_o  => drp_common_rdy_o,
      pad_txn_o        => sfp_txn_o,
      pad_txp_o        => sfp_txp_o,
      pad_rxn_i        => sfp_rxn_i,
      pad_rxp_i        => sfp_rxp_i,
      rdy_o            => phy_rdy);

  clk_sys_62m5_o <= clk_sys;
  tx_usr_clk_o   <= clk_ref;                  -- PMOD misura (toggle /2 nel top)
  rx_rec_clk_o   <= phy16_to_wrc.rx_clk;      -- PMOD misura

  phy16_to_wrc.rdy            <= phy_rdy;
  phy16_to_wrc.ref_clk        <= clk_ref;
  phy16_to_wrc.rx_sampled_clk <= '0';  -- niente DMTD sampler LPDC: path classico
  phy16_to_wrc.sfp_tx_fault   <= sfp_tx_fault_i;
  phy16_to_wrc.sfp_los        <= sfp_los_i;
  sfp_tx_disable_o            <= phy16_from_wrc.sfp_tx_disable;

  -- v9: specchio phy16 per ILA
  phy_rx_dbg_o(15 downto 0)  <= phy16_to_wrc.rx_data;
  phy_rx_dbg_o(17 downto 16) <= phy16_to_wrc.rx_k;
  phy_rx_dbg_o(18)           <= phy16_to_wrc.rx_enc_err;
  phy_rx_dbg_o(23 downto 19) <= phy16_to_wrc.rx_bitslide(4 downto 0);
  phy_tx_dbg_o(15 downto 0)  <= phy16_from_wrc.tx_data;
  phy_tx_dbg_o(17 downto 16) <= phy16_from_wrc.tx_k;

  -- Stato SDM/PHY per EMIO (lettura runtime senza JTAG)
  -- v4: mappa diagnostica bring-up TX del GT (per EMIO, verdetto senza JTAG)
  --  0=tx_done 1=txpmareset_done(proxy QPLL lock) 2=txprgdivreset_done
  --  3=userclk_tx_active 4=serdes_ready 5=rx_cdr_stable 6=dmtd_locked 7=phy_rdy
  --  8=sdm_toggle  15..9 = sdm_word(24..18) (mirror parte alta, 7 bit)
  sdm_stat_o(0)           <= phy_dbg(0);
  sdm_stat_o(1)           <= phy_dbg(1);
  sdm_stat_o(2)           <= phy_dbg(2);
  sdm_stat_o(3)           <= phy_dbg(3);
  sdm_stat_o(4)           <= phy_dbg(4);
  sdm_stat_o(5)           <= phy_dbg(5);
  sdm_stat_o(6)           <= dmtd_locked;
  sdm_stat_o(7)           <= phy_rdy;
  sdm_stat_o(8)           <= sdm_toggle;
  sdm_stat_o(15 downto 9) <= sdm_word(24 downto 18);

  -- debug largo per ILA via XVC (stesso dominio clk_sys del p_dac_to_sdm)
  sdm_dbg_o(24 downto 0)  <= sdm_word;
  sdm_dbg_o(40 downto 25) <= dac_dpll_data(19 downto 4);
  sdm_dbg_o(41)           <= dac_dpll_load;

  ---------------------------------------------------------------------------
  -- WR PTP Core (common board wrapper) — come v1, senza LPDC MDIO
  ---------------------------------------------------------------------------
  cmp_board_common : xwrc_board_common
    generic map (
      g_simulation                => g_simulation,
      g_with_external_clock_input => g_with_external_clock_input,
      g_board_name                => "KRSD",
      g_phys_uart                 => TRUE,
      g_virtual_uart              => TRUE,
      g_aux_clks                  => 0,
      g_ep_rxbuf_size             => 1024,
      g_tx_runt_padding           => TRUE,
      g_dpram_initf               => g_dpram_initf,
      g_dpram_size                => 196608/4,
      g_interface_mode            => PIPELINED,
      g_address_granularity       => BYTE,
      g_aux_sdb                   => c_wrc_periph3_sdb,
      g_softpll_enable_debugger   => FALSE,
      g_vuart_fifo_size           => 1024,
      g_pcs_16bit                 => TRUE,
      g_diag_id                   => g_diag_id,
      g_diag_ver                  => g_diag_ver,
      g_diag_ro_size              => g_diag_ro_size,
      g_diag_rw_size              => g_diag_rw_size,
      g_dac_bits                  => 20,
      g_fabric_iface              => g_fabric_iface)
    port map (
      clk_sys_i          => clk_sys,
      clk_dmtd_i         => clk_dmtd,
      clk_ref_i          => clk_ref,
      clk_10m_ext_i      => '0',
      pps_ext_i          => '0',
      rst_n_i            => rst_sys_n,
      -- HPLL DAC -> shim MMCM DMTD (fine-PS)
      dac_hpll_load_p1_o => dac_hpll_load,
      dac_hpll_data_o    => dac_hpll_data,
      -- DPLL DAC -> parola SDM QPLL0
      dac_dpll_load_p1_o => dac_dpll_load,
      dac_dpll_data_o    => dac_dpll_data,
      -- PHY (16-bit GTHE4, 8b10b hardware)
      phy16_o            => phy16_from_wrc,
      phy16_i            => phy16_to_wrc,
      -- phy_mdio_master_*: default dummy (nessun LPDC)
      -- EEPROM I2C (assente)
      scl_o              => open,
      scl_i              => '1',
      sda_o              => open,
      sda_i              => '1',
      -- SFP I2C
      sfp_scl_o          => sfp_scl_o,
      sfp_scl_i          => sfp_scl_i,
      sfp_sda_o          => sfp_sda_o,
      sfp_sda_i          => sfp_sda_i,
      sfp_det_i          => sfp_det_i,
      sfp_mux_sel_i      => '0',
      sfp1_scl_o         => open,
      sfp1_scl_i         => '1',
      sfp1_sda_o         => open,
      sfp1_sda_i         => '1',
      sfp1_det_i         => '0',
      spi_sclk_o         => open,
      spi_ncs_o          => open,
      spi_mosi_o         => open,
      spi_miso_i         => '0',
      uart_rxd_i         => uart_rxd_i,
      uart_txd_o         => uart_txd_o,
      owr_pwren_o        => open,
      owr_en_o           => open,
      owr_i              => (others => '1'),
      btn1_i             => '1',
      btn2_i             => '1',
      wb_slave_i         => wb_slave_i,
      wb_slave_o         => wb_slave_o,
      led_act_o          => led_act_o,
      led_link_o         => led_link_o,
      pps_p_o            => pps_p_o,
      pps_led_o          => pps_led_o,
      tm_link_up_o       => tm_link_up_o,
      tm_time_valid_o    => tm_time_valid_o,
      tm_tai_o           => tm_tai_o,
      tm_cycles_o        => tm_cycles_o);

end architecture struct;
