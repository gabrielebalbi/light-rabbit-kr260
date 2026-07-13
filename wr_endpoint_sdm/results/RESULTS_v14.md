# v14 — fix larghezza DAC 16→20 bit (chiusura MPL) + bitslide

**Data:** 2026-07-10 (loopback). Test MPL vero contro WR-ZEN: 2026-07-13.

## Problema
Col partner WR-ZEN il link va UP e la **frequenza aggancia** (`MFL1`, `HL1`), ma il
**lock di fase non arriva mai** (`MPL0`); l'uscita DAC del softpll (`MY`/`md`) vagava
di ±5000 LSB attorno a 524288.

## Causa (dai sorgenti + misura loopback)
Mismatch di larghezza del DAC tra HDL e software:
- `xwrc_board_kr260_sdm.vhd` dichiarava `dac_dpll_data`/`_last` a **16 bit** (init `x"8000"`)
  e istanziava il softpll con **`g_dac_bits=>16`**.
- Il `wrc.bram` BabyWR ha **`BOARD_SPLL_DAC_BITS=20`** e pilota valori ~524288=`0x80000`.
- L'HDL prendeva solo i **16 bit bassi**: al bias software `0x80000` i low-16 = `0x0000`
  (non il centro HDL `0x8000`), e ad ogni confine di 65536 codici l'ingresso HDL **wrappava
  a dente di sega** → salto di frequenza → la fase non entrava mai nella finestra ±1.17 ns
  (`spll_main.c:421`, thr=1200 tag) → `MPL0`. Il freq-detector, sticky, restava `MFL1`.
- Packing `sdm = base + (dac_dpll_last−32768)×8`: il ×8 aggiungeva over-gain
  (K_dac ≈ 6.5e-3 ppm/LSB vs SiT5359 ~1.9e-5 → A ≈ 342×).

## Fix (solo HDL, NIENTE rebuild wrc.bram) — `xwrc_board_kr260_sdm.vhd`
7 edit (non 5): oltre al ramo DPLL, `g_dac_bits` dimensiona **entrambe** le porte DAC
(`xwrc_board_common.vhd` righe 103/106), quindi anche l'HPLL è stato allargato preservandolo:
- DPLL: `dac_dpll_data`/`_last` → **20 bit** (init `x"80000"`); `g_dac_bits=>20`;
  packing → `shift_right(resize(signed('0'&dac_dpll_last)-524288,27),5)` (centro 2^19, ÷32
  invece di ×8 → pull ≈ ±13 ppm ≈ SiT ±10 ppm → **A ≈ 1.3**, dentro la taratura BabyWR);
  slice ILA → `dac_dpll_data(19 downto 4)`.
- HPLL: `dac_hpll_data` → **20 bit**, ma passo `dac_hpll_data(15 downto 0)` a `mmcm_psen_dac`
  (fisso 16-bit) → **helper bit-identico** a prima (il reg HW 16-bit troncava già il word
  20-bit sui low-16) → `HL1` preservato.
- Bitslide: `wr_gthe4_phy_family7_xilinx_ip.vhd` = wrapper con sincronizzatore
  `bitslide_ready` su `gtwiz_reset_rx_done_out` (evita il rollover del `bslide` vicino a 16000).
- `.xci` GT wizard lasciato **originale 8B10B/16** (scartata la modifica RAW/20).

## Build
`wrc/rebuild_v14.tcl` (HDL-only, `reset_run synth_1`, no regen IP, no rebuild wrc.bram):
**WNS +2.858 ns**, ~7 min.

## Esito loopback (2026-07-10, SFP non-BiDi TX→RX) — `out_v14.log`
App univoca `kr260_wr_sdm_app_v14` (firmware-name coerente, niente collisione con
`kr260_wr_sdm.bit.bin` esistente). UIO4/5/6 freschi = programmazione reale.

| Metrica | v14 | v13 (prima) |
|---|---|---|
| `lnk` / `lock` | **1 / 1** stabile (5/5) | 1 / 1 |
| `md` (DAC main) | **524288 FISSO** (= 2^19, centro) | vagava ±5000 |
| `bslide` | **11200 stabile** (no rollover) | — |

→ Il dente-di-sega è sparito: il DAC main resta inchiodato al centro. `ptp:listening/LINK_DOWN`
è normale in loopback (nessun partner PTP). **Prova MPL completa = lunedì con lo ZEN.**

## Prossimo passo — `wrc/test_zen_v14.sh` (banner: FIBRA VERSO WR-ZEN, BiDi)
Bring-up verso lo ZEN, autoneg ON, osservazione ~2 min di `pll stat` per cogliere
`MFL1 → MPL1` (`m_phase_lock_ms>0`, `md` fermo, `ptp:slave`/`TRACK_PHASE`).
Fallback runtime pronto (commentato) se MPL non aggancia: `pll gain 0 0 -1800 -25 16`
(abbassa il guadagno del ramo di fase alzando `shift` 12→16/17/18).

## Trappole registrate
- `deploy_v13.sh` non fa `mkdir -p $DST` (la sua dir esisteva già) → primo run v14 fallito
  (`loadapp Error -1`; l'`unloadapp` aveva già tolto v13, fabric residuo raggiungibile via
  /dev/mem). Fix in `deploy_v14.sh`: aggiunto `mkdir -p "$DST"`.
- `stat` bare in questo wrc è un TOGGLE dell'output continuo → usare `wr_stat.sh` per il
  one-shot. `wrc_cmd`/`wr_stat.sh` vogliono `sudo` (mmap /dev/mem). `version` non esiste.
