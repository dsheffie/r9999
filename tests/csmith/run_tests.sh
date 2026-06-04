#!/usr/bin/env bash
# run_tests.sh  --  csmith differential testing for r9999 MIPS simulator
#
# Infinite-loop detection uses cbmc (formal bounded model checking) instead of
# wasting QEMU's timeout budget.  When cbmc finds an unbounded loop it also
# reports the exact function, line, and loop number, which is useful for
# understanding what the simulator might encounter.
#
# Flow per test:
#   1. Generate with csmith
#   2. cbmc --unwind $CBMC_K  (< 1 s for most programs)
#        FAIL with user-code violation  → SKIP, print loop location
#        PASS                           → continue
#   3. Compile MIPS Linux, run under qemu-mips-static  → reference checksum
#        Timeout (cbmc false-positive)  → SKIP
#   4. Compile bare-metal, run on r9999 simulator      → test checksum
#   5. Compare checksums; save mismatches as fail_N.c
#
# Usage:
#   ./run_tests.sh [num_tests [cbmc_k [maxicnt]]]
#   ./run_tests.sh 1 20 10000000 fail_5.c    # re-test a saved failure

set -uo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELLO="$REPO_ROOT/hello"
SIM="$REPO_ROOT/ooo_core"
CSMITH_INC="/usr/include/csmith"

CC=mips-linux-gnu-gcc
NPROC=$(nproc)

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------
N=${1:-100}
CBMC_K=${2:-20}         # unwind bound for user-generated loops
MAXICNT=${3:-10000000}
SPECIFIC=${4:-}

# Library loop bounds: fixed, exact counts derived from csmith.h source.
#   crc32_gentab.1  outer i-loop:  for (i=0; i<256; i++)   needs 257
#   crc32_gentab.0  inner j-loop:  for (j=8; j>0;  j--)   needs   9
#   strcmp.0        char loop:     conservative bound of  200
CBMC_LIBLOOPS="crc32_gentab.0:9,crc32_gentab.1:257,strcmp.0:200"

TIMEOUT_REF=60    # wall-clock limit for the qemu-mips-static reference run
TIMEOUT_SIM=30    # simulator wall-clock limit

QEMU=qemu-mips-static

CSMITH_FLAGS="--no-float --no-builtins --concise --max-block-depth 3"

BM_FLAGS="-mxgot -ffreestanding -O1 -mips3 -mno-branch-likely"
BM_DEFS="-D printf=printf_ -D _FORTIFY_SOURCE=0 -D WRAP_VOLATILES=1"
# MIPS Linux reference: same ISA and ABI as the bare-metal binary, so
# architecture-specific behavior (bit-field layout, integer types) matches.
# Compiled as a static MIPS binary and run under qemu-mips-static.
REF_FLAGS="-O1 -static"

# ---------------------------------------------------------------------------
# Build shared objects (once, before parallel phase)
# ---------------------------------------------------------------------------
SHARED=$(mktemp -d)
trap 'rm -rf "$SHARED"' EXIT

echo "Building common bare-metal objects  (parallelism: ${NPROC} jobs)..."

$CC $BM_FLAGS \
    -c "$SCRIPT_DIR/start_csmith.S"                       -o "$SHARED/start.o"
$CC $BM_FLAGS -I"$HELLO" \
    -c "$HELLO/printf.c"                                   -o "$SHARED/printf.o"
$CC $BM_FLAGS \
    -c "$HELLO/arith64.c"                                  -o "$SHARED/arith64.o"
$CC $BM_FLAGS $BM_DEFS -I"$CSMITH_INC" \
    -c /usr/include/csmith/volatile_runtime.c              -o "$SHARED/volatile_runtime.o"
$CC $BM_FLAGS \
    -c "$SCRIPT_DIR/baremetal_support.c"                   -o "$SHARED/support.o"

