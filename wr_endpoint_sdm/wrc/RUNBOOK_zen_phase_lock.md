# RUNBOOK — Lunedì 2026-07-13: test MPL contro il WR-ZEN (fw **v15**)

**Obiettivo:** dimostrare il **lock di FASE** WR (`MPL1`) col fix DAC 16→20 bit.
In v12/v13 la frequenza agganciava (`MFL1`) ma la fase no (`MPL0`). Il fix elimina il
wrap a dente di sega del DAC e riporta il guadagno d'anello ad A≈1,3 (dentro la taratura
BabyWR) → la fase dovrebbe entrare in finestra e scattare `MPL1`.

> Stato a fine 10/7: **v14** buildato (WNS +2.858), **loopback OK** (`lnk:1 lock:1`,
> `md:524288` fisso). App `kr260_wr_sdm_app_v14` e script già a bordo.
>
> Stato 11/7: **v15 = v14 + LED1/LED2 della cage SFP** (logica WR **identica**, vedi la mappa
> LED in fondo). **Lunedì si usa v15**; **v14 resta il fallback** già installato sulla scheda.

## ⚡ PASSO 0 — copiare l'app v15 sulla scheda

Dalla workstation di build, con la KR260 accesa e raggiungibile via SSH:

```
ssh <user>@<kr260-host> 'echo scheda viva'
scp -r $HOME/kr260_wr_sdm_v15/app/kr260_wr_sdm_app_v15 <user>@<kr260-host>:~/
scp $HOME/kr260_wr_sdm_v15/{deploy_v15.sh,test_zen_v15.sh} <user>@<kr260-host>:~/
```

> ⚠️ **Il solo `scp` nella home NON basta:** `xmutil` cerca le app in
> `/lib/firmware/xilinx/<app>/`. Se salti l'installazione lì, `loadapp` fallisce.
> Ci pensa `deploy_v15.sh` (che fa anche il `mkdir -p` della destinazione).

---

## 📡 BANNER FIBRA: **VERSO IL PARTNER WR (SFP BiDi)** — non loopback

**SETUP HARDWARE prima di tutto:**
1. Montare l'**SFP BiDi** (BlueOptics BO15C4931629D-WR: TX1490/RX1310) al posto del non-BiDi.
2. Fibra dalla KR260 verso il **partner WR-ZEN** (Safran WR-ZEN, sua porta `wr0` in master).
3. **Caricare la scheda PRIMA di collegare il cavo USB-UART** (il cavo può piantare Ubuntu).
4. Verificare RX ottico: `sudo python3 ~/read_sfp_ddm.py` → RX ~**-6 dBm**
   (se RX = LOS/garbage: SFP rotto o fibra staccata — non proseguire).

---

## PASSO 1 — Test automatico verso lo ZEN (fa quasi tutto)
```
sudo bash ~/test_zen_v15.sh
```
Lo script: ricarica l'app v15 (unload→load), **verifica timestamp /dev/uio** (uio4/5/6
freschi = programmazione reale), riaccende il laser (`tx_enable on`), MAC fisso
`00:11:22:33:44:55`, **autoneg ON** (`mdio an 1`), `mode slave` + `ptp start`, poi osserva
`wr_stat.sh` + `pll stat` per ~2 min. Log salvato in `~/out_zen_v15.log`.

**COSA GUARDARE (in ordine):**
- **LED2** (cage SFP) respira subito dopo il load → il bitstream v15 gira davvero
- `lnk:1` → link su (PCS + bitslide ok) — sulla scheda: **UF2 fisso**
- `pll stat` → `MFL1` (freq agganciata, come già in v12/v13)
- **`MPL1`** e `m_phase_lock_ms > 0` → **OBIETTIVO RAGGIUNTO** (lock di fase);
  sulla scheda **LED1 (cage) si accende FISSO** e **UF1 lampeggia 1/s** (PPS)
- `md` (uscita DAC) fermo entro poche unità (non deve vagare ±5000 come in v13)
- stato PTP che sale a `ptp:slave` → `TRACK_PHASE`, `lock:1`

