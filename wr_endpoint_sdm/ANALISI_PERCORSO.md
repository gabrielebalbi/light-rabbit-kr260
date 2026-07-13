# WR Endpoint KR260 + steering QPLL0/SDM — Analisi del percorso

> Documento di sintesi del lavoro svolto sull'endpoint White Rabbit su AMD KR260
> con steering della QPLL0 via Sigma-Delta Modulator ("Light Rabbit").
> Copre: cosa deve portare il meccanismo SDM, i problemi incontrati lungo la
> strada, e il significato dell'autonegoziazione — che è stata la chiave del
> lungo mistero del `lnk:0`.
> Ultimo aggiornamento: 2026-07-07 (firmware v12, `lnk:1` in loopback).

---

## 1. Cosa deve portare il meccanismo SDM ("Light Rabbit")

### 1.1 White Rabbit in due righe
White Rabbit (WR) è un'estensione di PTP/Ethernet che porta la sincronizzazione
sub-nanosecondo su fibra. Il nodo **slave** non si limita a stimare l'offset di
tempo: **disciplina fisicamente il proprio clock TX** in modo che la sua fase
insegua quella del master. Nel WR classico questo avviene con un **VCXO** (quarzo
controllato in tensione) pilotato da un DAC: il softpll del WRPC muove il DAC e il
VCXO cambia leggermente frequenza.

### 1.2 L'idea "Light Rabbit"
Su KR260 non c'è un VCXO dedicato sul datapath del transceiver: il GTHE4 parte da
un **refclk fisso** (U90, 156.25 MHz). L'agilità in frequenza la si ottiene
**dentro il transceiver**, agendo sulla parte **frazionaria del PLL frac-N**
(QPLL0) tramite il suo **Sigma-Delta Modulator (SDM)**:

```
softpll WRPC          invece di →  DAC → VCXO (assente)
   │
   ▼
DAC DPLL 16 bit ─► packing ─► SDM0DATA[24:0] della QPLL0 ─► sposta il VCO ─► sposta TXUSRCLK
                              (+ handshake SDM0TOGGLE)
```

In pratica il **numeratore frazionario** della QPLL0 diventa il nuovo "DAC": una
parola digitale a 25 bit che sposta con continuità la frequenza del VCO a 10 GHz,
e quindi il clock TX. Nessun componente analogico esterno: **tutta la disciplina
di frequenza è digitale, dentro il GT**. Questo è il senso di "Light Rabbit" —
refclk fisso, agilità nel frac-N.

### 1.3 Cosa deve garantire il meccanismo
Perché sia utilizzabile come attuatore del softpll WR, lo steering SDM deve essere:
- **monotòno e lineare** nell'intorno di lavoro (una parola più grande = più
  frequenza, in modo proporzionale);
- **fine** (risoluzione ppb) e con **range** sufficiente a coprire l'incertezza
  dei quarzi (decine di ppm);
- **reversibile** e **deterministico** (nessuna latenza variabile: requisito WR).

### 1.4 Cosa è stato dimostrato (firmware v6, 2026-07-04)
Misurando TXPRGDIVCLK con il frequenzimetro hardware mentre si scrive la parola SDM:
- **Δ = +183.108 ppb** con base `2^22` (atteso +183.110 a DAC=0: accordo a 2 conteggi);
- risposta **lineare** ed **esatta** sotto la saturazione, **reversibile bit-esatto**
  al ritorno alla baseline;
- saturazione del VCO oltre ~+6000 ppm (frac ~0,38), ben oltre il necessario;
- **margine ~15×** rispetto a quanto serve a WR.

➡️ **Il meccanismo di attuazione (SDM come "DAC digitale" del softpll) è validato.**
Quello che mancava per un link WR completo non era l'attuatore, ma la catena
endpoint/PCS lato link — di cui si occupa il resto di questo documento.

---

## 2. Il percorso e i problemi riscontrati

L'endpoint è stato costruito per versioni successive (`kr260_wr_sdm` v1…v12).
Ogni tappa ha isolato e chiuso un problema.

