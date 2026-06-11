#!/bin/bash
# run_parallel.sh -- parallel random-instruction co-sim sweep across all cores.
#
#   ./run_parallel.sh [start_seed] [count] [jobs]
#       start_seed  first seed            (default 1)
#       count       number of seeds       (default 1000)
#       jobs        parallel jobs         (default = nproc)
#
# Each seed: gen .S -> assemble+link (shared crt0.o) -> ooo_core -c 1 co-sim.
# A PASS reaches DONE with no register/PC divergence; failures are listed.
set -u
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
SIM="$ROOT/ooo_core"
GEN="$(pwd)/gen_mips_test.py"
COMMON="$(pwd)/../common"
CRT0="$COMMON/crt0.o"
CC=mips-linux-gnu-gcc
LD=mips-linux-gnu-ld
CFLAGS="-march=mips3 -mabi=32 -EB -mno-abicalls -fno-pic -G 0 -O1 -nostdlib -nostartfiles -I$COMMON"
LDFLAGS="-T $COMMON/link.ld -nostdlib -G 0 -static"

START=${1:-1}; COUNT=${2:-1000}; JOBS=${3:-$(nproc)}
$CC $CFLAGS -c "$COMMON/crt0.S" -o "$CRT0" 2>/dev/null   # shared startup, built once
WORK=$(mktemp -d)
export WORK SIM GEN CC LD CFLAGS LDFLAGS CRT0

run_one() {
  local s=$1
  local n=$(( 200 + (s * 41) % 800 ))
  local p="$WORK/s$s"
  python3 "$GEN" --seed "$s" --n "$n" --out "$p" >/dev/null 2>&1 || { echo "GENERR $s"  >"$WORK/r$s"; return; }
  if $CC $CFLAGS -c "$p.S" -o "$p.o" 2>/dev/null && $LD $LDFLAGS "$CRT0" "$p.o" -o "$p.elf" 2>/dev/null; then :; else
    echo "BUILDERR $s" >"$WORK/r$s"; rm -f "$p".*; return; fi
  local out
  out=$(timeout 90 "$SIM" -f "$p.elf" -c 1 --maxicnt $((n*4+30000)) 2>&1)
  rm -f "$p".*
  if echo "$out" | grep -q DONE && ! echo "$out" | grep -qiE "does not match|incorrect 8001|no match"; then
    echo "PASS $s" >"$WORK/r$s"
  else
    echo "FAIL $s n=$n :: $(echo "$out" | grep -E 'does not match' | head -1 | cut -c1-80)" >"$WORK/r$s"
  fi
}
export -f run_one

echo "sweep seeds $START..$((START+COUNT-1))   jobs=$JOBS"
t0=$(date +%s)
seq "$START" $((START+COUNT-1)) | xargs -P "$JOBS" -I{} bash -c 'run_one "$1"' _ {}
t1=$(date +%s)

cat "$WORK"/r* > "$WORK/all" 2>/dev/null
p=$(grep -c '^PASS' "$WORK/all"); f=$(grep -cvE '^PASS' "$WORK/all")
echo "=================================="
echo " pass=$p  fail/err=$f  / $COUNT   (${JOBS} jobs, $((t1-t0))s)"
grep -vE '^PASS' "$WORK/all" | head -30
rm -rf "$WORK"