> Fallback: se v15 desse problemi, `sudo bash ~/test_zen_v14.sh` (app v14 già a
> bordo, stessa logica WR ma senza LED). Un esito **diverso** tra v14 e v15 sarebbe di per sé
> sospetto: le due build differiscono solo per due porte di uscita.

## PASSO 2 — Monitor esteso (se serve confermare la tenuta)
```
sudo bash ~/wr_stat.sh        # lettura one-shot (NB: 'stat' bare è un TOGGLE!)
# ripetere a mano, o:
for i in $(seq 1 20); do sudo bash ~/wr_stat.sh | grep -E 'lnk:|ptp:'; sleep 5; done
sudo python3 ~/wrc_cmd.py "pll stat"     # MFL/MPL/m_phase_lock_ms
sudo python3 ~/wrc_cmd.py "mdio dump"    # ANLPAR = cosa dichiara lo ZEN
```

---

## PASSO 3 — FALLBACK se resta `MPL0` (fase non aggancia / `md` che sbatte)

### 3a. Abbassare il guadagno del ramo di fase a runtime (effetto immediato)
`SPLL_LOOP_MAIN=0`, stage 0, si alza `shift` (÷2 per unità). Provare in sequenza:
```
sudo python3 ~/wrc_cmd.py "pll gain 0 0 -1800 -25 16"   # ÷16 vs shift 12
# se non basta:
sudo python3 ~/wrc_cmd.py "pll gain 0 0 -1800 -25 17"   # ÷32
sudo python3 ~/wrc_cmd.py "pll gain 0 0 -1800 -25 18"   # ÷64
```
Dopo ogni comando osservare `wr_stat.sh`: criterio di successo = `md` si stabilizza,
la fase entra e resta, `pll stat` mostra `MPL1`. Registrare kp/ki/shift vincenti.

### 3b. (Opzionale) misurare il K reale dell'attuatore per calcolare lo shift esatto
**Richiede fibra in LOOPBACK** (misura locale a anello aperto) — quindi da fare
rimettendo temporaneamente il loopback, oppure prima/dopo il test ZEN:
```
sudo bash ~/sdm_kf_measure.sh            # v14: default --pack-exp -5 (÷32)
```
Stampa K_dac (ppm/LSB), il rapporto A vs SiT5359 e i kp/ki/shift raccomandati.
(Con A≈1,3 atteso, dovrebbe confermare che serve poco o nulla.)

---

## PASSO 4 — Se `MPL1` STABILE: rendere permanente (no più `pll gain` a mano)
Patch `wrpc-sw/boards/babywr/board.c` `babywr_spll_setup()` righe **228–231** con i
guadagni vincenti del passo 3a, poi rebuild `wrc.bram`. **Trappole build wrc.bram:**
- albero **vero** `kr260_wr_rxpol_exp` (non la copia dentro il progetto Vivado)
- `genraminit ... 196608`, **STACKSIZE 4096**, **niente EXTENDED_CLI** (altrimenti softcore muto)
- `reset_run synth_1` obbligatorio; poi ridispiegare (`deploy_v14.sh` stile).

---

## ⚠️ TRAPPOLE / CHECKLIST (non dimenticarle)
- [ ] **Fibra verso ZEN (BiDi)**, non loopback. RX ~-6 dBm verificato.
- [ ] Scheda caricata **prima** del cavo USB-UART.
- [ ] Dopo OGNI redeploy PL il **GPO laser si azzera** → serve `tx_enable on`
      (test_zen_v14.sh lo fa già; se ricarichi a mano: `sudo python3 ~/tx_enable.py on`).
- [ ] **Un solo consumatore vUART** alla volta: se un `vuart_term.py`/monitor resta attivo,
      gli script danno output vuoto → killarlo.
- [ ] `stat` (nudo) è un **TOGGLE** dell'output continuo → per il one-shot usare `wr_stat.sh`.
      `wrc_cmd`/`wr_stat.sh` vogliono `sudo` (mmap /dev/mem). `version` non esiste in questo build.
- [ ] **Mai** accedere a `0xA00xxxxx` (wrc_cmd/dev-mem) senza app WR caricata → blocca la scheda.
- [ ] Verificare sempre i **timestamp `/dev/uio*`** dopo un load (uio4/5/6 freschi = reale).
- [ ] MAC sempre fisso `00:11:22:33:44:55` a ogni bring-up.

