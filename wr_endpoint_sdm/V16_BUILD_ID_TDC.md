# v16/v17 — registri build-id + TDC a catena di carry

Progetto Vivado: `~/kr260_wr_sdm_v16` (copia della v15; runs esclusi) — il nome
della cartella è rimasto "v16" (rinominarla avrebbe rotto i path assoluti nel
progetto Vivado), ma **l'app deployata dal 21/7/2026 è `kr260_wr_sdm_app_v17`**
(registro `FLAGS[31:24]=17`): la catena raddoppiata a 1536 tap + il fix di
polarità hanno reso il firmware abbastanza diverso da meritare il bump di
versione. `kr260_wr_sdm_app_v16` (768 tap, senza fix polarità) resta a bordo
come fallback ma **non va più usata** per il TDC.

Sorgenti di riferimento: `hdl/` di questo repo (`build_id.v`, `tdc_carry.v`,
`tdc_delayline.v`, `ring_osc.v`, `tdc_v16.xdc`, top aggiornato). Integrazione
una tantum: `scripts/integrate_v16.tcl`; build: `scripts/rebuild_v16.tcl`
(nonostante il nome, produce `kr260_wr_sdm_app_v17`).

**Stato: buildato e verificato su hardware il 21/7/2026, calibrazione inclusa**
(vedi "Esito verifica su hardware" in fondo).

## Mappa indirizzi (invariata + 2 nuove periferiche)

| Base | Periferica |
|---|---|
| `0xA0000000` | bridge Wishbone → WRPC (vUART ecc.) |
| `0xA0010000` | I²C SFP |
| `0xA0020000` | DRP GTHE4_COMMON (QPLL0/SDM) |
| `0xA0030000` | freq_counter |
| `0xA0040000` | debug bridge |
| **`0xA0050000`** | **build_id** |
| **`0xA0060000`** | **tdc_carry** |

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
= build fatta saltando l'hook. **Nota implementativa**: i parametri sono
spezzati in mezze parole da 16 bit (`FW_HASH_HI/LO` ecc.) perché il wrapper
VHDL generato dal BD converte i parametri in *integer con segno* a 32 bit: un
hash con MSB=1 (visto con `0xa9f7580f`) sfora il massimo rappresentabile e la
synth fallisce.

## tdc_carry @ 0xA0060000

TDC a linea di ritardo su catena di carry: 96 CARRY8 = **768 tap** (~4–6 ps/tap
su UltraScale+), campionati a **375 MHz** (coarse bin 2.667 ns) da un MMCM
riferito a **TXUSRCLK2**, il 62.5 MHz WR-disciplinato (⚠ `clk_sys_62m5` in
questo design è free-running: NON è quello). Coarse counter a 44 bit
(wrap ~13 h), FIFO 512 stamp.

| Off | Nome | Contenuto |
|---|---|---|
| 0x00 | `CSR`    | `[0]` enable · `[2:1]` input: 0=PMOD 1=PPS 2=cal 3=sw · `[3]` fifo reset (autoclear) · `[4]` sw strobe (toggle) |
| 0x04 | `STATUS` | `[0]` mmcm_locked · `[1]` fifo empty · `[2]` overflow sticky · `[25:16]` fifo count (10 bit) |
| 0x08 | `TS_LO`  | `{coarse[21:0], fine[9:0]}` — la lettura **fa pop** e congela TS_HI |
| 0x0C | `TS_HI`  | `{seq[7:0], 00, coarse[43:22]}` — leggere **dopo** TS_LO |
| 0x10 | `TAPS`   | 768 (costante, per la calibrazione) |
| 0x14 | `CLK_HZ` | 375_000_000 |
| 0x18 | `CNT_HITS` | contatore hit totale (conta anche a FIFO piena) |
| 0x1C | `RING_CNT` | fronti del ring oscillator dall'ultimo reset (due letture a distanza nota → stima Hz) |

**Ingressi** (`input_sel`):
- `0` — **PMOD1 pin fisico 3 = E10** (LVCMOS33, 3.3 V): il segnale esterno da
  timestampare. Fronte di salita; deve tornare basso prima del fronte successivo
  (dead time 2 cicli TDC ≈ 5,3 ns).
- `1` — **PPS del WRPC**: timestampando il PPS si ancora coarse+fine al confine
  di secondo TAI (è il ponte fra la base TDC e il tempo assoluto WR). Richiede
  il WRPC in `TRACK_PHASE` (bring-up da notebook, non parte da solo al load
  della PL).
- `2` — **ring oscillator libero** (nessun PLL, frequenza data dal ritardo di
  LUT/routing, jitter termico reale): per il **code-density test**. Sostituisce
  dal 20/7/2026 il vecchio divisore di `s_axi_aclk` — vedi sotto perché.
- `3` — strobe software (ogni scrittura di CSR con bit4=1 genera un fronte).

**Timestamp**: `t = coarse × 2.667 ns − fine_calibrato`. Il fine è un popcount
bubble-tolerant dei tap: più tap alti = fronte più vecchio dentro il periodo,
quindi il fine si **sottrae** dal tempo del fronte di campionamento.

**Calibrazione (software)**: `input_sel=2`, raccogliere molti stamp, istogramma
dei fine → densità ∝ larghezza reale di ciascun bin (INL/DNL); la somma dei bin
copre un periodo intero. Ripetere quando cambia molto la temperatura.

