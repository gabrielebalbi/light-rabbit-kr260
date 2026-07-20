# v16 — registri build-id + TDC a catena di carry

Progetto Vivado: `~/kr260_wr_sdm_v16` (copia della v15; runs esclusi).
Sorgenti di riferimento: `hdl/` di questo repo (`build_id.v`, `tdc_carry.v`,
`tdc_delayline.v`, `tdc_v16.xdc`, top aggiornato). Integrazione una tantum:
`scripts/integrate_v16.tcl`; build: `scripts/rebuild_v16.tcl`.

## Mappa indirizzi (invariata + 2 nuove periferiche)

| Base | Periferica |
|---|---|
| `0xA0000000` | bridge Wishbone → WRPC (vUART ecc.) |
| `0xA0010000` | I²C SFP |
| `0xA0020000` | DRP GTHE4_COMMON (QPLL0/SDM) |
| `0xA0030000` | freq_counter |
| `0xA0040000` | debug bridge |
| **`0xA0050000`** | **build_id (nuovo)** |
| **`0xA0060000`** | **tdc_carry (nuovo)** |

## build_id @ 0xA0050000

| Off | Nome | Contenuto |
|---|---|---|
| 0x00 | `FW_GITHASH` | primi 8 hex dell'HEAD di **questo repo** al momento della synth |
| 0x04 | `SW_GITHASH` | primi 8 hex dell'HEAD di **wrpc-sw** (il wrc.bram embedded) |
| 0x08 | `BUILD_TS`   | unix time della build |
| 0x0C | `FLAGS`      | `[31:24]`=versione (16) · `[1]` sw dirty · `[0]` fw dirty |

Gli hash vengono iniettati da `rebuild_v16.tcl` (proprietà CONFIG del modulo nel
BD) a ogni build: **committare prima di buildare**, altrimenti il dirty bit
avvisa che l'hash non identifica esattamente ciò che gira. Default `0xDEADxxxx`
= build fatta saltando l'hook.

## tdc_carry @ 0xA0060000

TDC a linea di ritardo su catena di carry: 96 CARRY8 = **768 tap** (~4–6 ps/tap
su UltraScale+), campionati a **375 MHz** (coarse bin 2.667 ns) da un MMCM
riferito a **TXUSRCLK2**, il 62.5 MHz WR-disciplinato (⚠ `clk_sys_62m5` in
questo design è free-running: NON è quello). Coarse counter a 44 bit
(wrap ~13 h), FIFO 512 stamp.

| Off | Nome | Contenuto |
|---|---|---|
| 0x00 | `CSR`    | `[0]` enable · `[2:1]` input: 0=PMOD 1=PPS 2=cal 3=sw · `[3]` fifo reset (autoclear) · `[4]` sw strobe (toggle) |
| 0x04 | `STATUS` | `[0]` mmcm_locked · `[1]` fifo empty · `[2]` overflow sticky · `[31:16]` fifo count |
| 0x08 | `TS_LO`  | `{coarse[21:0], fine[9:0]}` — la lettura **fa pop** e congela TS_HI |
| 0x0C | `TS_HI`  | `{seq[7:0], 00, coarse[43:22]}` — leggere **dopo** TS_LO |
| 0x10 | `TAPS`   | 768 (costante, per la calibrazione) |
| 0x14 | `CLK_HZ` | 375_000_000 |
| 0x18 | `CNT_HITS` | contatore hit totale (conta anche a FIFO piena) |

**Ingressi** (`input_sel`):
- `0` — **PMOD1 pin fisico 3 = E10** (LVCMOS33, 3.3 V): il segnale esterno da
  timestampare. Fronte di salita; deve tornare basso prima del fronte successivo
  (dead time 2 cicli TDC ≈ 5,3 ns).
- `1` — **PPS del WRPC**: timestampando il PPS si ancora coarse+fine al confine
  di secondo TAI (è il ponte fra la base TDC e il tempo assoluto WR).
- `2` — oscillatore di calibrazione (pl_clk0/6 ≈ 20,8 MHz, asincrono): per il
  **code-density test**.
- `3` — strobe software (ogni scrittura di CSR con bit4=1 genera un fronte).

**Timestamp**: `t = coarse × 2.667 ns − fine_calibrato`. Il fine è un popcount
bubble-tolerant dei tap: più tap alti = fronte più vecchio dentro il periodo,
quindi il fine si **sottrae** dal tempo del fronte di campionamento.

**Calibrazione (software)**: `input_sel=2`, raccogliere ≥1e5 stamp, istogramma
dei fine → densità ∝ larghezza reale di ciascun bin (INL/DNL); la somma dei bin
copre un periodo intero. Ripetere quando cambia molto la temperatura.

**Caveat**:
- a link giù / GT in reset TXUSRCLK2 non è affidabile → controllare
  `STATUS[0]` (mmcm_locked) prima di fidarsi degli stamp;
- cambiare `input_sel` con `enable=0` (il mux è combinatorio: può generare un
  fronte spurio);
- `TS_LO` a FIFO vuota restituisce spazzatura: controllare prima
  `STATUS[1]`/fifo count.

## Da fare al ritorno della scheda

1. `integrate_v16.tcl` già eseguito e `rebuild_v16.tcl` → `kr260_wr_sdm_app_v16`
   (bit + dtbo in `~/kr260_wr_sdm_v16/app/`), da copiare in
   `/lib/firmware/xilinx/` a bordo come per la v15.
2. Verifica lampo: leggere `0xA0050000` (hash attesi) e `0xA0060004`
   (mmcm_locked a link su).
3. Autotest TDC: `input_sel=1` (PPS), 10 stamp → devono distare 1 s esatto in
   unità coarse (375e6 conteggi ±1); poi code-density con `input_sel=2`.
4. Aggiungere le celle al `wr_node_panel.ipynb` (lettura build_id nel pannello,
   sezione TDC con istogramma di calibrazione).
