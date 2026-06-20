#!/usr/bin/env bash
# build_one.sh -- generate ONE csmith test and build the FPGA-runnable bare-metal
# ELF (FSBL/kseg0 flow), plus its QEMU reference checksum.
#
#   Usage:  ./build_one.sh <out.elf> [seed]
#   Output: writes <out.elf> + <out.elf>.c ; prints  REF=<checksum-hex>
#           (empty REF => csmith/qemu produced no checksum: caller should skip)
#
# The ELF uses the FSBL/kseg0 layout (start_csmith_fsbl.S + csmith_fsbl.ld): the
# henry_arcs FSBL boots it like the kernel, so it runs on the FPGA under
#   mips-axi -f <elf> --sgi true --arcs henry_arcs.bin --start-pc 0xbfc00000
# (the older mapped layout hung at "state 1" on the Henry SoC -- see
# project_henry_baremetal_runtime_broken).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELLO="$REPO/hello"
CC=mips-linux-gnu-gcc
CSMITH_INC=/usr/include/csmith
BM_FLAGS="-mxgot -ffreestanding -O1 -mips3 -mno-branch-likely -mabi=n32 -mno-abicalls"
BM_DEFS="-D printf=printf_ -D _FORTIFY_SOURCE=0 -D WRAP_VOLATILES=1"
CSMITH_FLAGS="--no-float --no-builtins --concise --max-block-depth 2 --max-funcs 4"

OUT=${1:?usage: build_one.sh <out.elf> [seed]}
[ -n "${2:-}" ] && CSMITH_FLAGS="$CSMITH_FLAGS --seed $2"

# Cache the test-independent support objects (built once).  Separate cache dir
# from the mapped flow's .support so the two never share a stale start.o.
SUPP="$SCRIPT_DIR/.support_fsbl"
if [ ! -f "$SUPP/.ok" ]; then
  mkdir -p "$SUPP"
  $CC $BM_FLAGS               -c "$SCRIPT_DIR/start_csmith_fsbl.S"   -o "$SUPP/start.o"   || exit 1
  $CC $BM_FLAGS -I"$HELLO"    -c "$HELLO/printf.c"                   -o "$SUPP/printf.o"  || exit 1
  $CC $BM_FLAGS               -c "$HELLO/arith64.c"                  -o "$SUPP/arith64.o" || exit 1
  $CC $BM_FLAGS $BM_DEFS -I"$CSMITH_INC" -c /usr/include/csmith/volatile_runtime.c -o "$SUPP/vr.o" || exit 1
  $CC $BM_FLAGS               -c "$SCRIPT_DIR/baremetal_support.c"   -o "$SUPP/support.o" || exit 1
  touch "$SUPP/.ok"
fi
SUPP_OBJS="$SUPP/start.o $SUPP/printf.o $SUPP/arith64.o $SUPP/vr.o $SUPP/support.o"

C="$OUT.c"
csmith $CSMITH_FLAGS > "$C" 2>/dev/null || { echo "REF="; exit 0; }

# QEMU reference (O32 Linux binary; sizes match N32 so checksums agree).
REFBIN="$(mktemp)"
if $CC -O1 -static -I"$CSMITH_INC" -w "$C" -lm -o "$REFBIN" 2>/dev/null; then
  REF=$(timeout 60 qemu-mips-static "$REFBIN" 2>/dev/null | grep '^checksum' | grep -oiE '[0-9a-f]+$')
fi
rm -f "$REFBIN"

# Bare-metal ELF, FSBL/kseg0 layout (FPGA-runnable via the henry_arcs FSBL).
$CC $BM_FLAGS $BM_DEFS -I"$CSMITH_INC" -I"$HELLO" -w -nostdlib "$C" $SUPP_OBJS \
    -T "$SCRIPT_DIR/csmith_fsbl.ld" -Wl,-melf32btsmipn32 -o "$OUT" 2>/dev/null \
    || { echo "REF="; exit 0; }

echo "REF=${REF:-}"
