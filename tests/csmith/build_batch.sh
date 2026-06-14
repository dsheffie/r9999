#!/usr/bin/env bash
# build_batch.sh -- pre-build a batch of csmith ELFs + a baked checksum manifest
# for an AUTONOMOUS on-board (ARM) FPGA soak.  The board has no csmith / cross
# compiler / qemu, so we generate + build + reference here, push the batch once,
# and let soak_board.sh loop it on the FPGA with no dev-box round-trip per test.
#
#   Usage:  ./build_batch.sh <N> <outdir> [seed_start]   (seed_start default 1000)
#   Output: <outdir>/tNNNNN.elf ... + <outdir>/manifest.txt ("<elf> <refhex>")
#           + a copy of soak_board.sh
#
#   Push:   scp -r <outdir> root@fpga.local:~/mips/
#   Run :   ssh root@fpga.local 'cd ~/mips/<outdir> && nohup ./soak_board.sh 0 > soak.log 2>&1 &'
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
N=${1:?usage: build_batch.sh <N> <outdir> [seed_start]}
OUT=${2:?usage: build_batch.sh <N> <outdir> [seed_start]}
S0=${3:-1000}
mkdir -p "$OUT"
: > "$OUT/qemu_refs.txt"                # QEMU values, kept only as a cross-check
built=0
echo "building $N csmith tests (seeds $S0..$((S0+N-1))) into $OUT ..."
for i in $(seq 0 $((N-1))); do
  seed=$((S0+i))
  elf=$(printf "%s/t%05d.elf" "$OUT" "$seed")
  ref=$("$SCRIPT_DIR/build_one.sh" "$elf" "$seed" 2>/dev/null | sed -n 's/^REF=//p')
  if [ -n "$ref" ] && [ -f "$elf" ]; then
    printf "%s %s\n" "$(basename "$elf")" "$ref" >> "$OUT/qemu_refs.txt"
    built=$((built+1))
    printf "  [%4d] %s qemu=%s\n" "$seed" "$(basename "$elf")" "$ref"
  else
    rm -f "$elf" "$elf.c"
    printf "  [%4d] skip (build/ref failed)\n" "$seed"
  fi
done
rm -f "$OUT"/*.c                       # keep the batch small: ELFs + manifest only

# The FPGA golden is ooo_core (the exact RTL on the board), not QEMU.
echo "------------------------------------------------------------"
echo "baking manifest from ooo_core (sim-vs-silicon golden) ..."
"$SCRIPT_DIR/gen_manifest.sh" "$OUT" 1
# Cross-check: ooo_core (RTL) vs QEMU should agree; a mismatch is a real bug.
mism=$(join <(sort "$OUT/manifest.txt") <(sort "$OUT/qemu_refs.txt") \
       | awk '$2!=toupper($3) && toupper($2)!=toupper($3){print}')
[ -n "$mism" ] && { echo "WARNING: ooo_core vs QEMU MISMATCH (investigate):"; echo "$mism"; }

cp "$SCRIPT_DIR/soak_board.sh" "$OUT/"
echo "------------------------------------------------------------"
echo "batch ready: $built ELFs in $OUT/  (manifest.txt[ooo_core] + soak_board.sh)"
echo "push:  scp -r $OUT root@fpga.local:~/mips/"
echo "run :  ssh root@fpga.local 'cd ~/mips/$(basename "$OUT") && nohup ./soak_board.sh 0 > soak.log 2>&1 &'"