⚠️ **Perché il ring oscillator e non un divisore di clock**: la prima
implementazione (`input_sel=2` = `s_axi_aclk`/6 ≈ 20,8 MHz) è stata verificata
su hardware il 20/7 e ha dato un istogramma **concentrato** in un quarto della
catena (tap 589–768 su 768) anche con fronti isolati uno alla volta (quindi non
un artefatto di overflow della FIFO). Diagnosi: `s_axi_aclk` (PS) e il clock
del TDC (da TXUSRCLK2) sono asincroni nel senso CDC ma probabilmente non
*incommensurabili* — condividono l'albero di riferimento della scheda, quindi
la fase non gira uniformemente in pochi secondi di test. Un ring oscillator
(nessun riferimento di clock, solo ritardi di gate) non ha questo problema.

**Caveat**:
- a link giù / GT in reset TXUSRCLK2 non è affidabile → controllare
  `STATUS[0]` (mmcm_locked) prima di fidarsi degli stamp;
- cambiare `input_sel` con `enable=0` (il mux è combinatorio: può generare un
  fronte spurio);
- `TS_LO` a FIFO vuota restituisce spazzatura: controllare prima
  `STATUS[1]`/fifo count;
- **overflow sticky (STATUS[2]) NON si azzera in lettura** nonostante il nome
  storico "clear on read" nei commenti di prima stesura: si azzera solo con
  un fifo_reset (CSR bit3). Discrepanza doc/RTL scoperta il 20/7, corretta qui.
- ring oscillator: loop combinatorio intenzionale, richiede
  `ALLOW_COMBINATORIAL_LOOPS` in XDC — non è un errore di sintesi se compare
  in report_drc, è atteso e già gestito in `tdc_v16.xdc`.

## Esito verifica su hardware — stato finale (21/7/2026, immagine v17)

Tutto verificato su `kr260_wr_sdm_app_v17` (`FW_GITHASH=0xc93460eb`,
`FLAGS[31:24]=17`, `TAPS=1536`):

- **build_id**: `FW_GITHASH`/`SW_GITHASH`/`FLAGS` letti esatti.
- **TDC, infrastruttura**: hit contati coerenti con la frequenza della
  sorgente entro <0,001%; clock, coarse counter, FIFO, AXI tutti funzionanti.
- **TDC, PPS**: `input_sel=1`, 5 intervalli consecutivi = 375 000 000
  conteggi coarse esatti (**0 ppm** di errore).
- **TDC, code-density**: range attivo centrato (es. 669-1246 su 1536, varia
  leggermente da build a build per la sensibilità del ring alla P&R), **non
  incollato a nessun estremo** — la firma di una cattura sana.
- **TDC, calibrazione**: tabella `delta_ps[fine]` costruita da 130k+ campioni,
  **autoconsistente** (Σ width_ps = 2666,667 ps = T_periodo esatto),
  **monotona crescente**, correzioni reali fino a ~2600 ps applicate a
  timestamp di prova. Procedura e codice in `wr_node_panel.ipynb` sezione 12.

**Percorso per arrivare qui** (utile se il sintomo si ripresenta): tre ipotesi
smentite in sequenza (sorgente di calibrazione, doppio stadio di
registrazione, polarità di `CARRY8`) prima di trovare la causa vera — la
catena a 768 tap propagava più in fretta del periodo di campionamento
(2,667 ns), quasi ogni campione la trovava già satura. Raddoppiare a 1536 tap
(`N_C8=192`) ha risolto. **Trappola incontrata nel farlo**: cambiare solo il
*default* di un parametro di un module_ref (non l'interfaccia) non basta a
farlo recepire da Vivado — la cache `project_1.gen/.../mref/<nome>/` va
cancellata comunque, altrimenti si builda pulito ma con il vecchio valore
(visto con `TAPS` che leggeva ancora 768 dopo una build "riuscita").

## Se si riparte da qui

1. `kr260_wr_sdm_app_v17` è già a bordo (`/lib/firmware/xilinx/`) e nel
   notebook (`APP = "kr260_wr_sdm_app_v17"` in sezione 2).
2. Bring-up WRPC dal notebook (sezione 5) per riavere `TRACK_PHASE` e poter
   ripetere l'autotest PPS (sezione 11a).
3. Sezioni 10-13 del notebook fanno tutto il resto: build_id, monitor TDC,
   autotest PPS, code-density, calibrazione, **deriva termica** — vedi lì per
   l'uso pratico.
4. Aperto ma non urgente: usare `tdc_calibrated_ps()` su una sorgente esterna
   vera (PMOD, non solo ring/PPS) per una validazione end-to-end completa.

## Deriva termica della calibrazione (sezione 13, 21/7/2026)

La temperatura PS/PL è letta dal **SYSMON interno via IIO**
(`/sys/bus/iio/devices/iio:device0`, canali `ps_temp`/`pl_temp`/`remote_temp`)
— **già esposto da Linux su ogni immagine**, nessuna periferica PL aggiuntiva.
Ogni esecuzione della sezione 12 salva timestamp+temperatura+tabella in
`/home/ubuntu/tdc_calibration_log.json`; la sezione 13 confronta le voci
salvate per stimare la deriva reale in ps/°C. Non abbiamo ancora un dato reale
(serve una seconda calibrazione a temperatura genuinamente diversa) — la
prima voce salvata: PL=25,85 °C. Il ramo di calcolo è comunque verificato
(iniettata e poi rimossa una voce sintetica: matematica confermata esatta).
