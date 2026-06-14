#!/bin/bash
# soak_board.sh -- autonomous on-board cheri FPGA soak.  Runs ON the ARM.
# For each test in manifest.txt: run the ELF, capture the R<dd>= dump (killing
# mips-axi as soon as 32 lines appear -- the test free-runs after the dump since
# `break` doesn't halt r9999), diff against the baked ooo_core golden, tally.
# Run from the batch dir.
#
#   Usage:  ./soak_board.sh [reprogram_each] [bitstream]
#             reprogram_each: 1 = fpgautil -b before every test (default; CP0 is
#                             sticky), 0 = rely on the driver's per-run reset
#             bitstream:      default ~/mips/ultra96v2_oob_wrapper.bit
REPROG=${1:-1}
BIT=${2:-$HOME/mips/ultra96v2_oob_wrapper.bit}
MIPS=$(command -v mips-axi 2>/dev/null); [ -z "$MIPS" ] && MIPS=$HOME/bin/mips-axi
BATCH=$(cd "$(dirname "$0")" && pwd)
[ -f "$BATCH/manifest.txt" ] || { echo "no manifest at $BATCH"; exit 1; }
cd "$HOME/mips" 2>/dev/null   # mips-axi --sgi-less still wants arcs_fw.bin in cwd

CAP=/tmp/cheri_cap.out
run_one() {           # $1 = elf path; emits the 32 R-lines on stdout
  [ "$REPROG" = 1 ] && fpgautil -b "$BIT" >/dev/null 2>&1
  : > "$CAP"
  stdbuf -oL timeout 40 "$MIPS" -f "$1" --maxiters 100000000 >"$CAP" 2>&1 &
  local pid=$! i
  for i in $(seq 1 40); do
    [ "$(grep -acE '^R[0-9]{2}=' "$CAP")" -ge 32 ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  grep -aE '^R[0-9]{2}=' "$CAP" | head -32
}

pass=0; fail=0; err=0
echo "cheri FPGA soak start $(date)  reprogram_each=$REPROG"
while read -r name; do
  [ -z "$name" ] && continue
  got=$(run_one "$BATCH/$name.elf")
  exp=$(cat "$BATCH/$name.golden" 2>/dev/null)
  gn=$(printf '%s\n' "$got" | grep -cE '^R[0-9]{2}=')
  if [ "$gn" -ne 32 ]; then
    echo "ERROR $name (got $gn/32 R-lines)"; err=$((err+1))
  elif [ "$(printf '%s\n' "$got" | sort)" = "$(printf '%s\n' "$exp" | sort)" ]; then
    pass=$((pass+1))
  else
    echo "FAIL  $name"
    diff <(printf '%s\n' "$exp" | sort) <(printf '%s\n' "$got" | sort) | grep '^[<>]' | head -8
    fail=$((fail+1))
  fi
done < "$BATCH/manifest.txt"
echo "=== cheri FPGA: pass=$pass fail=$fail err=$err ==="
