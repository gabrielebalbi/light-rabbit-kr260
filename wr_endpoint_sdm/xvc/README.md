# XVC — ILA senza cavo JTAG (validato 2026-07-04)

Lettura dell'ILA `u_ila_sdm` **via Ethernet/SSH**, senza cavo JTAG, usando
Xilinx Virtual Cable: nel design c'è la coppia canonica PG245
`debug_bridge_0` (AXI-to-BSCAN, @0xA0040000) + `debug_bridge_1`
(BSCAN→DebugHub); su Linux il bridge è esposto come `generic-uio`.

Nota di progetto: l'auto-inserimento del `dbg_hub` NON convive con un debug
bridge in modalità master (Chipscope 16-336) — serve la coppia esplicita, e
l'ILA va **istanziata** (la netlist-insertion non è supportata col bridge).

## Sorgenti

`xvcServer.c` + `xvc_ioctl.h` + `Makefile` (da Xilinx XilinxVirtualCable,
variante zynqMP). **Fix necessario** (già applicato qui): il sorgente
originale forza `#define USE_IOCTL` incondizionato, quindi anche il target
`make mmap` compilava la variante ioctl (che richiede il driver kernel
`/dev/xilinx_xvc_driver`). Commentata la define → `make mmap` produce la
variante mmap su `/dev/uioN`.

## Procedura (dalla scheda B, via tunnel da A)

```bash
# 1. compila sulla Kria (nativo, no sudo)
make mmap

# 2. trova la uio del bridge (attesa 0xa0040000)
grep . /sys/class/uio/uio*/maps/map0/addr    # → es. uio6
cat /sys/class/uio/uio6/name                 # → debug_bridge

# 3. avvia il server (console, resta in foreground)
sudo ./xvcServer_mmap -d /dev/uio6 -v        # ascolta su :2542

# 4. da A: forward della 2542 attraverso il tunnel già esistente
ssh -N -L 2542:localhost:2542 <user>@<kr260-host> &

# 5. Vivado (anche batch):
#    open_hw_manager; connect_hw_server
#    open_hw_target -xvc_url localhost:2542
#    set_property PROBES.FILE {kr260_wr_sdm_v6.ltx} [current_hw_device]
#    refresh_hw_device ...   → hw_ila_1
```

Sintassi trigger (UG908): operatore `neq`, es.
`set_property TRIGGER_COMPARE_VALUE neq25'h0000000 [get_hw_probes emio_gpio_o_s*]`.

## Risultato (vedi `../results/`)

- `ila_sdm_smoke.csv` — cattura immediata: stato a riposo sano
  (`sdm_word=0`, bring-up flags tutti a 1, toggle idle)
- `ila_sdm_steer.csv` — **handshake v6 dal vivo**, trigger su base≠0:
  campione 512 base 0→2²², **513** `sdm_word`→`0x3C0000` (= 2²²−2¹⁸: DAC=0
  confermato in HW, stesso valore dedotto dal frequenzimetro), **531** toggle
  ↑, **563** toggle ↓ (32 cicli alti, dato congelato) — al ciclo col progetto.

Robustezza: se il collegamento cade mentre l'ILA ha già triggerato, la
cattura resta nella BRAM del core — basta riconnettersi e fare solo
`upload_hw_ila_data` (senza riarmare).