| Fase | Problema | Diagnosi / Fix |
|---|---|---|
| v1 | refclk IP sbagliata (wizard ignorava il frac-N) → QPLL fuori range, vUART muto | corretta la coppia refclk coerente col numeratore 4096 |
| v2→v3 | stallo del reset (clk_sys derivato dal GT) | `clk_sys` free-running separato → WRPC vivo, softpll lock:1 |
| v4 | verificare il TX del GT | catena bring-up TX su EMIO tutta a 1; **loopback ottico: phy_rdy=1** (RX decodifica il proprio TX) |
| v5c | parola SDM impacchettata ma **frequenza ferma** | packing continuo `clamp(base+(dac−32768)·8)` |
| v6 | l'SDM non si aggiornava | `SDM0TOGGLE` mai mosso → change-detect + sequenza 0→1→0 (64 cicli) → **steering dimostrato** |
| v7 | il WR-ZEN non ci "sentiva" | polarità TX **esclusa** (muto con txpol 0 e 1); scoperta la trappola laser |
| v8 | link giù anche in loopback | `rxpcsreset` cablata come da design ufficiale (necessario ma non sufficiente) |
| v9 | dov'è il buco nel PCS? | ILA su phy 16-bit: **datapath perfetto** (idle /I2/ 0xBC50, enc_err=0) in RX **e** TX |
| v10 | il sync detector è agganciato? | ILA dentro `ep_rx_pcs_16bit`: `rx_synced=1`, tutti i gate aperti, `phy_rdy=1` → **il buco è software** |
| v11 | fix software ma vUART **muto** | il wrc ricompilato **non bootava** (vedi §2.2) |
| **v12** | — | **`lnk:1` in loopback** (fix boot + fix autoneg) |

### 2.1 Il lungo mistero del `lnk:0`
Per gran parte del lavoro il link **non saliva mai** (`lnk:0`), pur con:
- ottica sana in entrambi i versi (RX power a livelli nominali);
- polarità TX/RX esclusa sperimentalmente;
- datapath 16-bit **perfetto** agli ILA (idle e comma corretti, zero errori 8b10b);
- PCS **sincronizzato** (`rx_synced=1`, gate aperti, `phy_rdy=1`).

Tutto l'hardware era sano. La causa era **doppia e interamente firmware**:

**(a) Autonegoziazione — vedi §3.** Il software chiamava `ep_enable(dev, 1, an=1)`.
Con `an=1` il flag `EP_DEV_AUTONEG_ENABLED` fa sì che `ep_link_up` richieda
**sia** `LSTATUS` **sia** `ANEGCOMPLETE`. Ma in loopback l'AN hardware non ha un
peer che risponde, quindi `ANEGCOMPLETE` **non sale mai** → `lnk:0` nonostante un
link fisicamente perfetto. Fix: `ep_enable(dev, 1, 0)` → `lnk = LSTATUS`.

**(b) Il wrc ricompilato non bootava.** Vedi §2.2.

### 2.2 La trappola dello stack (perché v11 era muto)
Aggiungere `an=0` e un comando shell richiede di **ricompilare il wrc** e
rigenerarne la BRAM. La ricompilazione **non bootava** (vUART muto: nessun output).
Falsi indizi scartati uno a uno:
- **non** la RAMSIZE (196608 in entrambe le versioni);
- **non** il PHY / LPDC / la polarità.

Causa vera: il firmware babywr che bootava (`c89a57d8`) era prodotto da un ramo
`wrpc-sw` (`babywr_proposed_main`, commit `31209efa`) con
`CONFIG_CUSTOM_STACKSIZE=4096`. Quel ramo **non è più disponibile** (né in locale
né su origin: solo `master`). Su `master` lo stack è un default fisso a **2048**.
Ricompilando su `master` (per giunta con `EXTENDED_CLI` acceso, che consuma più
stack) si otteneva uno **stack overflow all'avvio** — lo stack sta in cima alla
RAM (`arch/risc-v/ram.ld.S`) e con 2048 cresce dentro il codice → il core crasha
**prima** di stampare il banner.

Fix (v12): `Kconfig` → `STACKSIZE` da 2048 a **4096**, tolto `EXTENDED_CLI`,
ricompilato. (La patch binaria del `wrc.elf` buono era impraticabile: LTO ha
inlinato `ep_enable`/`wrc_initialize` e propagato le costanti.)

### 2.3 Trappole "di contorno" (documentate per non ricascarci)
- **Laser spento dal redeploy**: `tx_enable.py` scrive il GPO dell'AXI-IIC nella PL;
  ogni redeploy azzera il GPO → laser off. Va rifatto `tx_enable on` **dopo ogni
  redeploy**.
