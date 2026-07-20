-------------------------------------------------------------------------------
-- SPDX-FileCopyrightText: 2026 (KR260 SDM — Light Rabbit su KR260)
-- SPDX-License-Identifier: CERN-OHL-W-2.0+
-------------------------------------------------------------------------------
-- Title      : Top level KR260 WR endpoint con steering QPLL+SDM
-- Project    : kr260_wr_sdm (vedi shared_handoff/SDM_KR260_DESIGN.md)
-------------------------------------------------------------------------------
-- Derivato dal top v1 (kr260_wr.vhd): stesso BD (PS+smartconnect+iic+wb_bridge)
-- ESTESO con axi_drp_bridge_common (0xA0020000, DRP GTHE4_COMMON: QPLL0_FBDIV
-- e SDM_CFG*) e freq_counter (0xA0030000, misura tx clk) — stessi indirizzi
-- del progetto esercizio sfp_drp_kr260_sdm: sdm_sweep.py/notebook riusabili.
--
-- EMIO map (differenze dal v1):
--   IN  0..6  : invariati (locked, rst_n, diag WB rotta-A)
--   IN  7..22 : sdm_stat(15:0) — 0=tx_locked 1=dmtd_locked 2=phy_rdy
--               3=sdm_toggle, 15..4=sdm_word(24:13)  (gpiochip 85..100)
--   OUT 54..78: sdm_base(24:0) — parola base sommata al DAC DPLL
--               (gpiochip 466..490). I vecchi knob LPDC 40..52 NON esistono.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.wishbone_pkg.all;
use work.wr_board_pkg.all;
use work.wr_kr260_pkg.all;

library unisim;
use unisim.vcomponents.all;

entity kr260_wr_sdm is
  generic (
    g_dpram_initf : string := "../../sw/precompiled/wrps-sw-v5_babywr/wrc.bram");
  port (
    -- 156.25 MHz SFP reference clock from KR260 oscillator U90
    sfp_refclk_p   : in    std_logic;
    sfp_refclk_n   : in    std_logic;
    -- SFP+ GTH serial data
    sfp_tx_p       : out   std_logic;
    sfp_tx_n       : out   std_logic;
    sfp_rx_p       : in    std_logic;
    sfp_rx_n       : in    std_logic;
    -- SFP I2C — open-drain bidir (AB11/AC11)
    sfp_iic_scl_io : inout std_logic;
    sfp_iic_sda_io : inout std_logic;
    -- SFP TX disable (active-high, Y10)
    sfp_tx_disable : out   std_logic;
    -- PPS output (B11 = PMOD1 IO8, HDA18)
    pps_p_o        : out   std_logic;
    -- PPS replica on clock-capable PMOD1 IO6 pin (E12 = HDA16_CC, bank 45)
    pps_pmod_o     : out   std_logic;
    -- Clock su PMOD1 per misura frequenzimetro (toggle FF clk/2, bank 45 HD)
    tx_clk_pmod_o  : out   std_logic;   -- H12 = PMOD1 pin1: TXUSRCLK2/2
    rx_clk_pmod_o  : out   std_logic;   -- B10 = PMOD1 pin2: CDR/2
    -- v16: ingresso TDC (E10 = PMOD1 pin3, bank 45 HD, LVCMOS33)
    tdc_hit_pmod_i : in    std_logic;
    -- Status LEDs
    led_link_o     : out   std_logic;
    led_act_o      : out   std_logic;
    -- LEDs next to the SFP cage (LED1 = G8, LED2 = F7; bank 66 HPA13P/N)
    led1_o         : out   std_logic;
    led2_o         : out   std_logic);
end entity kr260_wr_sdm;

