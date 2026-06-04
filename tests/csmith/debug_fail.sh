#!/usr/bin/env bash
# debug_fail.sh -- rebuild a saved fail_*.c with print_hash_value=1 and
# run both the x86-32 reference and the r9999 bare-metal simulator so that
# each variable's individual hash contribution is printed for comparison.
#
# Usage:
#   ./debug_fail.sh <fail_N.c> [maxicnt]
#
# Output:
#   ref.out   -- x86-32 reference run with full hash trace
#   sim.out   -- simulator run with full hash trace
#   diff.out  -- first diverging line, if any

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELLO="$REPO_ROOT/hello"
SIM="$REPO_ROOT/ooo_core"
CSMITH_INC="/usr/include/csmith"

CC=mips-linux-gnu-gcc
MAXICNT=${2:-10000000}

SRC="${1:-}"
if [ -z "$SRC" ]; then
    echo "Usage: $0 <fail_N.c> [maxicnt]" >&2
    exit 1
fi
SRC="$(realpath "$SRC")"
[ -f "$SRC" ] || { echo "File not found: $SRC" >&2; exit 1; }

BM_FLAGS="-mxgot -ffreestanding -O1 -mips3 -mno-branch-likely"
BM_DEFS="-D printf=printf_ -D _FORTIFY_SOURCE=0 -D WRAP_VOLATILES=1"
REF_FLAGS="-m32 -O1"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PATCHED="$WORK/test_verbose.c"

# Force print_hash_value=1: replace the "= 0" initialiser in main().
# The line in csmith output is always exactly:
#   int print_hash_value = 0;
sed 's/int print_hash_value = 0;/int print_hash_value = 1;/' "$SRC" > "$PATCHED"

echo "Building x86-32 reference binary..."
REF_BIN="$WORK/ref"
gcc $REF_FLAGS -I"$CSMITH_INC" -w "$PATCHED" -lm -o "$REF_BIN" 2>/dev/null \
    || { echo "ERROR: reference compile failed" >&2; exit 1; }

echo "Building bare-metal MIPS objects..."
$CC $BM_FLAGS \
    -c "$SCRIPT_DIR/start_csmith.S"       -o "$WORK/start.o"
$CC $BM_FLAGS -I"$HELLO" \
    -c "$HELLO/printf.c"                  -o "$WORK/printf.o"
$CC $BM_FLAGS \
    -c "$HELLO/arith64.c"                 -o "$WORK/arith64.o"
$CC $BM_FLAGS $BM_DEFS -I"$CSMITH_INC" \
    -c /usr/include/csmith/volatile_runtime.c -o "$WORK/volatile_runtime.o"
$CC $BM_FLAGS \
    -c "$SCRIPT_DIR/baremetal_support.c"  -o "$WORK/support.o"

SUPPORT_OBJS="$WORK/start.o $WORK/printf.o $WORK/arith64.o \
    $WORK/volatile_runtime.o $WORK/support.o"

ELF="$WORK/test.elf"
$CC $BM_FLAGS $BM_DEFS -I"$CSMITH_INC" -I"$HELLO" \
    -w -nostdlib "$PATCHED" $SUPPORT_OBJS \
    -T "$HELLO/baremetal.ld" -o "$ELF" 2>/dev/null \
    || { echo "ERROR: bare-metal compile failed" >&2; exit 1; }

echo "Running reference..."
REF_OUT="$WORK/ref.out"
timeout 60 "$REF_BIN" > "$REF_OUT" 2>/dev/null \
    || { echo "WARN: reference timed out or crashed" >&2; }

echo "Running simulator..."
SIM_OUT="$WORK/sim.out"
cp $ELF .
timeout 60 "$SIM" --file "$ELF" --maxicnt "$MAXICNT" > "$SIM_OUT" 2>&1 \
    || true

# Copy outputs next to the source for inspection
BASE="${SRC%.c}"
cp "$REF_OUT" "${BASE}.ref.out"
cp "$SIM_OUT" "${BASE}.sim.out"

echo ""
echo "=== Reference checksum line ==="
grep "^checksum" "$REF_OUT" || echo "(none)"

echo ""
echo "=== Simulator checksum line ==="
grep "^checksum" "$SIM_OUT" || echo "(none)"

echo ""
echo "=== First diverging line (diff) ==="
DIFF_OUT="${BASE}.diff.out"
diff "$REF_OUT" "$SIM_OUT" > "$DIFF_OUT" 2>&1 || true
head -40 "$DIFF_OUT"

echo ""
echo "Full outputs saved:"
echo "  ref: ${BASE}.ref.out"
echo "  sim: ${BASE}.sim.out"
echo "  diff: ${BASE}.diff.out"
