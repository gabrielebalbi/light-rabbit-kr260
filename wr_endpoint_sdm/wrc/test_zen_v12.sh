#!/usr/bin/env bash
# test_zen_v12.sh — DA ESEGUIRE SULLA SCHEDA come root:  sudo bash ~/test_zen_v12.sh
# Test link WR col partner WR-ZEN (fw v12 gia' installato).
# SETUP ATTESO: >>> FIBRA VERSO WR-ZEN (SFP BiDi) <<<  (NON loopback)
# Strategia: autoneg ACCESO (mdio an 1) perche' col peer reale l'AN deve completare.
set -u
if [ "$(id -u)" -ne 0 ]; then echo "!! Va lanciato come root:  sudo bash ~/test_zen_v12.sh"; exit 1; fi
APP=kr260_wr_sdm
LOG=/home/ubuntu/out_zen_v12.log
exec > >(tee "$LOG") 2>&1
W(){ python3 /home/ubuntu/wrc_cmd.py "$1"; sleep 1; }

echo "=================================================================="
echo " TEST WR-ZEN (fw v12, autoneg ON)  —  $(date '+%H:%M:%S')"
echo " SETUP: FIBRA VERSO WR-ZEN (SFP BiDi)"
echo "=================================================================="

echo "== reload app v12 (reset pulito del GT/PCS) =="
xmutil unloadapp 2>&1 || true; sleep 1
xmutil loadapp "$APP" 2>&1; sleep 3
echo "== UIO + timestamp =="
for u in /sys/class/uio/uio*; do [ -e "$u/name" ] && printf "  %s: %s\n" "$(basename $u)" "$(cat $u/name)"; done
ls -la --time-style=+%H:%M:%S /dev/uio* 2>/dev/null | awk '{print "   "$6" "$7}'

echo "== LASER on (il redeploy azzera il GPO) =="
python3 /home/ubuntu/tx_enable.py on 2>&1 | tail -2

echo "== attesa 6 s boot wrc; sanity =="; sleep 6
W "ptp stop"
W "mac set 00:11:22:33:44:55"

echo "== AUTONEG ON (mdio an 1): col partner l'AN deve completare =="
W "mdio an 1"

echo "== bring-up: mode slave + ptp start =="
W "mode slave"; W "ptp start"

echo "== osservo il link/PTP per ~40 s (5 letture) =="
for i in 1 2 3 4 5; do
  echo "----- lettura $i ($(date '+%H:%M:%S')) -----"
  bash /home/ubuntu/wr_stat.sh
  sleep 8
done

echo "== MDIO dump finale (ANLPAR = cosa dichiara lo ZEN) =="
W "mdio dump"
echo "== pll stat =="; W "pll stat"
echo "== FINE test ZEN v12 =="