## Riferimenti
- App/script **da copiare lunedì** (passo 0): `$HOME/kr260_wr_sdm_v15/{app/kr260_wr_sdm_app_v15,
  deploy_v15.sh, test_zen_v15.sh}`
- Già a bordo: `~/{test_zen_v14.sh, deploy_v14.sh, wr_stat.sh, sdm_kf_measure.sh,
  tx_enable.py, read_sfp_ddm.py, wrc_cmd.py}` (v14 = fallback)
- Tree build: `$HOME/kr260_wr_sdm_v15` (`rebuild_v15.tcl`, HDL-only); v14 in `..._v14`
- Repo github: `sfp_drp_kr260_sdm` → `wr_endpoint_sdm/{hdl, wrc/*_v1[45], results/RESULTS_v1[45].md}`
- Analisi causa→fix: `results/RESULTS_v14.md` (fix DAC) e `results/RESULTS_v15.md` (LED +
  trappola dei due top); memoria `mpl-phaselock-gain-mismatch`

## Esito atteso = SUCCESSO
`pll stat`: **`MFL1 MPL1`**, `m_phase_lock_ms > 0`, `md` fermo; `wr_stat.sh`: `ptp:slave`
in `TRACK_PHASE`, `lock:1`. → **"Light Rabbit" a fase chiusa via SDM contro il WR-ZEN.**
Salvare `out_zen_v14.log` e aggiornare `RESULTS_v14.md` + memoria con il risultato.

---

## MAPPA LED della scheda (verificata 11/7; LED1/LED2 attivi **da v15**)
| LED fisico | Net / pin | Comportamento | Verifica |
|---|---|---|---|
| **UF2** | `led_link_o` (PL, **E8**) | **fisso** = link WR su · **respira** = sta cercando | staccando la fibra loopback UF2 ha iniziato a "respirare" |
| **UF1** | `led_act_o` (PL, **F8**) | lampeggia sul **PPS** (1/s) | spento in loopback (nessun PPS) |
| **LED1** (cage SFP) | **G8** = `som240_1_a12` = HPA13**P** (Bank 66) | *(v15)* **`tm_time_valid`**: fisso = sincronizzazione WR valida | **è il segno visivo di `MPL1`** |
| **LED2** (cage SFP) | **F7** = `som240_1_a13` = HPA13**N** (Bank 66) | *(v15)* **heartbeat fabric**: respira sempre | **spento = il bitstream NON gira** |
| SOM — LED **centrale** | `heartbeat` (PS, sysfs) | lampeggio kernel (normale) | blink test sysfs |
| SOM — LED **vicino alla vite** | `vbus_det` (PS, sysfs) | fisso = VBUS USB presente | blink test sysfs |
| SOM — 3° LED del gruppo | *(hardware)* | power/status, non pilotabile | — |

**Lettura del bring-up a colpo d'occhio (v15):** dopo il load **LED2 respira** (fabric vivo) →
a link su **UF2 fisso** → a sincronizzazione valida **LED1 fisso** e **UF1 lampeggia 1/s**.
Fino a v14 LED1/LED2 erano spenti perché `G8`/`F7` non erano vincolati in nessun XDC — non
era un guasto.

> ⚠️ **Trappola build (costata un build fallito):** nel progetto Vivado ci sono **due** top con
> struttura LED identica. `hdl/top/kr260_wr/kr260_wr.vhd` è **`AutoDisabled` = file morto**;
> quello sintetizzato è **`kr260_wr_sdm.vhd`** (`TopModule = kr260_wr_sdm` nel `.xpr`).
> Editare l'altro non dà nessun errore finché l'XDC non cerca una porta inesistente.

**Trappola SFP:** `tx_enable off`/`GPO[0]=0` NON spegne davvero questo SFP (TX_DISABLE resta
False, TX power ~-4,8 dBm) → per far cadere il link **staccare la fibra**; l'autoneg in
loopback si completa da solo e non fa cadere `lnk`.
