#!/usr/bin/env python3
"""
Sweep del PACKING DAC->sdm_word: quanto guadagno serve per agganciare la fase?
Usa lo stesso PI del firmware + plant di fase di closed_loop_model.py.

Packing ATTUALE (xwrc_board_kr260_sdm.vhd, p_dac_to_sdm):
  sdm_word += (dac16 - 32768) * 8        (DAC troncato 20->16, moltiplicatore 8)
  => 16 LSB softpll = 1 LSB dac16 = 8 LSB sdm_word  => 0.5 sdm_word / LSB softpll
Packing PROPOSTO (20 bit pieni, moltiplicatore M):
  sdm_word += (dac20 - 2^19) * M         => M sdm_word / LSB softpll
Guadagno attuatore:  Kdac = (sdm_word/LSB) * Kf ,  Kf = Df/f per LSB di sdm_word.
Kf dal v6 ~ 4.366e-14 (STIMA, da misurare a banco).

Vincolo: sdm_word e' a 25 bit. dac20 oscilla +-2^19; per stare dentro ~+-2^24
(lasciando spazio alla base) -> M <= 2^24/2^19 = 32.
"""
import numpy as np
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt

# --- PI/plant (come closed_loop_model.py) ---
DAC_BITS=20; BIAS=1<<(DAC_BITS-1); Y_MAX=(1<<DAC_BITS)-(5<<4); Y_MIN=(5<<4)
HPLL_N=14; f_sys=62.5e6; f_upd=f_sys/2**HPLL_N; S_PHI=2**28
LOCK=1200; KP0,KI0,SH0=-1800,-25,12
Kf = 4.366e-14                        # Df/f per LSB di sdm_word (stima v6)
M_MAX = 32                            # limite da 25 bit sdm_word

def pi_update(st,x,kp,ki,sh):
    i=st['i']+ki*x; y=((i+x*kp)+(1<<(sh-1)))>>sh; y+=BIAS
    if y<Y_MIN: y=Y_MIN; st['i']=i if i>st['i'] else st['i']
    elif y>Y_MAX: y=Y_MAX; st['i']=i if i<st['i'] else st['i']
    else: st['i']=i
    return y

def resid_rms(Kdac,kp,ki,x0=4000.,n=150000):
    st={'i':0}; x=float(x0); xs=np.empty(n)
    rng=np.random.default_rng(0); nz=5.0/1e12*f_sys*2**HPLL_N
    for k in range(n):
        y=pi_update(st,int(round(x+rng.uniform(-nz,nz))),kp,ki,SH0)
        x=x+Kdac*(y-BIAS)*S_PHI; xs[k]=x
    tail=xs[-n//3:]
    return np.sqrt(np.mean(tail**2)), bool(np.all(np.abs(tail)<LOCK))

# --- sweep M per alcuni moltiplicatori di gain PI ---
Ms = np.array([0.5,1,2,4,8,16,32,64,128])
curves = {}
for gmul,lab in [(1,"kp,ki nominali"),(3,"kp,ki ×3"),(10,"kp,ki ×10")]:
    r=[]; ok=[]
    for M in Ms:
        rms,stab = resid_rms(M*Kf, KP0*gmul, KI0*gmul)
        r.append(rms); ok.append(stab)
    curves[lab]=(np.array(r),np.array(ok))
    print("%-14s: " % lab + "  ".join(
        "M=%g:%s(%.0f)"%(M,"OK" if o else "--",rr) for M,rr,o in zip(Ms,r,ok)))

print("\nM attuale effettivo = 0.5 (x8 + troncamento 20->16)")
print("M_max senza overflow 25-bit ~ %d" % M_MAX)

# --- figura ---
BLUE="#0072B2";ORANGE="#E69F00";GREEN="#009E73";VERM="#D55E00";GRAY="#666666";INK="#222222"
plt.rcParams.update({"figure.facecolor":"white","axes.facecolor":"white","savefig.facecolor":"white",
    "axes.edgecolor":"#cccccc","font.size":11,"axes.titlesize":13,"axes.titleweight":"bold",
    "axes.grid":True,"grid.color":"#e6e6e6","axes.spines.top":False,"axes.spines.right":False,
    "figure.dpi":130,"text.color":INK,"axes.labelcolor":INK,"xtick.color":INK,"ytick.color":INK,
    "axes.titlecolor":INK})
fig,ax=plt.subplots(figsize=(7.6,4.4))
for (lab,(r,ok)),c in zip(curves.items(),[VERM,ORANGE,GREEN]):
    ax.loglog(Ms,r,"o-",color=c,lw=1.8,ms=6,label=lab)
ax.axhline(LOCK,color=GRAY,lw=1.4,ls="--"); ax.text(Ms[0],LOCK*1.2,"finestra lock ±1200 tag",color=GRAY,fontsize=9)
ax.axvline(0.5,color=INK,lw=1.2,ls=":"); ax.text(0.5,ax.get_ylim()[1]*0.5,"  M oggi\n  (0.5)",color=INK,fontsize=9)
ax.axvspan(M_MAX,Ms[-1]*1.3,color=VERM,alpha=0.07)
ax.text(M_MAX*1.05,ax.get_ylim()[0]*2,"overflow 25-bit →",color=VERM,fontsize=9)
ax.set_xlabel("moltiplicatore packing  M  (sdm_word per LSB del DAC)")
ax.set_ylabel("errore di fase residuo RMS [tag]")
ax.set_title("H · Aumentare il packing (20 bit + M) porta la fase in lock")
ax.legend(frameon=False,fontsize=9)
fig.tight_layout(); fig.savefig("fig_H_packing.png"); plt.close(fig)

# --- candidato ---
print("\n=> CANDIDATO: con Kf(v6), M nell'intervallo utile e <= 32 (no overflow)")
print("   porta il residuo sotto la finestra di lock gia' coi gain nominali;")
print("   un piccolo bump (kp,ki x3) allarga il margine. Numeri esatti = dopo la")
print("   MISURA di Kf a banco (step del DAC main, Df col frequenzimetro).")
print("figura: fig_H_packing.png")
