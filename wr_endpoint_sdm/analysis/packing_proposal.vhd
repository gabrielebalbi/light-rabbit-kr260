-- ============================================================================
-- PROPOSTA (NON ancora buildata/validata) — packing DAC->sdm_word a 20 bit + M
-- Obiettivo: alzare il guadagno dell'attuatore SDM (Kdac) per dare banda al ramo
-- di fase del softpll (vedi analysis/README.md, modello closed-loop + fig_H).
--
-- OGGI (xwrc_board_kr260_sdm.vhd, p_dac_to_sdm):
--   signal dac_dpll_data : std_logic_vector(15 downto 0);           -- 16 bit
--   v_sum := signed(resize(unsigned(sdm_base_i), 27)) +
--            shift_left(resize(signed('0' & dac_dpll_last) - 32768, 27), 3); -- x8
--   => DAC softpll (20 bit) TRONCATO a 16 + moltiplicatore 8
--      -> solo ~0.5 LSB di sdm_word per LSB del softpll  (Kdac troppo basso)
--
-- PROPOSTA: usare il DAC a 20 bit PIENO (niente troncamento) e un moltiplicatore
-- M parametrico. Candidato dal modello (con Kf del v6): M = 16..32 coi gain PI
-- nominali. M<=32 per non sforare i 25 bit di sdm_word (dac20 oscilla +-2^19).
-- ============================================================================

-- 1) ampliare il segnale e collegarlo al DAC softpll SENZA troncare 20->16:
--    signal dac_dpll_data : std_logic_vector(19 downto 0);   -- era 15 downto 0
--    (e nel port map del core: dac_dpll_o(19 downto 0) => dac_dpll_data)
--    signal dac_dpll_last : std_logic_vector(19 downto 0) := std_logic_vector(to_unsigned(2**19,20));

  constant c_M : integer := 16;   -- moltiplicatore packing (misurare Kf -> 16..32)

  -- dentro p_dac_to_sdm, al posto dello shift_left x8:
  --   centro a 2^19 (bias del DAC a 20 bit), moltiplica per M, somma alla base
  v_sum := resize(signed('0' & sdm_base_i), 28)
         + resize( (signed('0' & dac_dpll_last) - 2**19) * to_signed(c_M, 8), 28 );

  -- clamp invariato a [0, 2^25-1]:
  --   if v_sum < 0 then sdm_word <= (others=>'0');
  --   elsif v_sum > 33554431 then sdm_word <= (others=>'1');
  --   else sdm_word <= std_logic_vector(resize(unsigned(v_sum), 25));

-- ============================================================================
-- NOTE
--  * handshake SDM0TOGGLE (64 cicli) INVARIATO: non e' il collo di bottiglia.
--  * Il DRP NON e' coinvolto (dato via pin SDM0DATA); nessuna modifica firmware.
--  * Trade-off: M grande = passo di frequenza per LSB piu' grosso (risoluzione
--    piu' grezza) + piu' autorita'. L'M ottimo si fissa dopo la MISURA di Kf a
--    banco (step del DAC main via softpll, Df col frequenzimetro) rimesso nel
--    modello (closed_loop_model.py / packing_sweep.py).
-- ============================================================================
