# SFP+ DRP SDM — KR260 QPLL0 Sigma-Delta Modulator Exercise

> 🏆 **Questo esercizio è diventato un endpoint White Rabbit funzionante.**
> Il 2026-07-13 la KR260 ha agganciato **frequenza e fase** contro un WR-ZEN commerciale
> (`MFL1 MPL1`, `TRACK_PHASE`, **clock offset entro ±5 ps**) usando come attuatore **non un
> VCXO, ma il frac-N della QPLL0 sterzato via SDM**. → [`wr_endpoint_sdm/`](wr_endpoint_sdm/)

Progetto Vivado 2025.2 per **AMD KR260** (xck26-sfvc784-2LV-c) che permette di
esercitare a runtime la catena **SDM (Sigma-Delta Modulator)** della QPLL0 del
transceiver GTH (GTHE4_COMMON_X0Y1).

Partendo da un design SFP+ base a 10.3125 Gbps, il progetto aggiunge:
- accesso DRP al GTHE4_COMMON per scrivere i registri SDM della QPLL0;
- un **frequenzimetro hardware** (TXPRGDIVCLK misurata su finestra configurabile);
- un **Jupyter notebook** per controllare tutto da PS via `/dev/mem`.

---

## Architettura

```
PS (Zynq UltraScale+ ZU5EV)
 └─ M_AXI_HPM0_FPD → SmartConnect
      ├─ 0xA0000000  axi_drp_bridge_0      → DRP GTHE4_CHANNEL_X0Y6
      ├─ 0xA0010000  axi_iic_sfp           → I2C SFP+ (SCL AB11, SDA AC11)
      ├─ 0xA0020000  axi_drp_bridge_common → DRP GTHE4_COMMON_X0Y1 (registri SDM)
      └─ 0xA0030000  freq_counter_0        → Frequenzimetro TXPRGDIVCLK

GTH: QPLL0, FBDIV=66, refclk=156.25 MHz → 10.3125 Gbps
     SDM abilitato, parola frazionaria iniziale = 0
     TXPRGDIVCLK ≈ 161 MHz (TXOUTCLK via BUFG_GT, PROGDIV=64)
```

---

## Registri DRP GTHE4_COMMON per SDM (UG576 v1.7.1, Table C-1)

| Registro DRP | Indirizzo | Bit | Descrizione |
|---|---|---|---|
| `QPLL0_SDM_CFG0` | `0x0020` | `[12:0]` | SDM_DATA\[12:0\] (13 bit bassi) |
| `QPLL0_SDM_CFG0` | `0x0020` | `[14]` | 0 = SDM abilitato |
| `QPLL0_SDM_CFG1` | `0x0021` | `[8:0]` | SDM_DATA\[21:13\] (9 bit alti) |
| `QPLL0_SDM_CFG2` | `0x0024` | — | Configurazione SDM avanzata |

Step minimo di frequenza VCO: `Fref / 2^22 = 156.25 MHz / 4194304 ≈ 37.3 Hz`

---

## Struttura del repo

```
rtl/
  axi_drp_bridge.v      AXI4-Lite → DRP master (usato per CHANNEL e COMMON)
  freq_counter.v         Frequenzimetro AXI4-Lite, meas_clk = TXPRGDIVCLK
  gth_sfp_wrapper.v      Wrapper GTHE4_CHANNEL + GTHE4_COMMON, SDM abilitato
  top_sfp_drp.v          Top-level: BD wrapper + GTH wrapper

constraints/
  kr260_sfp.xdc          LOC GTH, clock constraints, CDC false_path

scripts/
  build_all.tcl          Crea progetto Vivado completo e genera bitstream (un unico run)
  run_impl.tcl           Re-run sintesi + impl su progetto esistente
  add_axi_iic.tcl        Aggiunge AXI IIC al BD (alternativa a build_all.tcl)
  add_tx_disable.tcl     Aggiunge GPO laser enable al BD

notebooks/
  freq_meter.ipynb       Notebook Jupyter: misura frequenza + sweep SDM via /dev/mem

ip/
  axi_drp_bridge/        IP packaged dell'AXI DRP bridge
```

## Licenza

Tutto il repo è rilasciato sotto **CERN Open Hardware Licence Version 2 — Weakly
Reciprocal** (`CERN-OHL-W-2.0`), testo integrale in [`LICENSE`](LICENSE).

