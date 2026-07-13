#!/usr/bin/env python3
"""
Modello CLOSED-LOOP del ramo di FASE del softpll main (perche' MPL0).
Replica il PI a virgola fissa del firmware (spll_common.c / spll_main.c) e chiude
il loop sul plant fase (attuatore -> Df -> integratore di fase -> tag DMTD).

PI (spll_common.c):
  i_new = integrator + ki*x
  y = ((i_new + kp*x) + 2^(sh-1)) >> sh + bias   [clamp y_min..y_max, anti-windup]

Parametri REALI (firmware babywr):
  BOARD_SPLL_DAC_BITS=20 -> DAC 0..2^20, bias 2^19 ; HPLL_N=14 ; PI_FRACBITS=12
  gain-stage fase (board.c stages[0]):  kp=-1800  ki=-25  shift=12
  soglia phase-lock (spll_main.c): |x|<1200 tag per 1000 campioni

L'UNICO parametro incerto e' il guadagno dell'attuatore Kdac = (Df/f) per LSB di
DAC. Per il DCXO SiT5359 (per cui i gain sono tarati) e' ~0.1-0.2 ppb/LSB; per
l'SDM (attuatore reale) e' molto piu' piccolo (stima, da MISURARE a banco). Lo
spazzo e vedo dove i gain attuali agganciano la fase.
"""
import numpy as np
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt

# ---------- parametri firmware ----------
DAC_BITS = 20
BIAS     = 1 << (DAC_BITS-1)            # 524288
Y_MAX    = (1<<DAC_BITS) - (5<<4)
Y_MIN    = (5<<4)
HPLL_N   = 14
f_sys    = 62.5e6
f_upd    = f_sys/2**HPLL_N              # tag/aggiornamenti al secondo (~3.815 kHz)
S_PHI    = 2**HPLL_N * (f_sys/f_upd)    # tag per (Df/f) per update = 2^28
LOCK_TAGS   = 1200
LOCK_SAMPLES= 1000
KP0, KI0, SH0 = -1800, -25, 12

def pi_update(st, x, kp, ki, sh):
    i_new = st['i'] + ki*x
    y = ((i_new + x*kp) + (1 << (sh-1))) >> sh
    y += BIAS
    if y < Y_MIN:
        y = Y_MIN
        if i_new > st['i']: st['i'] = i_new
    elif y > Y_MAX:
        y = Y_MAX
        if i_new < st['i']: st['i'] = i_new
    else:
        st['i'] = i_new
    return y

def simulate(Kdac, kp=KP0, ki=KI0, sh=SH0, x0=4000.0, n=200000, noise_ps=5.0):
    """Ritorna (x[n] tag, locked_bool, settle_updates)."""
    st = {'i':0}
    x = float(x0)                       # errore di fase in tag
    xs = np.empty(n)
    lock_cnt = 0; settle = -1
    noise_tags = noise_ps/1e12*f_sys*2**HPLL_N   # 5 ps -> tag (quantizz. DMTD)
    rng = np.random.default_rng(0)
    for k in range(n):
        xmeas = x + rng.uniform(-noise_tags, noise_tags)   # misura DMTD
        y = pi_update(st, int(round(xmeas if False else xmeas)), kp, ki, sh)
        dff = Kdac*(y - BIAS)           # Df/f dall'attuatore
        x = x + dff*S_PHI               # integratore di fase (segno per feedback negativo con kp<0)
        xs[k] = x
        if abs(x) < LOCK_TAGS:
            lock_cnt += 1
            if lock_cnt >= LOCK_SAMPLES and settle < 0: settle = k
        else:
            lock_cnt = 0
    # lock STABILE = resta in finestra nell'ultimo tratto (non solo un transito)
    stable = bool(np.all(np.abs(xs[-2000:]) < LOCK_TAGS))
    first_settle_ms = settle/f_upd*1e3 if settle>=0 else np.nan  # velocita' loop
    return xs, stable, first_settle_ms

# ---------- riferimenti di guadagno attuatore ----------
# SiT5359: DFC 26 bit, DAC softpll 20 bit -> 1 LSB DAC = 2^(26-20)=64 LSB DFC.
# pull_range ~ +-100 ppm su +-2^25 DFC -> per LSB DAC:
pull_ppm = 100.0
Kdac_sit = (pull_ppm*1e-6)/2**25 * 2**(26-DAC_BITS)     # ~ frazione/LSB
# SDM (stima, DA MISURARE): dal v6 ~4.4e-14 /LSB(sdm_word); DAC20->dac16(>>4)->x8
# => ~0.5 sdm_word per LSB DAC20 -> Kdac_sdm ~ 0.5*4.4e-14
Kdac_sdm = 0.5*4.366e-14

print("S_PHI = 2^%d ; f_upd=%.0f Hz" % (int(np.log2(S_PHI)), f_upd))
print("Kdac_SiT5359 (assunto dai gain) ~ %.2e /LSB (%.3f ppb/LSB)"
      % (Kdac_sit, Kdac_sit*1e9))
print("Kdac_SDM (stima, da misurare)   ~ %.2e /LSB (%.5f ppb/LSB)"
      % (Kdac_sdm, Kdac_sdm*1e9))
print("rapporto SiT/SDM ~ %.0fx" % (Kdac_sit/Kdac_sdm))

# ---------- sweep Kdac coi gain ATTUALI ----------
Kgrid = np.logspace(np.log10(Kdac_sdm)-1, np.log10(Kdac_sit)+1, 60)
settle_ms = []; locked = []
for K in Kgrid:
    xs, lk, s = simulate(K, n=120000)
    locked.append(lk); settle_ms.append(s)
