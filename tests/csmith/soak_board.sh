#!/bin/bash
# soak_board.sh -- AUTONOMOUS on-board (ARM) FPGA csmith soak.  Runs ON the board.
# Loops a manifest of pre-built ELFs (each line "<elf-basename> <refhex>"), runs
# each under  mips-axi -f <elf> --sgi 1, compares the on-silicon checksum to the
# baked QEMU reference, requires a clean magic-halt, and tallies.  No dev box in
# the loop.
#
#   Usage:  ./soak_board.sh [passes] [batchdir]
#             passes   = number of full sweeps (0 => loop forever).   default 0
#             batchdir = dir holding manifest.txt + the *.elf.         default = script dir
#                        (works for an scp'd batch OR an NFS-mounted share; with
#                         NFS, the dev box can keep appending tests -- the manifest
#                         is re-read every sweep so new tests get picked up.)
#
# The bitstream must already be programmed (a timing-clean build).  A hung test
# is killed by the per-test timeout and counted ERROR; the soak keeps going.
PASSES=${1:-0}
BATCH=$(cd "${2:-$(dirname "$0")}" && pwd)
# resolve the driver: non-login ssh shells don't have ~/bin on PATH
MIPS=${MIPS_AXI:-}
[ -z "$MIPS" ] && MIPS=$(command -v mips-axi 2>/dev/null)
for c in "$HOME/bin/mips-axi" "$HOME/axilite-mips/mips-axi"; do
  [ -n "$MIPS" ] && break; [ -x "$c" ] && MIPS="$c"
done
[ -n "$MIPS" ] || { echo "cannot find mips-axi (set MIPS_AXI=...)"; exit 1; }
MANIFEST="$BATCH/manifest.txt"
[ -f "$MANIFEST" ] || { echo "no manifest at $MANIFEST"; exit 1; }

# mips-axi --sgi loads arcs_fw.bin from the cwd; run from a dir that has it
# (the NFS share is typically read-only and won't).
if [ ! -f arcs_fw.bin ] && [ -f "$HOME/mips/arcs_fw.bin" ]; then cd "$HOME/mips"; fi
[ -f arcs_fw.bin ] || echo "warn: arcs_fw.bin not in $PWD -- --sgi may misbehave"

pass=0; fail=0; err=0; round=0
trap 'echo; echo "=== soak stopped: pass=$pass fail=$fail err=$err (sweeps=$round) ==="; exit 0' INT TERM
echo "soak start $(date)  batch=$BATCH  cwd=$PWD  mips=$MIPS  passes=$PASSES"

while :; do
  round=$((round+1))
  while read -r elf ref; do
    [ -z "$elf" ] && continue
    [ -f "$BATCH/$elf" ] || { echo "[r$round] MISS  $elf (not in batch)"; continue; }
    out=$(stdbuf -oL timeout 75 "$MIPS" -f "$BATCH/$elf" --sgi 1 2>&1 \
          | grep -aiE "^checksum|MAGIC HALT|CORE HALTED")
    got=$(printf '%s' "$out" | grep -oiE 'checksum *= *[0-9a-f]+' | grep -oiE '[0-9a-f]+$' | head -1)
    halted=$(printf '%s' "$out" | grep -icE 'MAGIC HALT|CORE HALTED')
    gU=$(printf '%s' "$got" | tr 'a-f' 'A-F'); rU=$(printf '%s' "$ref" | tr 'a-f' 'A-F')
    ts=$(date '+%H:%M:%S')
    if [ -z "$got" ]; then
      echo "[$ts r$round] ERROR $elf no-checksum (hang/timeout?) ref=$ref"; err=$((err+1))
    elif [ "$gU" = "$rU" ] && [ "$halted" -ge 1 ]; then
      pass=$((pass+1))                       # quiet on pass; see per-sweep summary
    else
      echo "[$ts r$round] FAIL  $elf got=$got ref=$ref halted=$halted"; fail=$((fail+1))
    fi
  done < "$MANIFEST"
  echo "[$(date '+%H:%M:%S')] sweep $round done: pass=$pass fail=$fail err=$err"
  [ "$PASSES" -ne 0 ] && [ "$round" -ge "$PASSES" ] && break
done
echo "=== soak done: pass=$pass fail=$fail err=$err (sweeps=$round) ==="