SUPPORT_OBJS="$SHARED/start.o $SHARED/printf.o $SHARED/arith64.o \
    $SHARED/volatile_runtime.o $SHARED/support.o"

echo "Done."
echo ""

# ---------------------------------------------------------------------------
# Export everything the worker subshells need
# ---------------------------------------------------------------------------
export SHARED REPO_ROOT HELLO SIM CC CSMITH_INC QEMU
export BM_FLAGS BM_DEFS REF_FLAGS SUPPORT_OBJS CSMITH_FLAGS
export TIMEOUT_REF TIMEOUT_SIM MAXICNT
export CBMC_K CBMC_LIBLOOPS
export SPECIFIC

# ---------------------------------------------------------------------------
# Worker: one test per invocation; writes PASS / SKIP / FAIL to $SHARED/r$id
# ---------------------------------------------------------------------------
worker() {
    local id=$1
    local work="$SHARED/t$id"
    mkdir -p "$work"

    local src ref_bin elf

    if [ -n "${SPECIFIC:-}" ]; then
        src="$SPECIFIC"
    else
        src="$work/test.c"
        csmith $CSMITH_FLAGS > "$src" 2>/dev/null \
            || { echo SKIP > "$SHARED/r$id"; return; }
    fi

    ref_bin="$work/ref"
    elf="$work/test.elf"

    # ---- Step 1: cbmc infinite-loop gate ---------------------------------
    #
    # Run cbmc with the per-library exact bounds so that known-finite library
    # loops (crc32_gentab, strcmp) are handled correctly.  Any remaining
    # unwinding failure must be in user-generated code.
    local cbmc_out
    cbmc_out=$(timeout 30 cbmc \
        --unwind "$CBMC_K" \
        --unwinding-assertions \
        --unwindset "$CBMC_LIBLOOPS" \
        -I"$CSMITH_INC" "$src" 2>&1) || true

    local cbmc_verdict
    cbmc_verdict=$(printf '%s' "$cbmc_out" | grep "^VERIFICATION" | head -1)

    if printf '%s' "$cbmc_verdict" | grep -q FAILED; then
        # Extract the user-code violation (ignore library loops)
        local where
        where=$(printf '%s' "$cbmc_out" \
            | grep "unwinding assertion.*FAILURE" \
            | grep -v "crc32_gentab\|strcmp" \
            | head -1 \
            | sed 's/.*\[\(.*\)\].*/\1/')   # extract [func.unwind.N]

        echo SKIP > "$SHARED/r$id"

        # Print diagnostic (GNU parallel --line-buffer keeps lines intact)
        if [ -n "$where" ]; then
            local lineno
            lineno=$(printf '%s' "$cbmc_out" \
                | grep "unwinding assertion.*FAILURE" \
                | grep -v "crc32_gentab\|strcmp" \
                | head -1 \
                | grep -o "line [0-9]*" | head -1)
            printf '[%d] SKIP  cbmc: unbounded loop  %s  %s\n' \
                "$id" "$where" "$lineno"
        else
            # Violation only in library code with the given K — rare; treat as skip
            printf '[%d] SKIP  cbmc: only library loop exceeded k=%s\n' "$id" "$CBMC_K"
        fi
        return
    fi

    # ---- Step 2: Reference output (MIPS Linux under qemu-mips-static) ------
    $CC $REF_FLAGS -I"$CSMITH_INC" -w "$src" -lm -o "$ref_bin" 2>/dev/null \
        || { echo SKIP > "$SHARED/r$id"; return; }

    local ref_out
    ref_out=$(timeout "$TIMEOUT_REF" "$QEMU" "$ref_bin" 2>/dev/null) || {
        # cbmc said finite but reference timed out: rare false-positive, skip
        printf '[%d] SKIP  cbmc k=%s false-positive (ref timeout)\n' "$id" "$CBMC_K"
        echo SKIP > "$SHARED/r$id"; return
    }
    ref_out=$(printf '%s' "$ref_out" | grep "^checksum")
    [ -z "$ref_out" ] && { echo SKIP > "$SHARED/r$id"; return; }

    # ---- Step 3: Bare-metal MIPS on r9999 simulator ----------------------
    $CC $BM_FLAGS $BM_DEFS -I"$CSMITH_INC" -I"$HELLO" \
        -w -nostdlib "$src" $SUPPORT_OBJS \
        -T "$HELLO/baremetal.ld" -o "$elf" 2>/dev/null \
        || { echo SKIP > "$SHARED/r$id"; return; }

    local sim_raw sim_out
    sim_raw=$(timeout "$TIMEOUT_SIM" \
        "$SIM" --file "$elf" --maxicnt "$MAXICNT" \
        2>&1) || true
    sim_out=$(printf '%s' "$sim_raw" | grep "^checksum")

    # ---- Step 4: Compare -------------------------------------------------
    if [ "$ref_out" = "$sim_out" ]; then
        echo PASS > "$SHARED/r$id"
    else
        echo FAIL > "$SHARED/r$id"
        printf '[%d] MISMATCH\n  ref: %s\n  sim: %s\n  saved: fail_%d.c\n' \
            "$id" "$ref_out" "${sim_out:-<no checksum output>}" "$id"
        printf '%s\n' "$sim_raw" | grep -v "^total_\|^simulation\|^insns\|^ *$" | head -30 | \
            sed "s/^/  [checker] /"
        cp "$src" "$REPO_ROOT/fail_${id}.c"
        cp "$elf"  "$REPO_ROOT/fail_${id}.elf"
    fi
}
export -f worker

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
if [ -n "${SPECIFIC:-}" ]; then
    echo "Re-testing: $SPECIFIC  (cbmc k=$CBMC_K)"
    worker 0
    case "$(cat "$SHARED/r0" 2>/dev/null)" in
        PASS) echo "PASS" ;;
        FAIL) echo "FAIL"; exit 1 ;;
        *)    echo "SKIP" ;;
    esac
    exit 0
