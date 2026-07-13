# Risultati — campagna steering SDM (2026-07-04, loopback ottico)

Setup: KR260 con fw `kr260_wr_sdm v6`, SFP non-BiDi con fibra in loopback su
se stessa, `phy_rdy=1` (l'RX decodifica il proprio TX). Frequenzimetro HW su
TXUSRCLK2 (62.5 MHz nominali), gate = 100·10⁶ cicli di pl_clk0 (124.99875 MHz)
= finestra 0.800 s. Base SDM impostata a runtime via EMIO (gpio 466..490).

## out_sdm11 — steering dimostrato (fw v6)

| Caso | base | FREQ_CNT | Δ vs baseline |
|---|---|---|---|
| A) baseline | 0 | 50 000 853 | — |
| C) 2²² | 4 194 304 | 50 183 961 | **+183 108** |
| D) 2²⁴−1 | 16 777 215 | 50 299 949 | +299 096 (saturato, v. sotto) |
| E) ritorno | 0 | 50 000 853 | **0 — bit-identico** |

**Verifica quantitativa (caso C):** il softpll scrive DAC=0 all'init → parola
effettiva = 2²² − 2¹⁸ = 3 932 160 → frazione 15/64 → Δ atteso =
50 000 853 × (15/64)/64 = **+183 110**. Misurato **+183 108**: accordo a
2 conteggi (~10⁻⁵ relativo). La QPLL0 esegue il frac-N esattamente da modello.

`phy_rdy=1` in tutti i casi: in loopback l'RX riceve il proprio TX spostato e
il CDR segue. Reversibilità bit-esatta al ritorno a base=0.

## out_sdm12 — caratterizzazione del limite: saturazione VCO

| Punto | frac richiesta | Δ misurato | frac effettiva |
|---|---|---|---|
| 2²⁴−1 (×3 misure) | 0.984 | +299 362 ±23 | 0.383 |
| 2²³ (×2 misure) | 0.484 | +299 275 ±16 | 0.383 |

Metà scala e fondo scala danno lo **stesso tetto**, stabile su misure ripetute
→ non è un transitorio né un limite del Σ-Δ: è la **saturazione del range di
tuning del VCO LC** attorno al punto di band-calibration (10.000 GHz all'avvio),
a ≈ **+6 000 ppm**. Indizio a supporto: al tetto le misure hanno jitter ±20-30
conteggi (controllo al rail), a frac=0 sono congelate al bit. Oltre il tetto
servirebbe una ricalibrazione (reset QPLL).

## Conclusioni

- **Zona lineare verificata** almeno fino a frac 0.234 (+3 660 ppm), esatta a 10⁻⁵.
- Lo span richiesto dal softpll WR è **±244 ppm** → margine **15×** dentro la
  zona lineare. Risoluzione ≈ 7.5·10⁻³ ppm per LSB del DAC.
- **La QPLL0+SDM è validata come attuatore di frequenza per il softpll WR.**
  Prossimo passo: aggancio WR contro un partner reale (softpll che sterza).

## Log inclusi

| File | Firmware | Esito |
|---|---|---|
| `out_sdm7.log` | v4 | scoperta artefatto devmem2 (SIGBUS su addr%8==4) |
| `out_sdm8.log` | v4 | DRP e fmeter sani; steering KO → bug packing |
| `out_sdm10.log` | v5c | packing ok (sdm_word segue la base) ma freq ferma → bug toggle |
| `out_sdm11.log` | v6 | **steering dimostrato** (tabella sopra) |
| `out_sdm12.log` | v6 | saturazione VCO caratterizzata |

(out_sdm9 non esiste come test: il nome è stato usato per una diagnostica del
tunnel di collegamento alla scheda.)

## Conferma visiva via XVC (ILA senza cavo JTAG)

Cattura `ila_sdm_steer.csv` (trigger su base≠0, gpio488 da console, ILA letta
via debug_bridge → UIO → xvcServer → tunnel SSH → Vivado su PC remoto):

| Campione | Evento |
|---|---|
| 512 (trigger) | `sdm_base` 0 → 0x0400000 (2²²) |
| 513 | `sdm_word` 0 → **0x03C0000** = 2²²−2¹⁸ (1 ciclo dopo; DAC=0 confermato in HW) |
| 531 | `SDM0TOGGLE` ↑ |
| 563 | `SDM0TOGGLE` ↓ (32 cicli alti, dato congelato) |

Il valore 0x3C0000 = 3 932 160 è lo **stesso** dedotto indipendentemente dal
frequenzimetro in out_sdm11: verifica incrociata fmeter ↔ ILA chiusa.
Procedura e note XVC in [`../xvc/README.md`](../xvc/README.md).

---

## 2026-07-07 — fw v12: `lnk:1` in loopback

Chiuso il mistero `lnk:0` (durato tutta la campagna): era **firmware**, non
hardware. Doppia causa — (a) autoneg `an=1` che pretende `ANEGCOMPLETE` (assente
in loopback), (b) il wrc ricompilato non bootava per **stack 2048** (overflow).

Fix v12 (`ed1a9228`, WNS +3.138): `ep_enable(an=0)` + `STACKSIZE=4096` + comando
shell `mdio`. Risultato (`out_v12.log`):

```
stat: lnk:1 rx:29 tx:35 lock:1 ptp:listening ...
mdio dump: MCR=0x0140 (an off)  MSR=0x018c (LSTATUS=1, ANEGCOMPLETE=0)
```

Cioè link su per il solo `LSTATUS`, senza `ANEGCOMPLETE` — verifica bit-esatta
della diagnosi. Dettagli in [`../ANALISI_PERCORSO.md`](../ANALISI_PERCORSO.md) §3.
Prossimo: partner WR-ZEN con `mdio an 1`.

---

## 2026-07-07 (sera) — primo link WR col partner WR-ZEN

Dopo il loopback, fibra BiDi verso il WR-ZEN. Sistemato un SFP caduto/rotto
(RX era in LOS −40 dBm → sostituito → −6.6 dBm). Con `mdio an 1`:

- `stat`: **lnk:1**, rx cresce, **ptp:slave**, TAI dal master; AN completa
  (MSR ANEGCOMPLETE=1, ANLPAR=0x41a0, WRSPEC=0x0020).
- `pll stat`: **mode:slave, HL1, MFL1** → freq agganciata via SDM sotto WR reale.
- Aperto: **MPL0 / ptrack ready:0 / mu·crtt garbage** → calibrazione di fase WR
  da fare. Log completi: [`out_zen_v12.log`](out_zen_v12.log),
  [`out_wr_watch.log`](out_wr_watch.log). Dettaglio in
  [`../ANALISI_PERCORSO.md`](../ANALISI_PERCORSO.md) §5.
