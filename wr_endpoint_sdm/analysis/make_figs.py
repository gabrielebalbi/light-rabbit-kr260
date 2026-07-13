#!/usr/bin/env python3
"""
Genera le figure dell'analisi del DMTD-shim (perche' MFL1 ok / MPL0 no).
Parametri REALI dal codice: g_acc_bits=18, HPLL_N=14, MMCM Fvco=1GHz -> PS 17.86 ps,
ptracker avg=512, phase-lock window firmware = 1200/2^14*16ns = 1.17 ns.
Output: PNG in questa cartella. Sfondo chiaro, palette colorblind-safe (Wong).
"""
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# ---- parametri ----
f_sys   = 62.5e6
T_ps    = 1e12/f_sys                 # 16000 ps
PS      = (1/1e9)/56*1e12            # 17.857 ps
HPLL_N  = 14
P       = 2**HPLL_N                  # 16384
beat_hz = f_sys/P                    # 3814.7 Hz
thresh  = 2**18
AVG     = 512
LOCKWIN = 1200/2**HPLL_N*T_ps        # 1171.9 ps  (soglia phase-lock firmware)

# ---- stile ----
BLUE="#0072B2"; ORANGE="#E69F00"; GREEN="#009E73"; VERM="#D55E00"; GRAY="#666666"
INK="#222222"; MUTED="#8a8a8a"
plt.rcParams.update({
    "figure.facecolor":"white","axes.facecolor":"white","savefig.facecolor":"white",
    "axes.edgecolor":"#cccccc","axes.labelcolor":INK,"text.color":INK,
    "xtick.color":INK,"ytick.color":INK,"axes.titlecolor":INK,
    "font.size":11,"axes.titlesize":13,"axes.titleweight":"bold",
    "axes.grid":True,"grid.color":"#e6e6e6","grid.linewidth":0.8,
    "axes.spines.top":False,"axes.spines.right":False,"figure.dpi":130})

def phase_staircase(e, n):
    return PS*np.floor(e*n/thresh)

# e non-multiplo di 16: il campionamento DMTD (ogni 2^14 cicli) vede il dente di
# sega della quantizzazione SD (e mult. di 16 -> residuo nullo, punto degenere).
E_BEAT = 14001

# ======================================================================
# FIG A — meccanismo: la fase di clk_dmtd avanza a GRADINI da 17.86 ps
# ======================================================================
e = 14000
n = np.arange(0, 1200)
ph = phase_staircase(e, n)
t_ns = n*1e9/f_sys
fig, ax = plt.subplots(figsize=(7.2,4.0))
ax.step(t_ns, ph, where="post", color=BLUE, lw=1.8)
# retta di offset medio (cio' che un helper VCXO darebbe: rampa liscia)
slope = (ph[-1]-ph[0])/(t_ns[-1]-t_ns[0])
ax.plot(t_ns, ph[0]+slope*(t_ns-t_ns[0]), color=GRAY, lw=1.4, ls="--")
ax.annotate("passo fine-PS MMCM = 17.86 ps", xy=(t_ns[300], ph[300]),
            xytext=(t_ns[120], ph[300]+45), color=INK, fontsize=10,
            arrowprops=dict(arrowstyle="->", color=GRAY, lw=1))
ax.text(t_ns[-1], ph[0]+slope*(t_ns[-1]-t_ns[0]), "  offset medio\n  (VCXO ideale)",
        color=GRAY, va="center", fontsize=9)
ax.set_xlabel("tempo [ns]"); ax.set_ylabel("fase di clk_dmtd [ps]")
ax.set_title("A · Il DMTD-shim avanza la fase a gradini discreti")
fig.tight_layout(); fig.savefig("fig_A_staircase.png"); plt.close(fig)

# ======================================================================
# FIG B — residuo di misura PRIMA e DOPO la media del ptracker (512)
# ======================================================================
e = E_BEAT
K = 6000
ns = np.arange(K, dtype=np.int64)*P
phs = phase_staircase(e, ns)
resid = phs - np.polyval(np.polyfit(ns, phs, 1), ns)
avg = np.convolve(resid, np.ones(AVG)/AVG, mode="valid")
ta = (np.arange(len(avg))+AVG/2)/beat_hz*1e3
fig, (a1,a2) = plt.subplots(2,1, figsize=(7.2,5.4))
# pannello alto: ZOOM su ~90 campioni per vedere il dente di sega
nz = 90
a1.step(np.arange(nz), resid[:nz], where="post", color=ORANGE, lw=1.6)
a1.axhline(0, color=MUTED, lw=0.8)
a1.set_ylabel("residuo [ps]"); a1.set_xlabel("campione DMTD (zoom)")
a1.set_title(f"B · Residuo di fase al DMTD — per campione: {resid.std():.1f} ps RMS")
a1.margins(x=0)
# pannello basso: la media 512 su tutta la durata
a2.plot(ta, avg, color=GREEN, lw=1.8)
a2.axhline(0, color=MUTED, lw=0.8)
a2.set_ylabel("residuo [ps]"); a2.set_xlabel("tempo [ms]")
a2.set_title(f"dopo media ptracker (512 campioni): {avg.std():.3f} ps RMS")
a2.margins(x=0)
fig.tight_layout(); fig.savefig("fig_B_averaging.png"); plt.close(fig)

