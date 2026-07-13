# v15 — LED1/LED2 della cage SFP pilotati (logica WR invariata rispetto a v14)

**Data:** 2026-07-11. Build per il test MPL col WR-ZEN di lunedì 2026-07-13.

## Perché

I due LED accanto alla cage SFP (**LED1** e **LED2**) risultavano spenti. Indagando si è
scoperto che **non sono un guasto**: nessuna build SDM li ha mai vincolati, quindi i pin
`G8`/`F7` restano flottanti. L'unico bitstream che li accendeva era il vecchio `DEBUG`
(pre-SDM, `G8=link` / `F7=pps`), inutilizzabile per il test MPL.

v15 li accende, così lunedì l'esito del bring-up si legge **a colpo d'occhio, senza terminale**.

## Cosa cambia rispetto a v14

**Solo i LED.** Il ramo SDM / DAC / bitslide è byte-identico a v14: nessuna modifica al
packing, a `g_dac_bits`, al wrapper GT o al `wrc.bram`. v15 ≡ v14 + due porte sul top.

Nel top `kr260_wr_sdm.vhd`:
```vhdl
led1_o <= tm_time_vld_s;   -- tm_time_valid_o del WR core (era 'open')
led2_o <= hb_led_s;        -- heartbeat del fabric (gia' esistente, ora anche su F7)
```
In `kr260_wr.xdc`:
```
set_property PACKAGE_PIN G8 [get_ports led1_o]   ;# som240_1_a12 = HPA13P, bank 66
set_property PACKAGE_PIN F7 [get_ports led2_o]   ;# som240_1_a13 = HPA13N, bank 66
set_property IOSTANDARD LVCMOS18 [get_ports {led1_o led2_o}]
```
`LVCMOS18` = stesso standard/bank 66 di `E8`/`F8` (i LED già pilotati), come faceva il DEBUG.

## ⚠️ TRAPPOLA: nel progetto Vivado ci sono DUE top

Il primo tentativo di build è **fallito**:
```
ERROR: [Common 17-55] 'set_property' expects at least one object.  [kr260_wr.xdc:80..83]
```
Causa: le edit HDL erano finite in **`hdl/top/kr260_wr/kr260_wr.vhd`** (entity `kr260_wr`),
che nel `.xpr` è marcato **`AutoDisabled="1"` → file morto**. Il top realmente sintetizzato è
**`hdl/top/kr260_wr/kr260_wr_sdm.vhd`** (entity `kr260_wr_sdm`, `<Option Name="TopModule"
Val="kr260_wr_sdm"/>`). I due file hanno struttura LED **identica**, quindi la svista non dà
nessun segnale finché l'XDC non cerca una porta che non esiste.

**Regola:** in questo progetto si edita **solo `kr260_wr_sdm.vhd`**. Per sicurezza,
`rebuild_v15.tcl` stampa un `PIN CHECK` esplicito dopo il route:
```tcl
foreach p {led1_o led2_o led_link_o led_act_o} {
  puts "PIN CHECK: $p -> [get_property PACKAGE_PIN [get_ports $p]] ([get_property IOSTANDARD [get_ports $p]])"
}
```

## Mappa LED completa (verificata sulla scheda l'11/7)

| LED fisico | Pin / sorgente | v14 | **v15** |
|---|---|---|---|
| **UF2** | `led_link_o` = **E8** (PL) | fisso = link WR su · respiro = sta cercando | invariato |
| **UF1** | `led_act_o` = **F8** (PL) | lampeggia sul **PPS** (spento in loopback: niente PPS) | invariato |
| **LED1** (cage SFP) | **G8** = som240_1_a12 = HPA13P, bank 66 | *non vincolato → spento* | **`tm_time_valid`**: fisso = sincronizzazione WR valida → **è il segnale visivo di `MPL1`** |
| **LED2** (cage SFP) | **F7** = som240_1_a13 = HPA13N, bank 66 | *non vincolato → spento* | **heartbeat fabric**: respira sempre → **spento = il bitstream non gira** |
| SOM, LED centrale | `heartbeat` (PS, sysfs) | lampeggio kernel (normale) | invariato |
| SOM, LED vicino alla vite | `vbus_det` (PS, sysfs) | fisso = VBUS USB presente | invariato |
| SOM, 3° LED del gruppo | hardware | power/status, non pilotabile | invariato |

