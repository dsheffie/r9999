#!/usr/bin/env bash
# build_mega.sh -- combine N csmith tests into ONE FSBL bare-metal binary.
#
#   Usage:  ./build_mega.sh <out.elf> <N> [base_seed]
#   Output: <out.elf> + <out.elf>.golden  (one "TEST<i> seed=<s> ref=<crc>" per test)
#
# Each csmith program's globals/functions/crc32_context are `static` (per-TU), so
# combining is trivial: rename each main -> csmith_<i> and a generated driver calls
# them in sequence.  platform_main_end() only PRINTS "checksum = ..." (no halt), so
# each test prints its own checksum; the driver returns -> start_csmith_fsbl.S does
# the single MAGIC HALT.  One boot exercises N programs -- amplifies the odds of
# catching the (random) mapped-execution corruption, and each per-test checksum vs
# the QEMU golden localizes which test diverged.
#
# Run on the FPGA exactly like build_one's output:
#   mips-axi -f <out.elf> --sgi true --arcs henry_arcs.bin --start-pc 0xbfc00000
# (no `set -e`: a test whose QEMU run yields no checksum is expected and skipped.)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELLO="$REPO/hello"
CC=mips-linux-gnu-gcc
CSMITH_INC=/usr/include/csmith
BM_FLAGS="-mxgot -ffreestanding -O1 -mips3 -mno-branch-likely -mabi=n32 -mno-abicalls"
BM_DEFS="-D printf=printf_ -D _FORTIFY_SOURCE=0 -D WRAP_VOLATILES=1"
CSMITH_FLAGS="--no-float --no-builtins --concise --max-block-depth 2 --max-funcs 4"

OUT=${1:?usage: build_mega.sh <out.elf> <N> [base_seed]}
N=${2:?usage: build_mega.sh <out.elf> <N> [base_seed]}
BASE=${3:-1}

# Test-independent support objects (shared with build_one via .support_fsbl).
SUPP="$SCRIPT_DIR/.support_fsbl"
if [ ! -f "$SUPP/.ok" ]; then
  mkdir -p "$SUPP"
  $CC $BM_FLAGS               -c "$SCRIPT_DIR/start_csmith_fsbl.S"   -o "$SUPP/start.o"
  $CC $BM_FLAGS -I"$HELLO"    -c "$HELLO/printf.c"                   -o "$SUPP/printf.o"
  $CC $BM_FLAGS               -c "$HELLO/arith64.c"                  -o "$SUPP/arith64.o"
  $CC $BM_FLAGS $BM_DEFS -I"$CSMITH_INC" -c "$CSMITH_INC/volatile_runtime.c" -o "$SUPP/vr.o"
  $CC $BM_FLAGS               -c "$SCRIPT_DIR/baremetal_support.c"   -o "$SUPP/support.o"
  touch "$SUPP/.ok"
fi
SUPP_OBJS="$SUPP/start.o $SUPP/printf.o $SUPP/arith64.o $SUPP/vr.o $SUPP/support.o"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OBJS=""
CALLS=""
DECLS="$WORK/decls.h"
: > "$DECLS"
: > "$OUT.golden"

i=0
while [ "$i" -lt "$N" ]; do
  seed=$((BASE + i))
  C="$WORK/p$i.c"
  if ! csmith $CSMITH_FLAGS --seed "$seed" > "$C" 2>/dev/null; then
    echo "  seed $seed: csmith failed, skip"; i=$((i + 1)); continue
  fi
  # QEMU reference checksum (O32 build; sizes match N32 so checksums agree).
  REFBIN="$(mktemp)"; REF=""
  if $CC -O1 -static -I"$CSMITH_INC" -w "$C" -lm -o "$REFBIN" 2>/dev/null; then
    REF=$(timeout 60 qemu-mips-static "$REFBIN" 2>/dev/null | grep '^checksum' | grep -oiE '[0-9a-f]+$')
  fi
  rm -f "$REFBIN"
  # No QEMU checksum => the program hangs / is uncomputable. Such a test would hang
  # the mega binary and block every test after it, so skip it entirely.
  if [ -z "$REF" ]; then
    echo "  seed $seed: no QEMU checksum (hangs), skip"; i=$((i + 1)); continue
  fi
  # bare-metal object, main renamed csmith_<i>
  if $CC $BM_FLAGS $BM_DEFS -I"$CSMITH_INC" -I"$HELLO" -w -Dmain=csmith_$i -c "$C" -o "$WORK/p$i.o" 2>/dev/null; then
    OBJS="$OBJS $WORK/p$i.o"
    CALLS="$CALLS $i"
    echo "extern int csmith_$i(int, char **);" >> "$DECLS"
    echo "TEST$i seed=$seed ref=${REF:-NONE}" >> "$OUT.golden"
    echo "  TEST$i seed=$seed ref=${REF:-NONE}"
  else
    echo "  seed $seed: bare-metal compile failed, skip"
  fi
  i=$((i + 1))
done

# generated driver: call each surviving test, framed by a "TEST<i>" marker line
DRIVER="$WORK/driver.c"
{
  echo 'int printf_(const char *, ...);'
  cat "$DECLS"
  echo 'int main(void){ char *av[2]; av[0]="m"; av[1]=0;'
  echo '  printf_("MEGA START\n");'
  for i in $CALLS; do
    echo "  printf_(\"TEST$i\\n\"); csmith_$i(1, av);"
  done
  echo '  printf_("MEGA DONE\n"); return 0; }'
} > "$DRIVER"
$CC $BM_FLAGS $BM_DEFS -I"$HELLO" -w -c "$DRIVER" -o "$WORK/driver.o"

$CC $BM_FLAGS $BM_DEFS -w -nostdlib "$WORK/driver.o" $OBJS $SUPP_OBJS \
    -T "$SCRIPT_DIR/csmith_fsbl.ld" -Wl,-melf32btsmipn32 -o "$OUT" \
    || { echo "LINK FAILED"; exit 1; }

echo "wrote $OUT ($(echo $CALLS | wc -w) tests); goldens in $OUT.golden"
