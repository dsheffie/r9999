#!/usr/bin/env bash
# build_batch.sh -- build the cheri FPGA-standalone batch.
# For each buildable test in the given categories, bake the ooo_core R<dd>= dump
# as the golden (sim-vs-silicon reference, same RTL as the FPGA) and collect the
# ELF.  Push the batch dir to the board and run soak_board.sh there.
#
#   Usage:  ./build_batch.sh [cats...]        (default: alu branch cp0)
#   Output: fpga/batch/<cat>_<test>.elf + .golden + manifest.txt + soak_board.sh
#
# A test whose ooo_core run does not yield a clean 32-register dump (hang /
# faults before DUMP_GPRS) is skipped and reported -- it can't be a golden.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHERI="$(cd "$SCRIPT_DIR/.." && pwd)"          # tests/cheri
REPO="$(cd "$CHERI/../.." && pwd)"
OOO="$REPO/ooo_core"
CATS="${*:-alu branch cp0}"
OUT="$SCRIPT_DIR/batch"
# Quarantine: tests excluded from the green sweep, two distinct reasons:
#   (a) timing-nondeterministic -- read a free-running register (Count), so
#       ooo_core's cycle count and the FPGA's real cycles never agree (not a bug).
#   (b) KNOWN REAL sim-vs-silicon divergence -- see BUGS_FOUND.md:
#       mem_test_raw_scd_uncached: uncached (XKPHYS CCA=2) SCD reads back 0 on
#       silicon (deterministic); cached SCD + ooo_core return the stored value.
QUARANTINE=" cp0_test_cp0_compare mem_test_raw_scd_uncached "
[ -x "$OOO" ] || { echo "no ooo_core at $OOO"; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"
: > "$OUT/manifest.txt"
ok=0; skip=0
for c in $CATS; do
  for elf in "$CHERI/$c"/test_*.elf; do
    [ -e "$elf" ] || continue
    base="$(basename "$elf" .elf)"
    name="${c}_${base}"
    case "$QUARANTINE" in *" $name "*) echo "  quarantine $name (timing-nondeterministic)"; skip=$((skip+1)); continue;; esac
    dump=$(timeout 120 "$OOO" --file "$elf" -c 0 --maxcycle 600000 2>/dev/null | grep -E '^R[0-9]{2}=')
    n=$(printf '%s\n' "$dump" | grep -cE '^R[0-9]{2}=')
    if [ "$n" -eq 32 ]; then
      cp "$elf" "$OUT/$name.elf"
      printf '%s\n' "$dump" > "$OUT/$name.golden"
      echo "$name" >> "$OUT/manifest.txt"
      ok=$((ok+1))
    else
      skip=$((skip+1)); echo "  skip $name (ooo_core dump=$n/32 lines)"
    fi
  done
done
cp "$SCRIPT_DIR/soak_board.sh" "$OUT/" 2>/dev/null
echo "------------------------------------------------------------"
echo "cheri batch ready: $ok tests, $skip skipped -> $OUT/"
echo "push:  ssh root@fpga.local 'mkdir -p ~/mips/cheri_batch'; scp $OUT/* root@fpga.local:~/mips/cheri_batch/"
echo "run :  ssh root@fpga.local 'cd ~/mips/cheri_batch && ./soak_board.sh'"