- **Deploy DFX "finto"**: `xmutil loadapp` può dire "loaded to slot 0" senza
  riprogrammare la PL. Verifica: **timestamp di `/dev/uio*`** e `sec:` piccolo nello `stat`.
- **XVC un solo client**: `xvcServer` serve un client per volta; un `hw_server`
  zombie tiene occupato il canale.
- **Path della BRAM**: la sintesi legge la `wrc.bram` in
  `kr260_wr_rxpol_exp/sw/precompiled/...`, non la copia dentro il progetto; e Vivado
  non traccia il file di init → serve `reset_run synth_1` per rileggerla.

---

## 3. Il significato dell'autonegoziazione

L'autonegoziazione è stata il cuore del mistero `lnk:0`, quindi merita una sezione.

### 3.1 Cos'è (1000BASE-X, IEEE 802.3 Clause 37)
Su fibra Gigabit, prima che il link sia dichiarato "su", i due PCS si scambiano
una **config word** di 16 bit (le "ability": full/half duplex, pause, ecc.)
inviando ordered-set `/C/` (configuration). Quando ciascun lato ha ricevuto in
modo stabile le ability dell'altro, l'AN si dichiara **completa** e alza il bit
**`ANEGCOMPLETE`** nel registro di stato del PCS (MSR). Solo allora il MAC
considera il link realmente utilizzabile.

Punti chiave:
- l'AN **richiede un interlocutore**: è uno scambio, non un test locale;
- `ANEGCOMPLETE` è distinto da `LSTATUS` (link/sync fisico). Si può avere sync
  fisico (`LSTATUS=1`) **senza** che l'AN sia completa (`ANEGCOMPLETE=0`).

### 3.2 A cosa serve l'AN in White Rabbit
In WR l'autonegoziazione 1000BASE-X non è solo formalità: è **il canale con cui i
due nodi si dichiarano WR-capable e avviano l'handshake WR**. Attraverso lo
scambio AN (e le estensioni WR che viaggiano sopra di esso) i due estremi
concordano di entrare in modalità WR e stabiliscono i ruoli master/slave per la
fase di calibrazione. In un link WR **reale**, quindi, **l'AN serve** e va tenuta
attiva: è il preludio al servo di fase che poi sterza il DAC/SDM.

### 3.3 Perché ci ha bloccato (e la soluzione a runtime)
Il gate software:

```
ep_link_up = LSTATUS            se autoneg disabilitato (an=0)
ep_link_up = LSTATUS AND ANEGCOMPLETE   se autoneg abilitato (an=1)
```

- **In loopback** (una scheda con TX→RX su sé stessa) **non c'è un peer** che
  risponda allo scambio AN → `ANEGCOMPLETE` resta 0. Con `an=1` il link fisico
  perfetto risultava comunque `lnk:0`. Con **`an=0`** il gate diventa il solo
  `LSTATUS` → **`lnk:1`**. È così che v12 valida il datapath.
- **Col partner WR-ZEN** la situazione si ribalta: c'è un peer reale che partecipa
  all'AN, quindi conviene **riaccendere l'AN (`an=1`)** perché lo scambio possa
  completare e portare con sé l'handshake WR.

Per non dover ricompilare a ogni prova è stato aggiunto un comando shell **`mdio`**
(`dump` / `rd` / `wr` / `an 0|1`) che permette di leggere i registri PCS e di
**accendere/spegnere l'autoneg a runtime**. Così lo stesso firmware v12 serve sia
il test in loopback (`an=0`) sia il bring-up col partner (`an=1`).

### 3.4 Verifica bit-esatta (v12, loopback)
`mdio dump` con `an=0`:

| reg | valore | lettura |
|---|---|---|
| MCR (0x00) | `0x0140` | AN-enable (bit12) **spento** → an=0; 1000/full |
| MSR (0x04) | `0x018c` | bit2 **LSTATUS=1**, bit5 **ANEGCOMPLETE=0** |
| ANAR (0x10) | `0x0020` | — |
| ANLPAR (0x14)| `0x0000` | nessun partner (loopback) |
| WRSPEC (0x40)| `0x0100` | — |

`stat`: **`lnk:1 rx:29 tx:35 lock:1`**. Cioè: link su per solo `LSTATUS`, senza
pretendere `ANEGCOMPLETE` — esattamente la teoria.

---

## 4. Stato e prossimo passo