architecture struct of kr260_wr_sdm is

  component led_heartbeat is
    generic (
      g_clk_freq_hz : natural := 62500000;
      g_breath_ms   : natural := 4000);
    port (
      clk_i   : in  std_logic;
      rst_n_i : in  std_logic;
      led_o   : out std_logic);
  end component led_heartbeat;

  -- BD wrapper ESTESO (build_sdm.tcl aggiunge drp bridge COMMON + freq counter)
  component wr_bd_wrapper is
    port (
      pl_clk0         : out std_logic;
      pl_resetn0      : out std_logic;
      wb_adr          : out std_logic_vector(31 downto 0);
      wb_dat_m2s      : out std_logic_vector(31 downto 0);
      wb_sel          : out std_logic_vector(3 downto 0);
      wb_cyc          : out std_logic;
      wb_stb          : out std_logic;
      wb_we           : out std_logic;
      wb_dat_s2m      : in  std_logic_vector(31 downto 0);
      wb_ack          : in  std_logic;
      wb_stall        : in  std_logic;
      wb_err          : in  std_logic;
      wb_rty          : in  std_logic;
      emio_gpio_i     : in  std_logic_vector(94 downto 0);
      emio_gpio_o     : out std_logic_vector(94 downto 0);
      sfp_iic_scl_io  : inout std_logic;
      sfp_iic_sda_io  : inout std_logic;
      -- DRP master del bridge COMMON (dominio pl_clk0)
      drpc_addr       : out std_logic_vector(9 downto 0);
      drpc_di         : out std_logic_vector(15 downto 0);
      drpc_en         : out std_logic;
      drpc_we         : out std_logic;
      drpc_do         : in  std_logic_vector(15 downto 0);
      drpc_rdy        : in  std_logic;
      -- clock misurato dal freq_counter; in v16 e' anche il riferimento
      -- dell'MMCM del TDC (TXUSRCLK2 = 62.5 MHz WR-disciplinato)
      fmeter_clk      : in  std_logic;
      -- v16: TDC a catena di carry + registri build_id (dentro il BD)
      tdc_hit_pmod    : in  std_logic;
      tdc_pps         : in  std_logic);
  end component wr_bd_wrapper;

  signal pl_clk0      : std_logic;
  signal pl_resetn0   : std_logic;
  signal clk_sys_62m5 : std_logic;
  signal rst_sys_n    : std_logic;

  signal pll_locked_s : std_logic;

  signal tx_usr_clk_dbg : std_logic;
  signal rx_rec_clk_dbg : std_logic;
  signal phy_rx_dbg_s   : std_logic_vector(23 downto 0);  -- v9 ILA phy16
  signal phy_tx_dbg_s   : std_logic_vector(17 downto 0);
  signal tx_clk_tog     : std_logic := '0';
  signal rx_clk_tog     : std_logic := '0';

  signal locked_meta, locked_sync : std_logic;
  signal rstsys_meta, rstsys_sync : std_logic;

  signal emio_gpio_i_s : std_logic_vector(94 downto 0);
  signal emio_gpio_o_s : std_logic_vector(94 downto 0);

  signal xc_slave_rst_n : std_logic;

  signal wb_adr_s     : std_logic_vector(31 downto 0);
  signal wb_dat_m2s_s : std_logic_vector(31 downto 0);
  signal wb_sel_s     : std_logic_vector(3 downto 0);
  signal wb_cyc_s     : std_logic;
  signal wb_stb_s     : std_logic;
  signal wb_we_s      : std_logic;
  signal wb_dat_s2m_s : std_logic_vector(31 downto 0);
  signal wb_ack_s     : std_logic;
  signal wb_stall_s   : std_logic;
  signal wb_err_s     : std_logic;
  signal wb_rty_s     : std_logic;

  signal brg_master_out : t_wishbone_master_out;
  signal brg_master_in  : t_wishbone_master_in;

  signal wb_slave_in  : t_wishbone_slave_in;
  signal wb_slave_out : t_wishbone_slave_out;

  -- Diagnostica WB rotta-A (sticky, EMIO 2..6) — invariata dal v1
  signal dbg_seen_cyc    : std_logic;
  signal dbg_seen_ack    : std_logic;
  signal dbg_multi_push  : std_logic;
  signal dbg_stall_wedge : std_logic;
  signal dbg_seen_push   : std_logic;
  signal push_cnt        : unsigned(1 downto 0);
  signal stall_cnt       : unsigned(10 downto 0);

  -- Stato SDM dal board wrapper -> EMIO 7..22
  signal sdm_stat_s : std_logic_vector(15 downto 0);

  -- Debug largo dal wrapper -> ILA (XVC): 24..0=sdm_word, 40..25=dac, 41=dac_load
  signal sdm_dbg_s : std_logic_vector(41 downto 0);

  -- ILA istanziata (flusso a istanza: compatibile col debug_bridge AXI-to-BSCAN;
  -- la netlist-insertion NON lo e' — vedi XVC_debug_senza_JTAG_notes.md)
  component ila_sdm is
    port (
      clk    : in std_logic;
      probe0 : in std_logic_vector(24 downto 0);  -- sdm_word
      probe1 : in std_logic_vector(15 downto 0);  -- dac_dpll_data
      probe2 : in std_logic_vector(0 downto 0);   -- dac_dpll_load
      probe3 : in std_logic_vector(15 downto 0);  -- sdm_stat
      probe4 : in std_logic_vector(24 downto 0)); -- sdm_base (EMIO)
  end component;

  component ila_rx16 is
    port (
      clk    : in std_logic;
      probe0 : in std_logic_vector(15 downto 0);  -- rx_data (phy16 -> PCS)
      probe1 : in std_logic_vector(1 downto 0);   -- rx_k
      probe2 : in std_logic_vector(0 downto 0);   -- rx_enc_err
      probe3 : in std_logic_vector(4 downto 0));  -- rx_bitslide
  end component;

  component ila_tx16 is
    port (
      clk    : in std_logic;
      probe0 : in std_logic_vector(15 downto 0);  -- tx_data (PCS -> phy16)
      probe1 : in std_logic_vector(1 downto 0));  -- tx_k
  end component;

  -- DRP COMMON: BD (10 bit) -> PHY (16 bit, zero-extend)
  signal drpc_addr_s : std_logic_vector(9 downto 0);
  signal drpc_di_s   : std_logic_vector(15 downto 0);
  signal drpc_en_s   : std_logic;
  signal drpc_we_s   : std_logic;
  signal drpc_do_s   : std_logic_vector(15 downto 0);
  signal drpc_rdy_s  : std_logic;

  signal pps_s        : std_logic;
  signal pps_led_s    : std_logic;
  signal link_up_s    : std_logic;
  signal hb_led_s     : std_logic;
  signal tm_time_vld_s : std_logic;

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of locked_meta : signal is "TRUE";
  attribute ASYNC_REG of locked_sync : signal is "TRUE";
  attribute ASYNC_REG of rstsys_meta : signal is "TRUE";
  attribute ASYNC_REG of rstsys_sync : signal is "TRUE";

begin

  -- LAB: laser sempre abilitato (bypass sfp_tx_disable del WR core)
  sfp_tx_disable <= '0';

  ---------------------------------------------------------------------------
  -- PS block design wrapper (esteso con DRP COMMON + freq counter)
  ---------------------------------------------------------------------------
  u_bd : wr_bd_wrapper
    port map (
      pl_clk0        => pl_clk0,
      pl_resetn0     => pl_resetn0,
      wb_adr         => wb_adr_s,
      wb_dat_m2s     => wb_dat_m2s_s,
      wb_sel         => wb_sel_s,
      wb_cyc         => wb_cyc_s,
      wb_stb         => wb_stb_s,
      wb_we          => wb_we_s,
      wb_dat_s2m     => wb_dat_s2m_s,
      wb_ack         => wb_ack_s,
      wb_stall       => wb_stall_s,
      wb_err         => wb_err_s,
      wb_rty         => wb_rty_s,
      emio_gpio_i    => emio_gpio_i_s,
      emio_gpio_o    => emio_gpio_o_s,
      sfp_iic_scl_io => sfp_iic_scl_io,
      sfp_iic_sda_io => sfp_iic_sda_io,
      drpc_addr      => drpc_addr_s,
      drpc_di        => drpc_di_s,
      drpc_en        => drpc_en_s,
      drpc_we        => drpc_we_s,
      drpc_do        => drpc_do_s,
      drpc_rdy       => drpc_rdy_s,
      fmeter_clk     => tx_usr_clk_dbg,
      tdc_hit_pmod   => tdc_hit_pmod_i,
      tdc_pps        => pps_s);

  brg_master_out.adr <= wb_adr_s;
  brg_master_out.dat <= wb_dat_m2s_s;
  brg_master_out.sel <= wb_sel_s;
  brg_master_out.cyc <= wb_cyc_s;
  brg_master_out.stb <= wb_stb_s;
  brg_master_out.we  <= wb_we_s;

  wb_dat_s2m_s <= brg_master_in.dat;
  wb_ack_s     <= brg_master_in.ack;
  wb_stall_s   <= brg_master_in.stall;
  wb_err_s     <= brg_master_in.err;
  wb_rty_s     <= brg_master_in.rty;

  p_status_sync : process(pl_clk0)
  begin
    if rising_edge(pl_clk0) then
      locked_meta <= pll_locked_s;
      locked_sync <= locked_meta;
      rstsys_meta <= rst_sys_n;
      rstsys_sync <= rstsys_meta;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Diagnostica WB rotta-A (sticky) — invariata dal v1
  ---------------------------------------------------------------------------
  p_wb_dbg : process(pl_clk0)
    variable push : std_logic;
  begin
    if rising_edge(pl_clk0) then
      if pl_resetn0 = '0' then
        dbg_seen_cyc    <= '0';
        dbg_seen_ack    <= '0';
        dbg_multi_push  <= '0';
        dbg_stall_wedge <= '0';
        dbg_seen_push   <= '0';
        push_cnt        <= (others => '0');
        stall_cnt       <= (others => '0');
      else
        push := wb_cyc_s and wb_stb_s and (not wb_stall_s);
        if wb_cyc_s = '1' then dbg_seen_cyc <= '1'; end if;
        if wb_ack_s = '1' then dbg_seen_ack <= '1'; end if;
        if push = '1'     then dbg_seen_push <= '1'; end if;
        if wb_cyc_s = '0' then
          push_cnt <= (others => '0');
        elsif push = '1' then
          if push_cnt /= "00" then dbg_multi_push <= '1'; end if;
          if push_cnt /= "11" then push_cnt <= push_cnt + 1; end if;
        end if;
        if (wb_cyc_s and wb_stall_s) = '1' then
          if stall_cnt = to_unsigned(1023, stall_cnt'length) then
            dbg_stall_wedge <= '1';
          else
            stall_cnt <= stall_cnt + 1;
          end if;
        else
          stall_cnt <= (others => '0');
        end if;
      end if;
    end if;
  end process;

  -- EMIO IN: 0/1 infra, 2..6 diag WB, 7..22 = sdm_stat(15:0) (gpiochip 85..100)
  emio_gpio_i_s <= (0 => locked_sync,
                    1 => rstsys_sync,
                    2 => dbg_seen_cyc,
                    3 => dbg_seen_ack,
                    4 => dbg_multi_push,
                    5 => dbg_stall_wedge,
                    6 => dbg_seen_push,
                    7  => sdm_stat_s(0),
                    8  => sdm_stat_s(1),
                    9  => sdm_stat_s(2),
                    10 => sdm_stat_s(3),
                    11 => sdm_stat_s(4),
                    12 => sdm_stat_s(5),
                    13 => sdm_stat_s(6),
                    14 => sdm_stat_s(7),
                    15 => sdm_stat_s(8),
                    16 => sdm_stat_s(9),
                    17 => sdm_stat_s(10),
                    18 => sdm_stat_s(11),
                    19 => sdm_stat_s(12),
                    20 => sdm_stat_s(13),
                    21 => sdm_stat_s(14),
                    22 => sdm_stat_s(15),
                    others => '0');

  xc_slave_rst_n <= pl_resetn0 and locked_sync;

  ---------------------------------------------------------------------------
  -- Wishbone clock-domain crossing (invariato dal v1)
  ---------------------------------------------------------------------------
  u_wb_xclk : entity work.xwb_clock_crossing
    generic map (
      g_size => 16)
    port map (
      slave_clk_i    => pl_clk0,
      slave_rst_n_i  => xc_slave_rst_n,
      slave_i        => brg_master_out,
      slave_o        => brg_master_in,
      master_clk_i   => clk_sys_62m5,
      master_rst_n_i => rst_sys_n,
      master_i       => wb_slave_out,
      master_o       => wb_slave_in,
      slave_ready_o  => open,
      slave_stall_i  => '0');

  ---------------------------------------------------------------------------
  -- WR PTP Core board wrapper KR260-SDM
  ---------------------------------------------------------------------------
  u_wr : entity work.xwrc_board_kr260_sdm
    generic map (
      g_simulation   => 0,
      g_dpram_initf  => g_dpram_initf,
      g_fabric_iface => PLAIN)
    port map (
      areset_n_i       => pl_resetn0,
      clk_125m_dmtd_i  => pl_clk0,
      clk_sfp_ref_p_i  => sfp_refclk_p,
      clk_sfp_ref_n_i  => sfp_refclk_n,
      clk_sys_62m5_o   => clk_sys_62m5,
      rst_sys_62m5_n_o => rst_sys_n,
      pll_locked_o     => pll_locked_s,
      sdm_base_i       => emio_gpio_o_s(78 downto 54),
      tx_polarity_i    => emio_gpio_o_s(52),  -- v7: txpol runtime (gpio 464), Caso B
      sdm_stat_o       => sdm_stat_s,
      sdm_dbg_o        => sdm_dbg_s,
      phy_rx_dbg_o     => phy_rx_dbg_s,
      phy_tx_dbg_o     => phy_tx_dbg_s,
      rx_rec_clk_o     => rx_rec_clk_dbg,
      tx_usr_clk_o     => tx_usr_clk_dbg,
      drp_common_clk_i  => pl_clk0,
      drp_common_addr_i => "000000" & drpc_addr_s,
      drp_common_di_i   => drpc_di_s,
      drp_common_en_i   => drpc_en_s,
      drp_common_we_i   => drpc_we_s,
      drp_common_do_o   => drpc_do_s,
      drp_common_rdy_o  => drpc_rdy_s,
      sfp_txp_o        => sfp_tx_p,
      sfp_txn_o        => sfp_tx_n,
      sfp_rxp_i        => sfp_rx_p,
      sfp_rxn_i        => sfp_rx_n,
      sfp_det_i        => '0',    -- assume SFP always present
      sfp_sda_i        => '1',    -- I2C handed off to PS AXI IIC
      sfp_sda_o        => open,
      sfp_scl_i        => '1',
      sfp_scl_o        => open,
      sfp_tx_fault_i   => '0',
      sfp_tx_disable_o => open,
      sfp_los_i        => '0',
      uart_rxd_i       => '1',
      uart_txd_o       => open,
      wb_slave_i       => wb_slave_in,
      wb_slave_o       => wb_slave_out,
      pps_p_o          => pps_s,
      pps_led_o        => pps_led_s,
      led_link_o       => link_up_s,
      led_act_o        => open,
      tm_link_up_o     => open,
      tm_time_valid_o  => tm_time_vld_s,
      tm_tai_o         => open,
      tm_cycles_o      => open);

  ---------------------------------------------------------------------------
  -- PPS fanout + LEDs (invariati dal v1)
  ---------------------------------------------------------------------------
  pps_p_o    <= pps_s;
  pps_pmod_o <= pps_s;
  led_act_o  <= pps_led_s;

  u_heartbeat : led_heartbeat
    generic map (
      g_clk_freq_hz => 62500000,
      g_breath_ms   => 4000)
    port map (
      clk_i   => clk_sys_62m5,
      rst_n_i => rst_sys_n,
      led_o   => hb_led_s);

  led_link_o <= '1' when link_up_s = '1' else hb_led_s;

  ---------------------------------------------------------------------------
  -- SFP-cage LEDs (v15)
  --   LED1 (G8) : WR time valid — solid ON once the servo is locked and the
  --               timescale is valid (the visible sign of a successful sync)
  --   LED2 (F7) : fabric heartbeat — always breathing, so a dark LED2 means
  --               the bitstream is not really running
  ---------------------------------------------------------------------------
  led1_o <= tm_time_vld_s;
  led2_o <= hb_led_s;

  ---------------------------------------------------------------------------
  -- Clock su PMOD1 (toggle FF clk/2, bank 45 HD): pin1=TX/2, pin2=CDR/2
  ---------------------------------------------------------------------------
  p_txclk_tog : process(tx_usr_clk_dbg)
  begin
    if rising_edge(tx_usr_clk_dbg) then
      tx_clk_tog <= not tx_clk_tog;
    end if;
  end process;
  tx_clk_pmod_o <= tx_clk_tog;

  p_rxclk_tog : process(rx_rec_clk_dbg)
  begin
    if rising_edge(rx_rec_clk_dbg) then
      rx_clk_tog <= not rx_clk_tog;
    end if;
  end process;
  rx_clk_pmod_o <= rx_clk_tog;

  ---------------------------------------------------------------------------
  -- ILA su clk_sys (62.5 MHz): steering SDM in tempo reale, letta via XVC
  -- (debug_bridge AXI-to-BSCAN nel BD @0xA0040000 + xvcServer_mmap sulla Kria)
  ---------------------------------------------------------------------------
  u_ila_sdm : ila_sdm
    port map (
      clk    => clk_sys_62m5,
      probe0 => sdm_dbg_s(24 downto 0),            -- sdm_word
      probe1 => sdm_dbg_s(40 downto 25),           -- dac_dpll_data
      probe2(0) => sdm_dbg_s(41),                  -- dac_dpll_load
      probe3 => sdm_stat_s,                        -- catena bring-up + phy_rdy
      probe4 => emio_gpio_o_s(78 downto 54));

  -- v9: ILA sul phy16 — RX nel dominio rx_clk (CDR), TX nel dominio clk_ref
  u_ila_rx16 : ila_rx16
    port map (
      clk    => rx_rec_clk_dbg,
      probe0 => phy_rx_dbg_s(15 downto 0),
      probe1 => phy_rx_dbg_s(17 downto 16),
      probe2(0) => phy_rx_dbg_s(18),
      probe3 => phy_rx_dbg_s(23 downto 19));

  u_ila_tx16 : ila_tx16
    port map (
      clk    => tx_usr_clk_dbg,
      probe0 => phy_tx_dbg_s(15 downto 0),
      probe1 => phy_tx_dbg_s(17 downto 16));

end architecture struct;
