#!/usr/bin/env bash
# deploy_v15.sh — DA ESEGUIRE SULLA SCHEDA come root:  sudo bash ~/deploy_v15.sh
# Installa e carica kr260_wr_sdm v15 = v14 (fix DAC 16->20bit + bitslide) + LED1/LED2.
# La logica WR e' IDENTICA a v14: cambiano solo due porte del top.
#   LED1 (G8) = tm_time_valid  -> fisso quando la sincronizzazione WR e' valida
#   LED2 (F7) = heartbeat      -> respira sempre; se e' spento il bitstream NON gira
# SETUP ATTESO: >>> FIBRA IN LOOPBACK (SFP non-BiDi, TX->RX stessa scheda) <<<
set -u
if [ "$(id -u)" -ne 0 ]; then echo "!! Va lanciato come root:  sudo bash ~/deploy_v15.sh"; exit 1; fi
APP=kr260_wr_sdm_app_v15
SRC=/home/ubuntu/kr260_wr_sdm_app_v15
DST=/lib/firmware/xilinx/$APP
STAMP=$(date +%Y%m%d_%H%M%S)
LOG=/home/ubuntu/out_v15.log
exec > >(tee "$LOG") 2>&1
W(){ python3 /home/ubuntu/wrc_cmd.py "$1"; sleep 1; }

echo "=================================================================="
echo " DEPLOY v15 (= v14 + LED1/LED2 sulla cage SFP)  —  $(date '+%H:%M:%S')"
echo " SETUP: FIBRA IN LOOPBACK (SFP non-BiDi, TX->RX stessa scheda)"
echo "=================================================================="
echo "== md5 sorgente =="; md5sum "$SRC/$APP.bit.bin" || { echo "manca $SRC"; exit 1; }

echo "== backup + install in $DST =="
mkdir -p "$DST"                     # <-- trappola v14: deploy_v13 non lo faceva
for f in "$APP.bit.bin" "$APP.dtbo" shell.json; do
  [ -f "$DST/$f" ] && cp -a "$DST/$f" "$DST/$f.pre_$STAMP"
  cp -f "$SRC/$f" "$DST/$f" && echo "  installato $f"
done
echo "== md5 installato =="; md5sum "$DST/$APP.bit.bin"

echo "== reload app (unload -> load) =="
xmutil unloadapp 2>&1 || true
sleep 1
xmutil loadapp "$APP" 2>&1
sleep 3
echo "== UIO dopo il load (timestamp = prova del programm. reale) =="
for u in /sys/class/uio/uio*; do [ -e "$u/name" ] && printf "  %s: %-18s\n" "$(basename $u)" "$(cat $u/name)"; done
ls -la --time-style=+%H:%M:%S /dev/uio* 2>/dev/null | awk '{print "   "$6" "$7}'

echo ""
echo ">>> GUARDA LA SCHEDA: LED2 (vicino alla cage SFP) deve RESPIRARE ora."
echo "    Se LED2 e' spento, il bitstream v15 non sta girando -> non proseguire."
echo ""

echo "== LASER: tx_enable on (il redeploy azzera il GPO) =="
python3 /home/ubuntu/tx_enable.py on 2>&1 | tail -2

echo "== attesa 6 s per boot wrc =="; sleep 6

echo "== bring-up minimo: MAC fisso, mode slave, ptp start =="
W "ptp stop"; W "mac set 00:11:22:33:44:55"; W "mode slave"; W "ptp start"
echo "== attesa 8 s =="; sleep 8

echo "=================== STAT (atteso lnk:1 in loopback) ==================="
bash /home/ubuntu/wr_stat.sh
echo "=================== MDIO DUMP (registri PCS) ========================="
W "mdio dump"
echo "== FINE deploy v15 =="