LED2 è utile come **verifica indipendente dal software**: se dopo un `xmutil loadapp` non
respira, il PL non è stato programmato davvero (finora l'unico controllo era il timestamp
di `/dev/uio*`).

## Build

`wrc/rebuild_v15.tcl` — HDL-only (`reset_run synth_1`, no regen IP, no rebuild `wrc.bram`).

**Esito: WNS +3.015 ns** (v14: +2.858 ns — la differenza è rumore di place&route, i due
design sono logicamente equivalenti). Pin check dopo il route:

```
PIN CHECK: led1_o     -> G8 (LVCMOS18)
PIN CHECK: led2_o     -> F7 (LVCMOS18)
PIN CHECK: led_link_o -> E8 (LVCMOS18)
PIN CHECK: led_act_o  -> F8 (LVCMOS18)
```

App: `kr260_wr_sdm_app_v15/` — `.bit.bin` (md5 `087e2e613381325685c6ab87b00aeded`),
`.dtbo` con `firmware-name = "kr260_wr_sdm_app_v15.bit.bin"`, `shell.json`.

## ✅ ESITO 2026-07-13: PHASE LOCK RAGGIUNTO contro il WR-ZEN

**`MFL1 MPL1`, `ptp:slave` in `TRACK_PHASE`, `lock:1`.** Obiettivo centrato al primo colpo,
**senza toccare i guadagni**: la gain-schedule BabyWR di serie (`m_kp:-1800 m_ki:-25 m_sh:12`)
funziona ora che il DAC 20-bit non wrappa più. Il blocco FALLBACK `pll gain` **non è servito**.

Log completo: `shared_handoff/out_zen_v15.log` (test) + monitor esteso 6 min.

| Grandezza | Valore | Commento |
|---|---|---|
| `ss` | `TRACK_PHASE` | stabile da ~40 s dopo lo start, **mai perso in 8 min** |
| `cko` (clock offset) | **0, entro ±5 ps** | sincronizzazione ben **sub-nanosecondo** |
| `m_phase_lock_ms` | 3597 | aggancio di fase in ~4 s, mai perso |
| `m_freq_lock_ms` | 674 | |
| `setp` / `ptrack phase` | 15518 ±3 LSB / 15889 (15516 ps) | fermi |
| `md` (DAC main) | 624k → 634k, **poi piatto** | deriva termica di warm-up, **non** il limit-cycle ±5000 di v13 |
| `bslide` | 1600 | |
| Autoneg | `ANLPAR = 0x41a0` | lo ZEN risponde |
| Ottica | RX **-6.60 dBm**, TX -5.76 dBm, no LOS | SFP BiDi verso lo ZEN |

**Diagnosi confermata:** la causa di `MPL0` in v12/v13 era il mismatch di guadagno prodotto dal
wrap a dente di sega del DAC 16-bit (A≈342×), non la taratura dell'anello. Con il packing /32
(A≈1,3) la fase entra nella finestra ±1,17 ns e ci resta.

Il `cko` resta entro ±5 ps **mentre `md` deriva**: è la prova che l'anello sta attivamente
inseguendo (non è fermo per caso). Margine DAC verso il fondo scala (2^20): ~415k LSB.

→ **"Light Rabbit": endpoint White Rabbit a fase chiusa via steering SDM/QPLL0, contro un
WR-ZEN commerciale.** v15 è la nuova build di riferimento.

## Stato precedente (pre-test)

Buildato sulla workstation l'11/7; deploy bloccato perché la scheda era spenta e non c'è
accensione da remoto (niente BMC/IPMI, dongle WiFi → niente WoL, niente PDU).
v14 restava il fallback — **non è servito**.

## Trappole ereditate (valgono anche per v15)

- Dopo OGNI redeploy PL il GPO del laser si azzera → `tx_enable.py on` (gli script lo fanno).
- `deploy_*.sh` deve fare `mkdir -p "$DST"` (v13 non lo faceva → `loadapp Error -1`).
- `stat` bare è un TOGGLE dell'output continuo → per il one-shot usare `wr_stat.sh`.
  `wrc_cmd`/`wr_stat.sh` vogliono `sudo`. `version` non esiste in questo build.
- Mai accedere a `0xA00xxxxx` senza app WR caricata → blocca la scheda.