fi

echo "Running $N tests on $NPROC parallel workers"
echo "  cbmc k=$CBMC_K   maxicnt=$MAXICNT   ref_timeout=${TIMEOUT_REF}s ($QEMU)   sim_timeout=${TIMEOUT_SIM}s"
echo "  csmith: $CSMITH_FLAGS"
echo ""

if [ -t 2 ]; then
    PARALLEL_PROGRESS="--bar"
else
    PARALLEL_PROGRESS=""
fi

seq 1 "$N" \
    | parallel --jobs "$NPROC" --line-buffer $PARALLEL_PROGRESS worker

# ---------------------------------------------------------------------------
# Tally results in test-ID order
# ---------------------------------------------------------------------------
PASS=0; FAIL=0; SKIP=0
FAILED_IDS=()
for i in $(seq 1 "$N"); do
    case "$(cat "$SHARED/r$i" 2>/dev/null || echo SKIP)" in
        PASS) PASS=$((PASS+1)) ;;
        FAIL) FAIL=$((FAIL+1)); FAILED_IDS+=("$i") ;;
        *)    SKIP=$((SKIP+1)) ;;
    esac
done

echo ""
echo "============================================"
printf '  pass=%-5d  skip=%-5d  fail=%-5d / %d\n' "$PASS" "$SKIP" "$FAIL" "$N"
echo "============================================"

if [ "${#FAILED_IDS[@]}" -gt 0 ]; then
    echo ""
    echo "Failed tests (rerun commands):"
    for i in "${FAILED_IDS[@]}"; do
        f="$REPO_ROOT/fail_${i}.c"
        if [ -f "$f" ]; then
            printf '  [%d]  %s\n' "$i" "$f"
            printf '       ./run_tests.sh 1 %s %s %s\n' "$CBMC_K" "$MAXICNT" "$f"
        else
            printf '  [%d]  source not saved\n' "$i"
        fi
    done
fi

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