- **Endpoint sano end-to-end in loopback** (v12): datapath, PCS, softpll e link OK.
- **Attuatore SDM validato** (v6): steering lineare, fine, reversibile, con margine 15×.
- **Prossimo passo in lab**: fibra **verso il WR-ZEN** (SFP BiDi), `mdio an 1`,
  e verifica che l'AN completi col partner → link WR → il softpll entra in
  `TRACK_PHASE` e comincia a **sterzare l'SDM** per inseguire la fase del master.
  È il punto in cui i due filoni di questo progetto — attuatore SDM e link WR —
  si uniscono.

### Firmware di riferimento
| ver | md5 | note |
|---|---|---|
| v6  | `dd0b03d0` | steering SDM dimostrato |
| v12 | `ed1a9228` | wrc master stack 4096 + `an=0` + cmd `mdio`; **`lnk:1` loopback** |

---

## 5. 7 lug (sera) — Primo link White Rabbit col partner WR-ZEN

Passati dal loopback al partner reale (SFP **BiDi**, fibra verso il WR-ZEN).

### Prima: il collegamento ottico
Con l'autoneg acceso (`mdio an 1`) il link restava giù con **rx:0**. Il DDM del
nostro SFP (`read_sfp_ddm.py`) ha isolato la causa: **RX power −40 dBm, RX LOS**
= non ci arrivava luce. **L'SFP era caduto e si era rotto**: sostituito → RX
−6.60 dBm, LOS cleared. (Trappola operativa: `vuart_term.py` lasciato attivo
**drena il vUART** e svuota l'output degli script — un solo consumatore del vUART
alla volta.)

### Poi: link WR su
Con luce in entrambi i versi e `mdio an 1`:
- **`lnk:1`** stabile, rx cresce (→1200+), **`ptp:slave`**, **tempo TAI adottato
  dal master** (il WR trasferisce il tempo);
- `mdio dump`: **ANEGCOMPLETE=1**, **ANLPAR=0x41a0** (lo ZEN risponde all'AN),
  **WRSPEC=0x0020** (capability WR scambiata) — l'autonegoziazione ha completato
  col partner (cfr. §3);
- **`pll stat`: `mode:slave`, `HL1` (helper lock), `MFL1` (main FREQUENCY lock)**
  → **il softpll pilota l'SDM e aggancia la frequenza sotto WR con un partner
  reale.** Il meccanismo "Light Rabbit" (attuatore SDM) funziona in un link WR
  vero, non più solo standalone.

### Cosa resta: l'aggancio di FASE
Bloccato a `seq:wait-main`: **`MPL0`** (main phase lock mai), `ptrack ready:0`,
`phase` fisso; e `mu`/`crtt`/deltas **spazzatura** → **timestamp non calibrati**.
Cioè: frequenza agganciata via SDM ✅, ma la **calibrazione di fase/timestamp
per-board WR** (ritardi fissi TX/RX, `t24p`, bitslide) non è ancora fatta →
niente sub-ns. È lo step di chiusura previsto per la prossima sessione:
1. calibrazione WR (`calib`/`measure_t24p`, deltas SFP nel database);
2. verifica del loop di **fase** del canale `main` che sterza l'SDM (guadagni/segno,
   quantizzazione fine) e del **DMTD/ptracker** (fase RX-vs-locale).

**Traguardo finale atteso:** `HL1 MFL1 MPL1`, `lock:1`, `ptp:TRACK_PHASE`,
`mu/crtt` sensati → WR sub-ns col DAC/SDM che insegue la fase del master.

