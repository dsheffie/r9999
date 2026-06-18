#!/usr/bin/env bash
# build_one_pt.sh -- like build_one.sh but builds the "real page table" variant
# (start_csmith_pt.S + pt_support.c + baremetal_pt.ld): empty TLB + software
# refill handler + scrambled VA->PA map. Prints REF=<qemu checksum>.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELLO="$REPO/hello"
CC=mips-linux-gnu-gcc
CSMITH_INC=/usr/include/csmith
BM_FLAGS="-mxgot -ffreestanding -O1 -mips3 -mno-branch-likely -mabi=n32 -mno-abicalls"
BM_DEFS="-D printf=printf_ -D _FORTIFY_SOURCE=0 -D WRAP_VOLATILES=1"
CSMITH_FLAGS="--no-float --no-builtins --concise --max-block-depth 2 --max-funcs 4"

OUT=${1:?usage: build_one_pt.sh <out.elf> [seed]}
[ -n "${2:-}" ] && CSMITH_FLAGS="$CSMITH_FLAGS --seed $2"

SUPP="$SCRIPT_DIR/.support_pt"
mkdir -p "$SUPP"
$CC $BM_FLAGS               -c "$SCRIPT_DIR/start_csmith_pt.S"  -o "$SUPP/start.o"   || exit 1
$CC $BM_FLAGS               -c "$SCRIPT_DIR/pt_support.c"       -o "$SUPP/pt.o"      || exit 1
$CC $BM_FLAGS -I"$HELLO"    -c "$HELLO/printf.c"               -o "$SUPP/printf.o"  || exit 1
$CC $BM_FLAGS               -c "$HELLO/arith64.c"              -o "$SUPP/arith64.o" || exit 1
$CC $BM_FLAGS $BM_DEFS -I"$CSMITH_INC" -c /usr/include/csmith/volatile_runtime.c -o "$SUPP/vr.o" || exit 1
$CC $BM_FLAGS               -c "$SCRIPT_DIR/baremetal_support.c" -o "$SUPP/support.o" || exit 1
SUPP_OBJS="$SUPP/start.o $SUPP/pt.o $SUPP/printf.o $SUPP/arith64.o $SUPP/vr.o $SUPP/support.o"

C="$OUT.c"
csmith $CSMITH_FLAGS > "$C" 2>/dev/null || { echo "REF="; exit 0; }

REFBIN="$(mktemp)"
if $CC -O1 -static -I"$CSMITH_INC" -w "$C" -lm -o "$REFBIN" 2>/dev/null; then
  REF=$(timeout 60 qemu-mips-static "$REFBIN" 2>/dev/null | grep '^checksum' | grep -oiE '[0-9a-f]+$')
fi
rm -f "$REFBIN"

$CC $BM_FLAGS $BM_DEFS -I"$CSMITH_INC" -I"$HELLO" -w -nostdlib "$C" $SUPP_OBJS \
    -T "$HELLO/baremetal_pt.ld" -Wl,-melf32btsmipn32 -o "$OUT" 2>/dev/null \
    || { echo "REF="; exit 0; }

echo "REF=${REF:-}"
