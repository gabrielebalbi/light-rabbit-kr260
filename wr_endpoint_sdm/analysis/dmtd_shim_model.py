#!/usr/bin/env python3
"""
Modello DMTD-shim v2 (parametri REALI: g_acc_bits=18).
Focus: la quantizzazione/idle-tone del sigma-delta si media via col ptracker(512)
sotto la finestra di phase-lock? -> spiega MFL1 ok / MPL0 no?
"""
import numpy as np

f_sys   = 62.5e6
T_sys_ps= 1e12/f_sys                     # 16000 ps
ps_step = (1.0/1.0e9)/56.0*1e12          # 17.857 ps
HPLL_N  = 14
P       = 2**HPLL_N                       # 16384 cicli sys per beat
beat_hz = f_sys/P                         # 3814.7 Hz
g_acc   = 18
thresh  = 2**g_acc
AVG     = 512
psdone  = 13

# operiamo il helper per un offset DMTD realistico ~ req (1/2^14 = 61 ppm)
req_frac = 1.0/P                          # 61.0 ppm
e_op = int(round(req_frac * thresh / (ps_step*1e-12) / f_sys))
# e tale che rate*step = req_frac : rate=e*f_sys/thresh ; rate*step_s=req_frac
e_op = int(round(req_frac / (ps_step*1e-12) * thresh / f_sys))
R = e_op*f_sys/thresh
print("="*66); print(" MODELLO DMTD-SHIM v2  (g_acc_bits=18 REALE)"); print("="*66)
print(f" passo PS {ps_step:.2f} ps | beat {beat_hz:.0f} Hz | thresh 2^18 | avg {AVG}")
R_hs = f_sys/psdone
print(f" range max helper: {min(32767*f_sys/thresh,R_hs)*ps_step*1e-12*1e6:.0f} ppm "
      f"(HS-limited)  vs richiesto {req_frac*1e6:.0f} ppm -> RANGE OK")
print(f" punto di lavoro: e={e_op}, rate {R/1e6:.2f} Mpulse/s "
      f"(HS {R_hs/1e6:.2f}M -> handshake {'non ' if R<R_hs else ''}binding)")

# --- SD vettorizzato (senza dead-time: al punto di lavoro non e' binding) ---
# fase cumulata (ps) al ciclo n = ps_step * floor(e*n/thresh)
K = 40000                                  # campioni di beat (>> AVG)
n = np.arange(K, dtype=np.int64)*P         # indici di campionamento DMTD
phase_ps = ps_step*np.floor(e_op*n/thresh)

# residuo = fase - rampa (l'offset voluto e' il beat; il residuo e' l'errore SD)
ramp = np.polyval(np.polyfit(n, phase_ps, 1), n)
resid = phase_ps - ramp

print(f"\n--- residuo di fase al DMTD (per campione) ---")
print(f" pp {resid.ptp():.2f} ps | RMS {resid.std():.2f} ps  "
      f"(~ 1 passo PS = {ps_step:.1f} ps, atteso)")

# --- media ptracker 512 ---
avg = np.convolve(resid, np.ones(AVG)/AVG, mode='valid')
print(f"\n--- dopo media ptracker ({AVG}) ---")
print(f" RMS {avg.std():.3f} ps | pp {avg.ptp():.3f} ps")
print(f" (rumore bianco darebbe {resid.std()/np.sqrt(AVG):.3f} ps: se il residuo")
print(f"  e' idle-tone a bassa freq, la media rende MENO)")

# --- spettro dell'idle-tone: dove sta l'energia? ---
r = resid - resid.mean()
F = np.abs(np.fft.rfft(r*np.hanning(len(r))))
fr = np.fft.rfftfreq(len(r), d=1.0/beat_hz)     # Hz
k = np.argmax(F[1:])+1
print(f"\n--- idle-tone dominante ---")
print(f" picco a {fr[k]:.1f} Hz  ({fr[k]/beat_hz*100:.2f}% del beat)")
# banda passante tipica del loop main (Hz): l'idle-tone in-band NON si filtra
bw_main = 50.0
inband = F[(fr>0)&(fr<bw_main)]
print(f" energia sotto ~{bw_main:.0f} Hz (banda loop main): "
      f"{'PRESENTE' if inband.max()>0.1*F[1:].max() else 'trascurabile'}")

print("\n"+"="*66); print(" VERDETTO v2"); print("="*66)
print(f" - RANGE: OK con g=18 (~86 ppm > 61). NON e' il problema (mio errore v1).")
print(f" - QUANTIZZAZIONE: ~{resid.std():.1f} ps RMS/campione (1 passo PS 17.9 ps),")
print(f"   dopo avg 512 -> {avg.std():.2f} ps RMS con struttura idle-tone a {fr[k]:.0f} Hz.")
print(f" - Se {avg.std():.2f} ps residuo (o l'idle-tone in-band) supera la finestra")
print(f"   di phase-lock (~pochi ps), il main non chiude MPL e il ptracker non si")
print(f"   stabilizza -> coerente con MFL1(media)/MPL0(fase). Se invece <~1-2 ps,")
print(f"   la quantizzazione da sola NON basta a spiegare MPL0 -> guardare altrove")
print(f"   (mapping canale ptracker/recovered clock, o dinamica di inseguimento).")
