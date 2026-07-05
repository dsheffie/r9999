#!/usr/bin/env bash
# build_mega_pt.sh -- like build_mega.sh but the "real page table" MAPPED flow
# (start_csmith_pt.S + pt_support.c + baremetal_pt.ld): empty TLB + software
# refill, so the N csmith programs run through actual TLB translation. This is the
# vehicle for the FPGA mapped-execution corruption (bare-metal/unmapped is correct;
# the bug only shows under mapped execution -- project_fpga_mapped_corruption).
#
#   Usage:  ./build_mega_pt.sh <out.elf> <N> [base_seed]
#   Output: <out.elf> + <out.elf>.golden  (one "TEST<i> seed=<s> ref=<crc>" per test)
#
# Same combine trick as build_mega.sh: each csmith main -> csmith_<i> (globals are
# static, no collisions); a generated driver chains them; NONE-golden tests skipped
# (they hang and would block the rest). One boot exercises N mapped programs.
#
#   mips-axi -f <out.elf> --sgi true --arcs henry_arcs.bin --start-pc 0xbfc00000
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELLO="$REPO/hello"
CC=mips-linux-gnu-gcc
CSMITH_INC=/usr/include/csmith
BM_FLAGS="-mxgot -ffreestanding -O1 -mips3 -mno-branch-likely -mabi=n32 -mno-abicalls"
BM_DEFS="-D printf=printf_ -D _FORTIFY_SOURCE=0 -D WRAP_VOLATILES=1"
CSMITH_FLAGS="--no-float --no-builtins --concise --max-block-depth 2 --max-funcs 4"

OUT=${1:?usage: build_mega_pt.sh <out.elf> <N> [base_seed]}
N=${2:?usage: build_mega_pt.sh <out.elf> <N> [base_seed]}
BASE=${3:-1}

# Mapped (page-table) support objects.
SUPP="$SCRIPT_DIR/.support_pt"
if [ ! -f "$SUPP/.ok" ]; then
  mkdir -p "$SUPP"
  $CC $BM_FLAGS               -c "$SCRIPT_DIR/start_csmith_pt.S"      -o "$SUPP/start.o"   || exit 1
  $CC $BM_FLAGS               -c "$SCRIPT_DIR/pt_support.c"           -o "$SUPP/pt.o"      || exit 1
  $CC $BM_FLAGS -I"$HELLO"    -c "$HELLO/printf.c"                    -o "$SUPP/printf.o"  || exit 1
  $CC $BM_FLAGS               -c "$HELLO/arith64.c"                   -o "$SUPP/arith64.o" || exit 1
  $CC $BM_FLAGS $BM_DEFS -I"$CSMITH_INC" -c "$CSMITH_INC/volatile_runtime.c" -o "$SUPP/vr.o" || exit 1
  $CC $BM_FLAGS               -c "$SCRIPT_DIR/baremetal_support.c"    -o "$SUPP/support.o" || exit 1
  touch "$SUPP/.ok"
fi
SUPP_OBJS="$SUPP/start.o $SUPP/pt.o $SUPP/printf.o $SUPP/arith64.o $SUPP/vr.o $SUPP/support.o"

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
  REFBIN="$(mktemp)"; REF=""
  if $CC -O1 -static -I"$CSMITH_INC" -w "$C" -lm -o "$REFBIN" 2>/dev/null; then
    REF=$(timeout 60 qemu-mips-static "$REFBIN" 2>/dev/null | grep '^checksum' | grep -oiE '[0-9a-f]+$')
  fi
  rm -f "$REFBIN"
  if [ -z "$REF" ]; then
    echo "  seed $seed: no QEMU checksum (hangs), skip"; i=$((i + 1)); continue
  fi
  if $CC $BM_FLAGS $BM_DEFS -I"$CSMITH_INC" -I"$HELLO" -w -Dmain=csmith_$i -c "$C" -o "$WORK/p$i.o" 2>/dev/null; then
    OBJS="$OBJS $WORK/p$i.o"
    CALLS="$CALLS $i"
    echo "extern int csmith_$i(int, char **);" >> "$DECLS"
    echo "TEST$i seed=$seed ref=$REF" >> "$OUT.golden"
    echo "  TEST$i seed=$seed ref=$REF"
  else
    echo "  seed $seed: bare-metal compile failed, skip"
  fi
  i=$((i + 1))
done

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
    -T "$HELLO/baremetal_pt.ld" -Wl,-melf32btsmipn32 -o "$OUT" \
    || { echo "LINK FAILED"; exit 1; }

echo "wrote $OUT ($(echo $CALLS | wc -w) mapped tests); goldens in $OUT.golden"
