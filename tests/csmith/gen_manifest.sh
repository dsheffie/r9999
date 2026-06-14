#!/usr/bin/env bash
# gen_manifest.sh -- bake a soak manifest from the ooo_core model (the EXACT RTL
# that runs on the FPGA).  The on-board soak then compares silicon to the same
# design's simulation (sim-vs-silicon) instead of a third-party reference -- this
# is what catches sim/synth mismatches (timing/metastability), the bug class FPGA
# testing exists for.  Works on any dir of ELFs/MIPS binaries (incl. an NFS share
# of pre-generated csmith tests -- no QEMU/source needed).
#
#   Usage:  ./gen_manifest.sh <dir> [checker]
#             checker: 1 = RTL + interpreter lockstep (default; validates the golden)
#                      0 = RTL only (faster)
#   Writes: <dir>/manifest.txt  ("<basename> <checksum-hex>").  An ELF that yields
#           no checksum (co-sim divergence / hang) is SKIPPED and reported.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
OOO="$REPO/ooo_core"
DIR=${1:?usage: gen_manifest.sh <dir> [checker]}
CHK=${2:-1}
[ -x "$OOO" ] || { echo "no ooo_core at $OOO"; exit 1; }
MAN="$DIR/manifest.txt"; : > "$MAN"
ok=0; bad=0
for elf in "$DIR"/*.elf "$DIR"/*.mips; do
  [ -e "$elf" ] || continue
  cs=$(timeout 300 "$OOO" --file "$elf" --maxicnt 2000000000 -c "$CHK" 2>/dev/null \
       | grep -oiE 'checksum *= *[0-9a-f]+' | grep -oiE '[0-9a-f]+$' | head -1)
  if [ -n "$cs" ]; then
    printf "%s %s\n" "$(basename "$elf")" "$cs" >> "$MAN"; ok=$((ok+1))
    printf "  %-16s %s\n" "$(basename "$elf")" "$cs"
  else
    printf "  %-16s SKIP (no checksum: divergence/hang under -c %s)\n" "$(basename "$elf")" "$CHK"; bad=$((bad+1))
  fi
done
echo "manifest: $ok ok, $bad skipped -> $MAN  (ooo_core -c $CHK)"