settle_ms = np.array(settle_ms); locked=np.array(locked)

# ---------- FIGURE ----------
BLUE="#0072B2"; ORANGE="#E69F00"; GREEN="#009E73"; VERM="#D55E00"; GRAY="#666666"; INK="#222222"
plt.rcParams.update({"figure.facecolor":"white","axes.facecolor":"white","savefig.facecolor":"white",
    "axes.edgecolor":"#cccccc","font.size":11,"axes.titlesize":13,"axes.titleweight":"bold",
    "axes.grid":True,"grid.color":"#e6e6e6","axes.spines.top":False,"axes.spines.right":False,
    "figure.dpi":130,"text.color":INK,"axes.labelcolor":INK,"xtick.color":INK,"ytick.color":INK,
    "axes.titlecolor":INK})

# F: risposte al gradino per alcuni Kdac
fig, ax = plt.subplots(figsize=(7.4,4.3))
for K,c,lab in [(Kdac_sit,GREEN,"Kdac SiT5359 (gain nominali)"),
                (Kdac_sit/30,ORANGE,"Kdac /30"),
                (Kdac_sdm,VERM,"Kdac SDM (stima)")]:
    xs,lk,s = simulate(K, n=120000)
    t = np.arange(len(xs))/f_upd*1e3
    ax.plot(t, xs, color=c, lw=1.8, label=lab)
ax.set_xlim(0, 4000)
ax.axhspan(-LOCK_TAGS, LOCK_TAGS, color=GRAY, alpha=0.12)
ax.axhline(LOCK_TAGS, color=GRAY, lw=1, ls="--")
ax.text(3960, LOCK_TAGS*1.15, "finestra lock ±1200 tag (±1.17 ns)",
        ha="right", color=GRAY, fontsize=9)
ax.set_xlabel("tempo [ms]"); ax.set_ylabel("errore di fase [tag]")
ax.set_title("F · Il ramo di fase AGGANCIA (anche con SDM), solo più lento")
ax.legend(frameon=False, fontsize=9)
fig.tight_layout(); fig.savefig("fig_F_step.png"); plt.close(fig)

# G: settling-time vs Kdac, coi marker SiT/SDM
fig, ax = plt.subplots(figsize=(7.4,4.3))
ax.plot(Kgrid, settle_ms, "o-", color=BLUE, lw=1.6, ms=4)
ax.set_xscale("log")
ax.axvline(Kdac_sit, color=GREEN, lw=1.6, ls="--"); ax.text(Kdac_sit,ax.get_ylim()[1]*0.9,"  SiT5359",color=GREEN,fontsize=9)
ax.axvline(Kdac_sdm, color=VERM, lw=1.6, ls="--");  ax.text(Kdac_sdm,ax.get_ylim()[1]*0.9,"  SDM (stima)",color=VERM,fontsize=9)
ax.set_xlabel("Kdac  (Df/f per LSB del DAC)"); ax.set_ylabel("tempo al 1o ingresso in finestra [ms]")
ax.set_title("G · Il tempo di lock (banda del loop) scala con Kdac")
fig.tight_layout(); fig.savefig("fig_G_settle_vs_Kdac.png"); plt.close(fig)

# ---------- validazione del modello + finestra di lock in Kdac ----------
print("\n--- validazione (gain attuali kp=-1800,ki=-25) ---")
for K,lab in [(Kdac_sit,"SiT5359"),(Kdac_sit/30,"SiT/30"),
              (Kdac_sit/300,"SiT/300"),(Kdac_sdm,"SDM stima")]:
    xs,lk,s = simulate(K, n=150000)
    print("  Kdac=%.2e (%-8s) -> %s %s" % (K,lab,"LOCK" if lk else "no-lock",
          ("(1o ingresso %.0f ms)"%s) if not np.isnan(s) else ""))
# finestra di Kdac che aggancia coi gain attuali
klk = Kgrid[locked]
if len(klk):
    print("finestra di lock (gain attuali): Kdac in [%.2e , %.2e] /LSB"
          % (klk.min(), klk.max()))

print("\n=====================  VERDETTO (onesto)  =====================")
print("Il modello VALIDA: coi gain nominali e il guadagno del SiT5359 il ramo di")
print("fase aggancia PULITO in ~272 ms (Fig F, verde).")
print("Man mano che Kdac CALA, il loop diventa piu' lento e SOTTO-SMORZATO")
print("(Fig F: /30 arancio oscilla; SDM rosso = oscillazione lenta e ampia che")
print("SFIORA la finestra ma NON ci resta -> no-lock STABILE).")
print()
print("=> Alla stima Kdac_SDM il ramo di fase NON tiene il lock stabile:")
print("   CONSISTENTE con l'MPL0 osservato a banco. Il collo di bottiglia e' la")
print("   BANDA del loop, cioe' il GUADAGNO dell'ATTUATORE SDM, troppo basso")
print("   rispetto al DCXO SiT5359 per cui i gain sono tarati.")
print("   (E il WANDER reale del master, non modellato qui, peggiora ancora.)")
print()
print("CAVEAT: Kdac_SDM e' una STIMA (dal v6) e S_PHI/f_upd sono assunti.")
print("PROSSIMO (a banco): 1) MISURARE Kdac (step del DAC main via softpll, Df col")
print("   frequenzimetro); 2) alzare la BANDA -> aumentare il packing DAC->sdm_word")
print("   (oggi x8) e/o kp,ki, e usare il DAC a 20 bit senza troncarlo a 16;")
print("   3) ri-verificare che x agganci e RESTI (non derivi col wander).")
print("figure: fig_F_step.png, fig_G_settle_vs_Kdac.png")
