#!/usr/bin/env bash
# run_fpga_regression.sh -- build N fresh csmith tests, run each on the FPGA via
# the henry_arcs FSBL (kseg0 flow), clean magic-halt detection, and compare the
# on-silicon checksum to the QEMU reference.
#
#   Usage: ./run_fpga_regression.sh [N]        (default N=5)
#
# Prereqs: the FPGA must already have a working bitstream programmed (e.g.
#          ../../doit.sh / a timing-clean Henry build), and ~/mips/henry_arcs.bin
#          present on the board.  The test is booted like the kernel:
#            mips-axi -f X.elf --sgi true --arcs henry_arcs.bin --start-pc 0xbfc00000
#          (the old mapped layout + --sgi 1 hung at "state 1"; see
#          project_henry_baremetal_runtime_broken).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
N=${1:-5}
HOST=root@fpga.local
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0; err=0
echo "FPGA csmith regression: $N tests  (host=$HOST)"
echo "=================================================="
for i in $(seq 1 "$N"); do
  elf="$WORK/t$i.elf"
  ref=$("$SCRIPT_DIR/build_one.sh" "$elf" "$i" 2>/dev/null | sed -n 's/^REF=//p')
  if [ -z "$ref" ] || [ ! -f "$elf" ]; then
    printf "[%2d] SKIP   (no reference / build failed)\n" "$i"; continue
  fi
  scp -q "$elf" "$HOST:~/mips/fpga_reg.elf" 2>/dev/null || { printf "[%2d] SKIP   scp failed\n" "$i"; continue; }
  out=$(timeout 100 ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" \
        'cd ~/mips && stdbuf -oL timeout 75 ~/bin/mips-axi -f fpga_reg.elf \
           --sgi true --arcs henry_arcs.bin --start-pc 0xbfc00000 2>&1 \
           | grep -aiE "^checksum|MAGIC HALT|CORE HALTED"' 2>/dev/null)
  got=$(printf '%s' "$out" | grep -oiE 'checksum *= *[0-9a-f]+' | grep -oiE '[0-9a-f]+$' | head -1)
  halted=$(printf '%s' "$out" | grep -icE 'MAGIC HALT|CORE HALTED')
  if [ -z "$got" ]; then
    printf "[%2d] ERROR  no checksum (timeout/hang?)  ref=%s\n" "$i" "$ref"; err=$((err+1))
  elif [ "${got^^}" = "${ref^^}" ] && [ "$halted" -ge 1 ]; then
    printf "[%2d] PASS   %s  (clean halt)\n" "$i" "$got"; pass=$((pass+1))
  else
    printf "[%2d] FAIL   got=%s ref=%s halted=%s\n" "$i" "$got" "$ref" "$halted"; fail=$((fail+1))
  fi
done
echo "=================================================="
echo " FPGA csmith: pass=$pass  fail=$fail  err=$err  / $N"
