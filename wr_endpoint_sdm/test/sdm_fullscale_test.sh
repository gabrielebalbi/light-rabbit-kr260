#!/usr/bin/env bash
# sdm_fullscale_test.sh — out_sdm12: doppia misura a FONDO SCALA (base=2^24-1)
# per discriminare l'anomalia del caso D di out_sdm11 (frac eff. 0,38 vs 0,98):
#   - se mis1 ≈ mis2  → effetto STABILE = bordo range del Σ-Δ (limite fisico)
#   - se mis1 ≠ mis2  → era un TRANSITORIO nella finestra di misura
# Uso: sudo bash sdm_fullscale_test.sh    (app kr260_wr_sdm v6 caricata)
set -u
DM(){ busybox devmem "$@"; }
FM=0xA0030000
GPIO0=466

set_base(){ local V=$1
  for i in $(seq 0 24); do g=$((GPIO0+i))
    [ -d /sys/class/gpio/gpio$g ] || echo $g > /sys/class/gpio/export 2>/dev/null
    echo out > /sys/class/gpio/gpio$g/direction 2>/dev/null
    echo $(( (V>>i)&1 )) > /sys/class/gpio/gpio$g/value 2>/dev/null
  done
  echo "  sdm_base = $V"
}
fmeter(){ DM $FM 32 0x05F5E100 >/dev/null; sleep 2.3
  echo "  FREQ_CNT=$(DM $((FM+4)) 32) (status=$(DM $((FM+8)) 32))"
}

echo "== baseline base=0, doppia misura =="
set_base 0; sleep 1; fmeter; fmeter
echo "== FONDO SCALA base=2^24-1, TRIPLA misura =="
set_base 16777215; sleep 2; fmeter; fmeter; fmeter
echo "== meta' scala base=2^23 (dentro il range raccomandato), doppia misura =="
set_base 8388608; sleep 1; fmeter; fmeter
echo "== ripristino base=0 =="
set_base 0; sleep 1; fmeter
echo "== Fine out_sdm12 =="
