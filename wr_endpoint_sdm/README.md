# WR Endpoint KR260 con steering QPLL0+SDM ("Light Rabbit")

Evoluzione dell'esercizio SDM (root del repo) in un **endpoint White Rabbit
completo** su KR260, in cui il softpll del WRPC sterza la frequenza TX agendo
sulla parola frazionaria della QPLL0 via Sigma-Delta Modulator — al posto del
classico oscillatore controllato in tensione (architettura "Light Rabbit":
refclk U90 156.25 MHz **fisso**, tutta l'agilità è nel frac-N del GT).

## 🏆 Risultato (2026-07-13): phase lock raggiunto contro un WR-ZEN

Con il fw **v15**, contro un **Safran WR-ZEN** in master su fibra BiDi:

| | |
|---|---|
| `pll stat` | **`MFL1 MPL1`** — frequenza **e fase** agganciate |
| `wr_stat` | `ptp:slave`, `ss:'TRACK_PHASE'`, `lock:1` — **mai persi in ~8 min** |
| **`cko`** (clock offset) | **entro ±5 ps** → ben **sub-nanosecondo** |
| aggancio di fase | **~4 s** dallo start (`m_phase_lock_ms:3597`) |
| `md` (DAC main) | deriva lenta di warm-up, poi piatta (non il limit-cycle ±5000 di v13) |

**È bastato il fix del DAC (v14):** né i `pll gain` a runtime né il rebuild di `wrc.bram`
sono stati necessari — la gain-schedule BabyWR di serie (`kp:-1800 ki:-25 shift:12`) è
corretta una volta tolto il wrap. Log completo: [`results/out_zen_v15.log`](results/out_zen_v15.log),
write-up in [`results/RESULTS_v15.md`](results/RESULTS_v15.md).

→ **Un endpoint White Rabbit a fase chiusa in cui l'attuatore non è un VCXO ma il
frac-N del transceiver**, sterzato via SDM. `v15` = build di riferimento.

---

## Come ci siamo arrivati (cronologia)

**Stato (2026-07-04): steering dimostrato quantitativamente in loopback ottico**
— vedi [`results/RESULTS.md`](results/RESULTS.md).

**Stato (2026-07-07, fw v12): `lnk:1` in loopback** — endpoint sano end-to-end
(datapath, PCS, softpll, link). Il `lnk:0` era firmware: autoneg + stack.
Analisi completa in [`ANALISI_PERCORSO.md`](ANALISI_PERCORSO.md); fix wrc in
[`wrc/README.md`](wrc/README.md).

**Stato (2026-07-07 sera, fw v12 + partner WR-ZEN): primo link WR col partner** —
`lnk:1`, `ptp:slave`, tempo TAI dal master, AN+TLV WR negoziati; softpll
`mode:slave` con **frequenza agganciata via SDM** (HL1+MFL1). Resta la
**calibrazione di FASE** (MPL0/ptracker): vedi §5 di
[`ANALISI_PERCORSO.md`](ANALISI_PERCORSO.md) e log in `results/out_zen_v12.log`,
`results/out_wr_watch.log`.

**Stato (2026-07-10, fw v14 — causa di MPL0 trovata e corretta in HDL):** il lock
di fase falliva per un **mismatch di larghezza del DAC** HDL↔software. L'HDL
dichiarava il DAC DPLL a **16 bit** (`g_dac_bits=16`), ma il `wrc.bram` BabyWR ha
`BOARD_SPLL_DAC_BITS=20` e pilota valori ~`0x80000`: l'HDL ne prendeva solo i **16
bit bassi** → al bias software `0x80000` i low-16 valgono `0x0000` (non il centro
HDL `0x8000`) e ad ogni confine di 65536 codici l'ingresso **wrappava a dente di
sega** → salto di frequenza → la fase non entrava mai in finestra (`MPL0`), mentre
il freq-detector sticky restava `MFL1`. **Fix v14 (solo HDL, nessun rebuild
`wrc.bram`):** DAC a **20 bit** coerente col sw + packing `÷32` centrato su `2^19`
(era `×8`, over-gain A≈342× → ora A≈1.3). In **loopback** (2026-07-10): `lnk:1
lock:1`, e l'uscita DAC `md` **fissa a 524288** (prima vagava ±5000) → dente-di-sega
risolto. Prova MPL vera col WR-ZEN: **lunedì 2026-07-13** (`wrc/test_zen_v14.sh`).
Dettagli in [`results/RESULTS_v14.md`](results/RESULTS_v14.md).

**Stato (2026-07-11, fw v15 — LED della cage SFP attivi):** logica WR **identica a v14**
(nessun tocco a SDM/DAC/bitslide), ma i due LED accanto alla cage SFP — che nessuna build
aveva mai vincolato — ora sono pilotati: **LED1 = `tm_time_valid`** (fisso = sincronizzazione
WR valida) e **LED2 = heartbeat del fabric** (respira sempre).
Vedi [`results/RESULTS_v15.md`](results/RESULTS_v15.md) e la mappa qui sotto.

**Stato (2026-07-13, fw v15 + WR-ZEN): 🏆 `MPL1` — fase agganciata.** Il fix del DAC era la
cura giusta: `TRACK_PHASE` stabile, `cko` entro ±5 ps. Vedi il riquadro in cima.

## LED della scheda

Verificati sulla scheda l'11/7 (blink test sysfs + prova a fibra staccata).

| LED fisico | Pin / sorgente | Significato |
|---|---|---|
| **UF2** | `led_link_o` = **E8** (PL) | **fisso** = link WR su · **respira** (~4 s) = sta cercando il link |
| **UF1** | `led_act_o` = **F8** (PL) | lampeggia sul **PPS** (1/s). Spento in loopback: senza partner non c'è PPS |
| **LED1** (cage SFP) | **G8** = `som240_1_a12` = HPA13P, bank 66 | *(da v15)* **`tm_time_valid`**: fisso = sincronizzazione WR valida → **è il segno visivo di `MPL1`** |
| **LED2** (cage SFP) | **F7** = `som240_1_a13` = HPA13N, bank 66 | *(da v15)* **heartbeat del fabric**: respira sempre → **spento = il bitstream non sta girando** |
| SOM, LED **centrale** del gruppo di 3 | `heartbeat` (PS, sysfs) | lampeggio del kernel Linux (normale, non c'entra col PL) |
| SOM, LED **vicino alla vite** | `vbus_det` (PS, sysfs) | fisso = VBUS USB presente |
| SOM, 3° LED del gruppo | hardware | power/status, non pilotabile |

Fino a v14 **LED1 e LED2 erano spenti**: non un guasto, semplicemente `G8`/`F7` non erano
vincolati in nessun XDC → pin flottanti. LED2 è ora la verifica **più diretta** che il PL sia
stato programmato davvero (prima l'unico indizio era il timestamp di `/dev/uio*`).

> ⚠️ **Trappola build:** il progetto Vivado contiene **due** top con struttura LED identica.
> `hdl/top/kr260_wr/kr260_wr.vhd` è `AutoDisabled` (**file morto**); quello sintetizzato è
> **`kr260_wr_sdm.vhd`** (`TopModule = kr260_wr_sdm` nel `.xpr`). Editare l'altro non produce
> nessun errore finché l'XDC non cerca una porta inesistente.

## Architettura

```
WRPC (LM32 + softpll)                        GTHE4 (X0Y6) — linea 1.25 Gbps 8b10b HW
 └─ DAC DPLL 20 bit ──┐   (v14; era 16 bit → bug MPL, vedi RESULTS_v14.md)
                      ▼
        packing centrato+clampato:            QPLL0 frac-N (VCO 10 GHz)
        sdm_word = clamp(base + (dac−2^19)/32) ─► SDM0DATA[24:0]
        base runtime 25 bit via EMIO (gpio 466..490)  + handshake SDM0TOGGLE
                      │                               (sequenza 0→1→0, 64 cicli)
                      └─ mirror su EMIO in + ILA (XVC)

PS AXI: 0xA0020000 bridge DRP GTHE4_COMMON (QPLL0)   0xA0030000 freq_counter (TXUSRCLK2)
        0xA0040000 debug_bridge AXI→BSCAN (XVC, ILA senza cavo JTAG)
```

- TX su QPLL0 frac-N; RX su QPLL1 (156.25 intera): lo steering agisce solo sul TX
- Escursione DAC softpll: **±244 ppm** attorno a `base/2^24`; passo ≈ 7.5·10⁻³ ppm/LSB
- DMTD da MMCM (shim v1); wrc.bram embedded nel bitstream

## Contenuto

| Dir | Contenuto |
|---|---|
| `hdl/` | i 3 sorgenti scritti/modificati: wrapper board (packing+handshake), top (ILA/XVC), PHY con porte SDM |
| `scripts/` | `build_sdm.tcl` — build batch completa (sorgenti→IP GT fracN→BD→bit+app Kria) |
| `test/` | script di test lato scheda (richiedono `busybox devmem`, **non** devmem2 — vedi sotto) |
| `results/` | log grezzi `out_sdm*.log`, catture ILA + write-up `RESULTS.md` |
| `notebooks/` | `wr_node_panel.ipynb` — **pannello del nodo**: carica il fw, bring-up, vUART, frequenzimetro, monitor del lock (vedi sotto) · `sdm_steering.ipynb` — sweep steering + monitor lock |
| `xvc/` | server XVC (ILA senza cavo JTAG) + procedura |

I sorgenti in `hdl/` si innestano su un tree wr-cores con la piattaforma
UltraScale+ `xilinx_ip` (8b10b hardware del GT, come le board ZCU102/106 del
repo ufficiale); il tree completo non è incluso (troppo grande): `build_sdm.tcl`
documenta i path attesi.

## Il pannello grafico del nodo — `notebooks/wr_node_panel.ipynb`

Fa **tutto il bring-up da scheda appena riavviata** e mostra lo stato del nodo:
carica il firmware v15 sulla PL (con verifica dei timestamp `/dev/uio*` = programmazione
reale), riaccende il laser, esegue MAC/autoneg/`mode slave`/`ptp start`, apre la **vUART**
del softcore, legge il **frequenzimetro** (TXUSRCLK2, atteso ≈62.5 MHz) e infine grafica in
loop **`cko`** (offset di fase dal master) e **`md`** (uscita del DAC che sterza l'SDM)
finché non scatta il **phase lock**.

Si usa via JupyterLab sulla Kria, tipicamente esposto in SSH tunnel:

```
# sulla scheda — DEVE girare come root: servono /dev/mem e xmutil
sudo jupyter lab --allow-root --no-browser --ip=127.0.0.1 --port=8888
# dalla workstation
ssh -N -L 8888:localhost:8888 <user>@<kr260-host>
# poi http://localhost:8888/lab/tree/wr_node_panel.ipynb
```

**Due trappole incontrate davvero, già gestite nel notebook:**

1. **Jupyter come utente non funziona:** senza root il kernel non apre `/dev/mem` (la cella 1
   se ne accorge e si ferma con un messaggio esplicito, invece di dare errori incomprensibili).
2. **Backend `inline` di matplotlib rotto sull'immagine Kria:** matplotlib **3.5.1** di sistema
   contro `matplotlib_inline` **0.2.2** in `~/.local` → `AttributeError: 'RcParams' object has
   no attribute '_get'` al primo `import matplotlib.pyplot`. La cella dei grafici forza il
   backend **Agg** e mostra le figure come PNG: nessun aggiornamento di pacchetti richiesto.

⚠️ La vUART regge **un solo consumatore per volta**: mentre il notebook è vivo non lanciare
`wrc_cmd.py`/`wr_stat.sh` da shell, o si rubano i byte a vicenda.

## Trappola nota: devmem2 su aarch64

`devmem2` fa accessi a 64 bit (`unsigned long`): su memoria Device ogni offset
`addr % 8 == 4` genera SIGBUS ("Bus error"). Sono stati persi due giorni dietro
un finto guasto AXI. Per i registri PL usare **sempre** `busybox devmem ADDR 32
[VAL]` (gli script in `test/` lo fanno).

## I tre bug trovati (in ordine di scoperta)

1. **devmem2 64-bit** (out_sdm7): il "Bus error sul DRP" e il "baco fmeter"
   erano artefatti del tool. DRP e frequenzimetro erano sani.
2. **Packing gated** (out_sdm8, fix v5c): `sdm_word` veniva ricalcolata solo su
   `dac_dpll_load`; a softpll muto (loopback) la base EMIO non fluiva mai.
   Fix: calcolo continuo con `dac_dpll_last` (init centro scala).
3. **Toggle gated** (out_sdm10, fix v6): il GTHE4 campiona `SDM0DATA` **solo su
   una transizione di `SDM0TOGGLE`** (UG576); anche il toggle derivava da
   `dac_dpll_load` → la parola nuova non entrava mai nel modulatore.
   Fix: change-detect su `sdm_word` → dato congelato in `sdm_word_sent` +
   sequenza toggle di 64 cicli (pattern del riferimento `gthe4_sdm.vhd`).

## Clock SDM sull'oscilloscopio (PMOD1)

La frequenza generata dalla QPLL0+SDM è esportata su PMOD1 (già nel fw v6,
ereditata da bbfix7 — nessuna rebuild necessaria):

| PMOD1 pin fisico | Pin FPGA | Segnale | Nominale |
|---|---|---|---|
| 1 (HDA11) | H12 | **TXUSRCLK2/2 ← QPLL0 ← SDM** | 31,250000 MHz |
| 2 (HDA15) | B10 | CDR/2 (clock recuperato RX) | 31,25 MHz |
| 5, 11 | — | GND per la sonda | — |

LVCMOS33; toggle-FF /2 in fabric (bank 45 HD = solo SDR → il /2 dà 50% di
duty). Perturbazione trascurabile: TXUSRCLK2 è già in fabric via BUFG_GT,
si aggiunge solo un FF e un pin HD — zero carico sul GT. Massa corta sulla
sonda (31 MHz a 3,3 V).

Cosa si vede:
- **steering manuale**: base=2²² → il counter dello scope passa da 31,250 a
  31,372 MHz (+122 kHz = +0,39%), ben visibile;
- **lock softpll** (±244 ppm → ±7,6 kHz max): CH1=H12 come trigger, CH2=B10 —
  al lock le due tracce smettono di scorrere l'una rispetto all'altra; per i
  ppm fini usare il frequenzimetro interno (risoluzione ~0,025 ppm a gate 0,8 s,
  cella 3 del notebook).