È la licenza dell'ecosistema White Rabbit / Open Hardware, ed è quella coerente col
fatto che i sorgenti in `wr_endpoint_sdm/hdl/` sono **opera derivata da
[wr-cores](https://ohwr.org/project/wr-cores)** (CERN-OHL-W-2.0+, header SPDX nei file).
Il resto — bridge AXI→DRP, frequenzimetro, script di build, notebook — è codice
originale di questo progetto, rilasciato sotto la stessa licenza.

### Documentazione di riferimento (non redistribuita)

I documenti AMD/Xilinx usati durante il lavoro **non sono inclusi nel repo**: sono
materiale proprietario, si scaricano gratuitamente dal sito AMD.

| Documento | Dove serve | Dove prenderlo |
|---|---|---|
| **UG576** — *UltraScale Architecture GTH Transceivers* (Appendix C: mappa DRP `GTHE4_COMMON`, registri SDM) | registri `QPLL0_SDM_CFG*`, handshake `SDM0TOGGLE` | [docs.amd.com](https://docs.amd.com/) → UG576 |
| **XTP743 / XTP750** — schematici della carrier card KR260 (e sorgente OrCAD) | pinout SFP+ cage, LED, PMOD | [amd.com — Kria KR260 downloads](https://www.amd.com/en/products/system-on-modules/kria/k26/kr260-robotics-starter-kit.html#documentation) |

---

## Come costruire il bitstream

```bash
git clone https://github.com/gabrielebalbi/sfp_drp_kr260_sdm
cd sfp_drp_kr260_sdm
vivado -mode batch -source scripts/build_all.tcl
```

Il bitstream viene scritto in:
`vivado/sfp_drp_kr260_sdm/sfp_drp_kr260_sdm.runs/impl_1/top_sfp_drp.bit`

> **Requisiti:** Vivado 2025.2, licenza per GTHE4 (inclusa nella licenza Kria/KR260 device-locked).

---

## Come caricare il bitstream sul KR260

```bash
# Da host:
scp vivado/sfp_drp_kr260_sdm/sfp_drp_kr260_sdm.runs/impl_1/top_sfp_drp.bit \
    ubuntu@<KR260_IP>:~/sfp_drp_sdm.bit

# Sul KR260:
sudo xmutil unloadapp
sudo fpgautil -b ~/sfp_drp_sdm.bit
```

---

## Registri frequenzimetro (base 0xA0030000)

| Offset | Nome | R/W | Descrizione |
|--------|------|-----|-------------|
| `0x00` | `GATE_CYCLES` | r/w | Finestra di misura in cicli pl_clk0 (default 100 000 000 = 1 s @100 MHz) |
| `0x04` | `FREQ_CNT` | r/o | Spigoli TXPRGDIVCLK nell'ultima finestra |
| `0x08` | `STATUS` | r/o | bit\[0\]=1: nuovo risultato disponibile (si azzera leggendo STATUS) |

Stima VCO da TXPRGDIVCLK (PROGDIV=64):
```
QPLL0_VCO_GHz ≈ FREQ_CNT × 64 / gate_seconds / 1e9
```

---

## Notebook Jupyter

`notebooks/freq_meter.ipynb` si esegue sul KR260 (JupyterLab già presente nell'immagine Ubuntu Kria):

| Cella | Funzione |
|-------|----------|
| 1 | Helper: `open_axi()`, `rd32()`, `wr32()`, `drp_read()`, `drp_write()` |
| 2 | Configura finestra di misura (default 2 s) |
| 3 | Singola lettura frequenza |
| 4 | Legge/scrive SDM_DATA via DRP COMMON |
| 5 | Sweep SDM + grafico matplotlib |
| 6 | Monitor live con bottone Stop |
| 7 | Cleanup mmap |

---

## Progetto base

Questo progetto è una variante del progetto base `sfp_drp_kr260` (10.3125 Gbps,
DRP solo sul CHANNEL, TX/RX in reset permanente). Le modifiche principali:
- DRP GTHE4_COMMON esportato e collegato a un secondo `axi_drp_bridge`
- TX reset = 0 per rendere valido TXPRGDIVCLK
- TXOUTCLK portato in fabric via BUFG_GT
- `freq_counter` aggiunto come slave AXI4-Lite
- Parametri SDM QPLL0 inizializzati a 0 (SDM abilitato, dato frazionario = 0)

---

## Dall'esercizio all'endpoint White Rabbit → `wr_endpoint_sdm/`

L'esercizio di questo repo è servito da groundwork per l'obiettivo vero:
un **endpoint White Rabbit su KR260 in cui il softpll sterza la QPLL0 via SDM**
("Light Rabbit": refclk fisso, agilità nel frac-N). Il progetto completo —
sorgenti HDL, build script, test lato scheda e risultati — è in
[`wr_endpoint_sdm/`](wr_endpoint_sdm/).

**Esito (2026-07-13): obiettivo raggiunto — phase lock contro un WR-ZEN commerciale.**
Il softpll del WRPC chiude l'anello **di fase** sterzando la QPLL0 via SDM:
`MFL1 MPL1`, `ptp:slave` in `TRACK_PHASE`, **clock offset entro ±5 ps**, lock in ~4 s
e stabile. Nessun VCXO nel percorso di attuazione.

Tappe: steering dimostrato quantitativamente in loopback (2026-07-04, accordo
teoria/misura ~10⁻⁵, reversibile bit-esatto, tuning range ≈+6 000 ppm = 15× lo span
±244 ppm del softpll) → primo link col partner e frequenza agganciata (2026-07-07) →
**fase agganciata** (2026-07-13), dopo aver trovato un mismatch di larghezza del DAC
(16 bit HDL vs 20 bit software) che faceva wrappare l'attuatore a dente di sega.

Dettagli: [`wr_endpoint_sdm/README.md`](wr_endpoint_sdm/README.md) ·
[`RESULTS.md`](wr_endpoint_sdm/results/RESULTS.md) (steering) ·
[`RESULTS_v14.md`](wr_endpoint_sdm/results/RESULTS_v14.md) (il bug del DAC) ·
[`RESULTS_v15.md`](wr_endpoint_sdm/results/RESULTS_v15.md) (phase lock).

⚠️ Trappola emersa durante i test, valida anche per il notebook di questo repo:
`devmem2` su aarch64 fa accessi a 64 bit → SIGBUS sugli offset `addr % 8 == 4`
di memoria Device. Usare `busybox devmem ADDR 32 [VAL]` o accessi mmap a 32 bit.
