#!/usr/bin/env bash
# watch_wr.sh — SOLO osservazione, NIENTE reload/bring-up: non tocca il link WR
# gia' attivo. Poll di stat + pll stat per ~2.5 min per vedere l'aggancio
# (helper -> main -> TRACK_PHASE, dove il softpll comincia a sterzare l'SDM).
# Uso:  sudo bash ~/watch_wr.sh
set -u
if [ "$(id -u)" -ne 0 ]; then echo "!! root:  sudo bash ~/watch_wr.sh"; exit 1; fi
LOG=/home/ubuntu/out_wr_watch.log
exec > >(tee "$LOG") 2>&1
W(){ python3 /home/ubuntu/wrc_cmd.py "$1"; }

echo "=== WATCH WR (no reload) — $(date '+%H:%M:%S') ==="
for i in $(seq 1 15); do
  echo "----- t=$i ($(date '+%H:%M:%S')) -----"
  bash /home/ubuntu/wr_stat.sh
  W "pll stat" | grep -E 'softpll:|main:|ptrack'
  sleep 8
done
echo "=== fine watch ==="