# ======================================================================
# FIG C — RMS del residuo vs finestra di media N (log-log) + riferimenti
# ======================================================================
Ns = 2**np.arange(0,11)              # 1..1024
rms = []
for w in Ns:
    if w==1: rms.append(resid.std())
    else:
        av = np.convolve(resid, np.ones(w)/w, mode="valid")
        rms.append(av.std())
rms = np.array(rms)
fig, ax = plt.subplots(figsize=(7.2,4.2))
ax.loglog(Ns, rms, "o-", color=BLUE, lw=2, ms=7)
ax.axhline(LOCKWIN, color=VERM, lw=1.8, ls="--")
ax.text(1.1, LOCKWIN*1.15, f"finestra phase-lock firmware = {LOCKWIN:.0f} ps",
        color=VERM, fontsize=10)
ax.axvline(AVG, color=GRAY, lw=1.2, ls=":")
ax.text(AVG*1.05, rms.min()*2, "ptracker\navg = 512", color=GRAY, fontsize=9)
ax.set_xlabel("campioni mediati  N"); ax.set_ylabel("residuo RMS [ps]")
ax.set_title("C · La media azzera la quantizzazione (≪ finestra di lock)")
ax.grid(True, which="both")
fig.tight_layout(); fig.savefig("fig_C_rms_vs_N.png"); plt.close(fig)

# ======================================================================
# FIG D — budget: cosa e' eliminato (scala log, dominio ps)
# ======================================================================
labels = ["Finestra\nphase-lock", "Quantizzazione\nper campione",
          "Quantizzazione\ndopo avg 512"]
vals   = [LOCKWIN, resid.std(), max(avg.std(),1e-3)]
colors = [VERM, ORANGE, GREEN]
fig, ax = plt.subplots(figsize=(7.2,3.6))
y = np.arange(len(labels))[::-1]
ax.barh(y, vals, color=colors, height=0.55)
ax.set_yticks(y); ax.set_yticklabels(labels)
ax.set_xscale("log"); ax.set_xlabel("ps (scala log)")
for yi,v in zip(y,vals):
    ax.text(v*1.25, yi, f"{v:.3g} ps", va="center", fontsize=10, color=INK)
ax.set_xlim(1e-3, 1e4)
ax.set_title("D · Nel dominio ps la quantizzazione e' irrilevante")
ax.spines["left"].set_visible(False); ax.tick_params(left=False)
fig.tight_layout(); fig.savefig("fig_D_budget.png"); plt.close(fig)

# ======================================================================
# FIG E — RANGE del helper: disponibile (g=18) vs richiesto
# ======================================================================
psdone=13
R_sd = 32767*f_sys/thresh; R_hs=f_sys/psdone
avail_ppm = min(R_sd,R_hs)*PS*1e-12*1e6
req_ppm   = 1/2**HPLL_N*1e6
fig, ax = plt.subplots(figsize=(7.2,2.6))
ax.barh([1],[avail_ppm], color=GREEN, height=0.5, label="disponibile (g_acc=18)")
ax.barh([0],[req_ppm],  color=BLUE,  height=0.5, label="richiesto (offset DMTD 1/2¹⁴)")
ax.text(avail_ppm*1.02,1,f"{avail_ppm:.0f} ppm",va="center",color=INK)
ax.text(req_ppm*1.02,0,f"{req_ppm:.0f} ppm",va="center",color=INK)
ax.set_yticks([0,1]); ax.set_yticklabels(["richiesto","disponibile"])
ax.set_xlabel("ppm"); ax.set_xlim(0, avail_ppm*1.25)
ax.set_title("E · Range del helper: OK con margine")
fig.tight_layout(); fig.savefig("fig_E_range.png"); plt.close(fig)

print("figure generate:")
import os
for f in sorted(os.listdir(".")):
    if f.endswith(".png"): print("  ", f, os.path.getsize(f)//1024, "kB")
print(f"\nvalori chiave: lockwin={LOCKWIN:.0f}ps  resid/camp={resid.std():.2f}ps  "
      f"dopo512={avg.std():.4f}ps  range {avail_ppm:.0f}/{req_ppm:.0f}ppm")
