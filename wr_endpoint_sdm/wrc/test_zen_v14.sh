#!/usr/bin/env bash
# test_zen_v14.sh — DA ESEGUIRE SULLA SCHEDA come root:  sudo bash ~/test_zen_v14.sh
# Test link WR col partner WR-ZEN con il fw v14 (fix DAC 16->20bit + bitslide).
# SETUP ATTESO: >>> FIBRA VERSO WR-ZEN (SFP BiDi) <<<  (NON loopback)
#
# OBIETTIVO: passare da MFL1 (freq gia' agganciava in v12/v13) a MPL1 (fase).
# Il fix v14 porta l'HDL a 20 bit coerente col wrc.bram BabyWR (BOARD_SPLL_DAC_BITS=20):
# il DAC main non wrappa piu' a dente di sega e il guadagno d'anello all'attuatore SDM
# scende da A~342x a A~1.3 (packing /32 invece di x8), dentro il range per cui la
# gain-schedule BabyWR (kp -1800/ki -25/shift 12) e' tarata -> la fase dovrebbe entrare
# e restare nella finestra +/-1.17 ns e scattare MPL1.
#
# Se MPL NON aggancia (limit-cycle residuo, MY che sbatte), scommentare il BLOCCO
# FALLBACK piu' sotto: abbassa il guadagno del MAIN a runtime alzando 'shift'.
set -u
if [ "$(id -u)" -ne 0 ]; then echo "!! Va lanciato come root:  sudo bash ~/test_zen_v14.sh"; exit 1; fi
APP=kr260_wr_sdm_app_v14
LOG=/home/ubuntu/out_zen_v14.log
exec > >(tee "$LOG") 2>&1
W(){ python3 /home/ubuntu/wrc_cmd.py "$1"; sleep 1; }

echo "=================================================================="
echo " TEST WR-ZEN (fw v14: DAC 20bit + bitslide, autoneg ON)  --  $(date '+%H:%M:%S')"
echo " SETUP: >>> FIBRA VERSO WR-ZEN (SFP BiDi) <<<   (NON loopback!)"
echo "=================================================================="

echo "== reload app v14 (reset pulito del GT/PCS) =="
xmutil unloadapp 2>&1 || true; sleep 1
xmutil loadapp "$APP" 2>&1; sleep 3
echo "== UIO + timestamp (uio4/5/6 devono essere FRESCHI = programm. reale) =="
for u in /sys/class/uio/uio*; do [ -e "$u/name" ] && printf "  %s: %s\n" "$(basename $u)" "$(cat $u/name)"; done
ls -la --time-style=+%H:%M:%S /dev/uio* 2>/dev/null | awk '{print "   "$6" "$7}'

echo "== LASER on (il redeploy azzera il GPO) =="
python3 /home/ubuntu/tx_enable.py on 2>&1 | tail -2

echo "== attesa 6 s boot wrc; sanity =="; sleep 6
W "ptp stop"
W "mac set 00:11:22:33:44:55"

echo "== AUTONEG ON (mdio an 1): col partner reale l'AN deve completare =="
W "mdio an 1"

echo "== bring-up: mode slave + ptp start =="
W "mode slave"; W "ptp start"

# ----------------------------------------------------------------------------
# BLOCCO FALLBACK (default OFF) -- usare SOLO se MPL non aggancia (MY che sbatte).
# Abbassa il guadagno del ramo di fase del MAIN (loop 0) alzando 'shift' 12->16.
# Provare 16, poi 17 (/32), poi 18 (/64). SPLL_LOOP_MAIN=0, stage 0.
#   W "pll gain 0 0 -1800 -25 16"
# ----------------------------------------------------------------------------

echo "== osservo link + freq/phase lock per ~2 min (12 letture x 8 s) =="
echo "   ATTESO: lnk:1, poi pll stat con MFL1 e finalmente MPL1 (m_phase_lock_ms>0)."
for i in $(seq 1 12); do
  echo "----- lettura $i ($(date '+%H:%M:%S')) -----"
  bash /home/ubuntu/wr_stat.sh 2>/dev/null | grep -E 'lnk:'
  W "pll stat" 2>/dev/null | grep -iE 'mode|MFL|MPL|HL|m_kp|m_phase_lock|MY|locked' | sed 's/^/     /'
  sleep 7
done

echo "== stato PTP finale (atteso ptp:slave -> TRACK_PHASE se MPL1) =="
bash /home/ubuntu/wr_stat.sh 2>/dev/null | grep -E 'lnk:|ptp:'
echo "== MDIO dump finale (ANLPAR = cosa dichiara lo ZEN) =="
W "mdio dump"
echo "== pll stat finale =="; W "pll stat"
echo "=================================================================="
echo " ESITO ATTESO SUCCESSO: pll stat mostra 'MFL1 MPL1', m_phase_lock_ms>0,"
echo " md (uscita DAC) fermo entro poche unita', ptp:slave in TRACK_PHASE, lock:1."
echo " Se MFL1 ma MPL0 persistente -> attivare il BLOCCO FALLBACK (pll gain shift 16+)."
echo "== FINE test ZEN v14 =="
