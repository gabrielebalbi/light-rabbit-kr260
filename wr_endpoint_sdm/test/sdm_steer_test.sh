#!/usr/bin/env bash
# sdm_steer_test.sh — test COMPLETO fw kr260_wr_sdm v4+ (fix accessi 32-bit).
# SCOPERTA out_sdm7: devmem2 su aarch64 fa accessi a 64 bit ("unsigned long") →
# SIGBUS su ogni offset addr%8==4 (fmeter FREQ_CNT@0x04, drp EN@0x0C, RDY@0x14).
# Il "Bus error DRP" era un artefatto del tool. Qui: busybox devmem ADDR 32 [VAL].
# Fa: 1) fmeter baseline  2) lettura DRP QPLL0 (transazione completa)
#     3) STEERING: sdm_base=2^22 via EMIO → Δf attesa sul TX → ripristino 0.
# Uso: sudo bash sdm_steer_test.sh   (app kr260_wr_sdm v4 CARICATA)
set -u
DM(){ busybox devmem "$@"; }
FM=0xA0030000   # fmeter: +0 GATE, +4 FREQ_CNT, +8 STATUS
DRP=0xA0020000  # bridge: +0 ADDR, +4 DI, +8 DO, +C EN, +10 WE, +14 RDY
GPIO0=466       # sdm_base bit0 = EMIO out 54 = gpio 412+54

fmeter(){ # misura con gate 0,800 s (GATE=100e6 cicli @ pl_clk0 = 125 MHz)
  DM $FM 32 0x05F5E100 >/dev/null
  sleep 2.3
  local c=$(DM $((FM+4)) 32); local s=$(DM $((FM+8)) 32)
  echo "  FREQ_CNT=$c (status=$s)  [tx clk ~62.5 MHz; gate 0,800 s -> atteso ~50e6 conteggi]"
}
drp_rd(){ # drp_rd <addr10bit>
  DM $DRP 32 $1 >/dev/null          # ADDR
  DM $((DRP+0x10)) 32 0 >/dev/null  # WE=0
  DM $((DRP+0x0C)) 32 1 >/dev/null  # EN=1
  local i=0; local r=0
  while [ $i -lt 50 ]; do r=$(DM $((DRP+0x14)) 32); [ "$r" = "0x00000001" ] && break; i=$((i+1)); done
  local d=$(DM $((DRP+0x08)) 32)
  echo "  DRP[$(printf 0x%02X $1)] = $d (rdy=$r, poll=$i)"
}
set_base(){ # set_base <valore 25 bit>
  local V=$1
  for i in $(seq 0 24); do
    g=$((GPIO0+i))
    [ -d /sys/class/gpio/gpio$g ] || echo $g > /sys/class/gpio/export 2>/dev/null
    echo out > /sys/class/gpio/gpio$g/direction 2>/dev/null
    echo $(( (V>>i)&1 )) > /sys/class/gpio/gpio$g/value 2>/dev/null
  done
  local RB=0; for i in $(seq 0 24); do v=$(cat /sys/class/gpio/gpio$((GPIO0+i))/value); [ "$v" = 1 ] && RB=$((RB+(1<<i))); done
  echo "  sdm_base = $RB (richiesto $V)"
}
stat_word(){ # sdm_word[24:18] da EMIO in 428..434 + phy_rdy
  local W=0; for i in $(seq 0 6); do
    g=$((428+i)); [ -d /sys/class/gpio/gpio$g ] || echo $g > /sys/class/gpio/export 2>/dev/null
    echo in > /sys/class/gpio/gpio$g/direction 2>/dev/null
    v=$(cat /sys/class/gpio/gpio$g/value); [ "$v" = 1 ] && W=$((W+(1<<i)))
  done
  [ -d /sys/class/gpio/gpio426 ] || echo 426 > /sys/class/gpio/export 2>/dev/null
  echo in > /sys/class/gpio/gpio426/direction 2>/dev/null
  echo "  sdm_word[24:18]=$W  phy_rdy=$(cat /sys/class/gpio/gpio426/value)"
}

echo "== A) baseline (base=0) =="
set_base 0; stat_word; fmeter
echo "== B) DRP QPLL0 (la lettura 'impossibile' di ieri) =="
drp_rd 0x14   # QPLL0_FBDIV
drp_rd 0x11
drp_rd 0x18
echo "== C) STEERING: base = 2^22 (=+0.25 su frazione di N) =="
set_base 4194304; sleep 1; stat_word; fmeter
echo "== D) STEERING: base = 2^24-1 (fondo scala) =="
set_base 16777215; sleep 1; stat_word; fmeter
echo "== E) ripristino base=0 =="
set_base 0; sleep 1; stat_word; fmeter
echo "== Fine: se FREQ_CNT cambia con la base, lo steering SDM e' DIMOSTRATO =="