### Analisi dell'aggancio di fase (modello + grafici)
L'indagine sul perché `MFL1` sì ma `MPL0` no — con modello numerico del DMTD-shim
e figure — è in [`analysis/`](analysis/README.md). In sintesi: **range OK** e
**quantizzazione del DMTD-shim eliminata** (la media a 512 del ptracker la porta a
~0.013 ps, contro una finestra di phase-lock firmware di ~1172 ps), **plumbing
verificato**; il collo di bottiglia è il **ramo di fase del `main`** (probabile
mistaratura dei guadagni PI, pensati per il DCXO SiT5359 e non per l'attuatore SDM).

---

## 6. Perché fino a oggi non vedevamo i pacchetti dallo ZEN — cause vere vs sintomo autoneg

Domanda ricorrente: *"non vedevamo i pacchetti dallo ZEN per via dell'autonegoziazione
disabilitata?"* Risposta breve: **no, quasi l'opposto.** L'autoneg non era disabilitata
(storicamente era **accesa**); il punto è che **non completava mai**, e la sua
non-completa era un **sintomo**, non la causa.

### Due livelli da non confondere
- **(A) Ricezione fisica / PCS**: luce dallo ZEN → CDR → comma → 8b10b → PCS sync
  (`phy_rdy=1`). Qui stiamo *decodificando i simboli* del partner.
- **(B) `lnk:1` + conteggio frame (`rx`)**: il link è *dichiarato su* ed entra in
  "data mode", dove passano i **frame**. Gate dell'endpoint:
  `ep_link_up = LSTATUS AND (ANEGCOMPLETE se an=1)`.

Storicamente eravamo spesso al livello (A) — **ricevevamo e decodificavamo lo ZEN**
(`phy_rdy=1`, ILA RX pulita) — ma non arrivavamo mai al (B). I "pacchetti" veri
stanno nel (B).

### L'autoneg 1000BASE-X è un handshake bidirezionale
In Clause 37, prima del link non si mandano dati né idle: solo ordered-set `/C/`
con la config word. Il link entra in data-mode **solo quando l'AN COMPLETA**: ogni
lato deve ricevere 3 config word consecutive dell'altro **con ACK**. Quindi:
- se il nostro TX non arrivava valido allo ZEN (o l'ottica era marginale), lo ZEN
  non riceveva le nostre `/C/` → niente ACK → il nostro `ANEGCOMPLETE` restava 0 →
  `lnk:0`; e specularmente lo ZEN restava down;
- restavamo **incastrati in fase di AN**: ricevevamo le sue `/C/` (livello A) ma
  **nessun frame** (livello B, `rx:0`), perché in AN i frame non esistono ancora.

`ANEGCOMPLETE=0` era il **termometro, non la febbre**.

### Perché allora oggi abbiamo *disabilitato* l'autoneg
Solo come trucco di laboratorio e **solo in loopback**: lì non c'è un peer che
risponda all'AN, quindi `ANEGCOMPLETE` non può salire per definizione e con `an=1`
il link fisicamente perfetto risultava `lnk:0`. Con **`an=0`** (gate = solo
`LSTATUS`) → `lnk:1`, e abbiamo **dimostrato l'endpoint sano**. Col partner vero,
invece, l'autoneg va **accesa**: oggi con `an=1` ha **completato**
(`ANEGCOMPLETE=1`, `ANLPAR=0x41a0`, `WRSPEC=0x0020`).

### Le vere cause storiche (sommate)
1. **Endpoint non pienamente funzionante** (v1→v11): refclk, reset dal GT,
   bring-up TX, `rxpcsreset`, e infine il wrc che **non bootava** per lo stack.
   Finché non abbiamo *provato* l'endpoint (loopback `lnk:1`), non si poteva
   separare "colpa nostra" da "colpa del link".
2. **Link ottico verso lo ZEN rotto**: DDM = **RX −40 dBm / LOS** (SFP caduto e
   rotto). Da solo dà `rx:0` a prescindere dal firmware. Combacia con vecchi
   indizi ("SFP wr0 garbage", swap-test che sembrava incolpare il TX on-wire).
3. **Di conseguenza l'AN non poteva completare** (né la nostra né la sua) → mai
   data-mode → nessun frame.

### Perché oggi è andato — sequenza in due mosse
1. **Provato l'endpoint** in loopback (`an=0` + fix stack) → `lnk:1`.
2. **Riparata l'ottica** (SFP nuovo → luce nei due sensi, RX −6.6 dBm).
3. **Riacceso l'autoneg** (`an=1`) verso lo ZEN → AN **completa bidirezionalmente**
   → data-mode → `rx` cresce, `ptp:slave`, tempo dal master.

### In una riga
Non vedevamo i pacchetti dallo ZEN **non perché l'autoneg fosse disabilitata, ma
perché non riusciva mai a COMPLETARE** — e non completava perché (a) l'endpoint non
era del tutto funzionante/bootabile e (b) l'ottica era guasta. Disabilitarla è
servito solo a misurarci in loopback; col partner la febbre è passata quando
abbiamo sistemato **endpoint + ottica**, e allora l'autoneg — accesa — ha fatto il
suo mestiere.
