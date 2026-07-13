# Modifiche wrc-sw per l'endpoint (firmware v12)

Il softcore **wrpc-sw** (RISC-V, target `babywr`) è il firmware che gira dentro
il gateware e controlla endpoint/PCS/softpll. Questa cartella documenta le
modifiche introdotte per arrivare a **`lnk:1`** e per poter pilotare
l'autonegoziazione a runtime. Vedi [`../ANALISI_PERCORSO.md`](../ANALISI_PERCORSO.md)
per il contesto (in particolare §2.2 stack e §3 autonegoziazione).

Base: `wrpc-sw` `master` (`a9f7580`), `.config` = `babywr_defconfig`.

## Le 3 modifiche

1. **Autoneg off di default** — `wrc_main.c`, in `wrc_initialize()`:
   ```c
   -   ep_enable( &wrc_endpoint_dev, 1, 1 );
   +   ep_enable( &wrc_endpoint_dev, 1, 0 );   /* an=0: lnk = LSTATUS */
   ```
   Con `an=1` `ep_link_up` pretende `LSTATUS AND ANEGCOMPLETE`; in loopback
   `ANEGCOMPLETE` non sale mai (nessun peer) → `lnk:0`. Con `an=0` → `lnk:1`.
   Col partner WR-ZEN si riaccende a runtime con `mdio an 1` (vedi punto 2).

2. **Nuovo comando shell `mdio`** — [`cmd_mdio.c`](cmd_mdio.c), più:
   - `include/cmds.h`: `WRC_COMMAND(mdio)`
   - `shell/shell.mk`: `shell/cmd_mdio.o \`

   Uso:
   ```
   mdio dump           # MCR, MSR, ANAR, ANLPAR, WRSPEC
   mdio rd <reg>       # legge un registro PCS
   mdio wr <reg> <val> # scrive un registro PCS
   mdio an <0|1>       # ep_enable(1, an): accende/spegne l'autoneg a caldo
   ```

3. **Stack a 4096** — `Kconfig`, `config STACKSIZE`:
   ```
   -   default 2048
   +   default 4096
   ```
   Su `master` lo stack è un default fisso 2048 (il ramo babywr originale usava
   `CONFIG_CUSTOM_STACKSIZE=4096`, non più disponibile). A 2048 il wrc va in
   **stack overflow all'avvio** (vUART muto, non bootava — era il bug di v11).
   Togliere anche `CONFIG_EXTENDED_CLI` (consumo stack).

## Ricetta di build (host A)

```bash
cd wrpc-sw
export PATH=$HOME/amd/2025.2/Vitis/gnu/riscv/lin/bin:$PATH
export CROSS_COMPILE=riscv64-unknown-elf-
make babywr_defconfig
# applicare le 3 modifiche sopra, poi:
yes '' | make oldconfig            # STACKSIZE=4096, EXTENDED_CLI off
make clean && make wrc.bin
gcc -o tools/genraminit tools/genraminit.c        # genraminit va compilato
./tools/genraminit -l wrc.bin 196608 > wrc.bram   # 49152 righe, reset vec 0x02c0006f
# installare wrc.bram nel path che legge la sintesi:
cp wrc.bram $HOME/kr260_wr_rxpol_exp/sw/precompiled/wrps-sw-v5_babywr/wrc.bram
# rebuild bitstream (NON ricrea IP): reset_run synth_1 -> impl -> bit -> app
vivado -mode batch -source rebuild_v12.tcl
```

## Deploy sulla scheda

`deploy_v12.sh` (da lanciare come root sulla KR260): installa l'app, ricarica,
verifica UIO/timestamp, riaccende il laser (`tx_enable on`), bring-up minimo,
`stat` e `mdio dump`. Setup atteso: **fibra in LOOPBACK** (per il test `lnk:1`);
per il partner WR-ZEN cambiare SFP (BiDi) e usare `mdio an 1`.

## Esito

`stat` → **`lnk:1 rx:29 tx:35 lock:1`** (loopback). Log completo in
[`../results/out_v12.log`](../results/out_v12.log).

| ver | md5 bitstream | note |
|---|---|---|
| v12 | `ed1a9228` | WNS +3.138; stack 4096 + an=0 + cmd mdio |
| v14 | `e8fd7d24` (bit.bin) | WNS +2.858; **fix HDL DAC 16→20bit** (MPL) + bitslide; `wrc.bram` INVARIATO (stesso di v12) |

## v14 — nota importante: è una modifica **solo HDL**, non wrc-sw

Il `wrc.bram` di v14 è **identico a v12** (stesse 3 modifiche sopra). La causa di
`MPL0` non era nel firmware ma nel gateware: il DAC del softpll era a 16 bit in HDL
mentre il sw lo pilota a 20 bit → wrap a dente di sega (analisi completa in
[`../results/RESULTS_v14.md`](../results/RESULTS_v14.md)). Il fix è nei 3 file HDL
(`hdl/xwrc_board_kr260_sdm.vhd` a 20 bit + packing ÷32; wrapper bitslide) e si
costruisce con [`rebuild_v14.tcl`](rebuild_v14.tcl) (HDL-only, `reset_run synth_1`,
**nessun** rebuild `wrc.bram`).

### Deploy v14 — trappole imparate stasera (2026-07-10)

- **`deploy_v13.sh` non faceva `mkdir -p $DST`** (la sua dir esisteva già): al primo
  run v14 l'install falliva (`cp: No such file or directory`) ma l'`xmutil unloadapp`
  aveva **già tolto** l'app precedente → `loadapp Error -1` e nessun bitstream nuovo.
  La scheda resta col **fabric precedente ancora attivo** (l'unload toglie solo
  l'overlay del device-tree, non ricancella la PL), raggiungibile da `wrc_cmd` via
  `/dev/mem` → **falso senso di "funziona"**. Fix in [`deploy_v14.sh`](deploy_v14.sh):
  aggiunto `mkdir -p "$DST"`. **Verificare sempre i timestamp `/dev/uio*`** (uio4/5/6
  freschi = programmazione reale) — non fidarsi dello `stat`.
- **Nome app univoco** `kr260_wr_sdm_app_v14`: il pacchetto viene generato con
  `make_kr260_app.sh <bit> kr260_wr_sdm_app_v14` così che `firmware-name` nel `.dtbo`
  sia coerente col file `.bit.bin`, **senza collidere** con la dir `kr260_wr_sdm/`
  (che contiene un `kr260_wr_sdm.bit.bin` diverso — rischio di caricare il bitstream
  sbagliato). v13 rinominava i file a mano lasciando un `firmware-name` disallineato.
- **`stat` (bare) è un TOGGLE** dell'output continuo in questo wrc → per la lettura
  one-shot usare `wr_stat.sh`. `wrc_cmd`/`wr_stat.sh` richiedono `sudo` (mmap
  `/dev/mem`). Il comando `version` non esiste in questo build.
