#!/usr/bin/env bash
# sdm_drp_probe.sh — DISCRIMINATORE Bus error DRP (fw kr260_wr_sdm v4, 1376bf07)
# Fatto: drp_common@0xA0020000 dava SIGBUS su WRITE; fmeter@0xA0030000 risponde a READ.
# I due moduli usano lo STESSO template AXI-lite e nel BD sono connessi identici
# (stesso clock pl_clk0, stesso reset, smartconnect M02/M03, segmenti 4K corretti).
# => Ipotesi da discriminare: (A) write-channel del template rotto per entrambi;
#    (B) problema specifico del solo drp_common; (C) anche le READ al drp falliscono.
# Ogni accesso è in un sottoprocesso: un SIGBUS non ferma la sequenza.
# Uso: sudo bash sdm_drp_probe.sh   (con app kr260_wr_sdm v4 CARICATA — trappola AXI!)
set -u
DEV=${DEVMEM:-devmem2}
probe(){ # probe <r|w> <addr> [val]
  local m=$1 a=$2 v=${3:-}
  local out rc
  if [ "$m" = r ]; then out=$($DEV "$a" 2>&1); else out=$($DEV "$a" w "$v" 2>&1); fi
  rc=$?
  if [ $rc -ge 128 ]; then echo "  $m $a ${v:+val=$v }→ **CRASH rc=$rc (SIGBUS?)**"
  else echo "  $m $a ${v:+val=$v }→ ok: $(echo "$out" | grep -oE '(Value at address|Read at address|Written).*' | tail -1)"; fi
  return 0
}
echo "== 1) FMETER 0xA0030000 (riferimento noto-buono in lettura) =="
probe r 0xA0030000            # GATE_CYCLES (default 100e6)
probe r 0xA0030004            # FREQ_CNT
echo "== 2) FMETER WRITE (il discriminatore!): GATE_CYCLES=50e6 =="
probe w 0xA0030000 0x02FAF080
probe r 0xA0030000            # riletto: 0x02FAF080 se la write è passata
echo "== 3) DRP READ puri (nessuna write prima) =="
probe r 0xA0020000            # ADDR
probe r 0xA0020008            # DO
probe r 0xA0020014            # RDY
probe r 0xA0020018            # offset non mappato → atteso 0xDEADBEEF
echo "== 4) DRP WRITE (quella che dava SIGBUS) =="
probe w 0xA0020000 0x14       # ADDR = 0x14 (QPLL0_FBDIV area, innocuo: sola scrittura reg locale)
probe r 0xA0020000            # riletto
echo "== 5) se (4) ok: transazione DRP completa in LETTURA (WE=0, EN=1) =="
probe w 0xA0020010 0x0        # WE=0 (read)
probe w 0xA002000C 0x1        # EN=1 (start)
sleep 0.1
probe r 0xA0020014            # RDY: atteso 1
probe r 0xA0020008            # DO: contenuto DRP reg 0x14 del QPLL0 COMMON
echo "== Fine. Riporta l'output COMPLETO nel log =="
