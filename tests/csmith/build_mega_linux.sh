#!/usr/bin/env bash
# build_mega_linux.sh -- combine N csmith programs into ONE static musl Linux
# binary (n64 mips3, matches the busybox initramfs). Runs as a Linux userspace
# process under vmlinux.32 -- the mapped/paging path, and (placed on a SCSI disk)
# the disk-read coherence path.
#
#   Usage:  ./build_mega_linux.sh <out> <N> [base_seed]
#   Output: <out> (mips ELF) + <out>.golden  (TEST<i> seed=<s> ref=<crc> per test)
#
# Same combine trick as build_mega.sh: each main -> csmith_<i> (globals static ->
# no collision); a driver chains them, printing per-test checksums. Uses real libc
# printf (no bare-metal support). NONE-golden tests skipped (they hang).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CC=/home/dsheffie/mips-initramfs/mips3-tc/bin/mips64-linux-musl-gcc
REFCC=mips-linux-gnu-gcc          # o32 reference for the QEMU golden
CSMITH_INC=/usr/include/csmith
CSMITH_FLAGS="--no-float --no-builtins --concise --max-block-depth 2 --max-funcs 4"

OUT=${1:?usage: build_mega_linux.sh <out> <N> [base_seed]}
N=${2:?usage: build_mega_linux.sh <out> <N> [base_seed]}
BASE=${3:-1}

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
  # QEMU golden (checksum is over fixed-width global values -> ABI-independent).
  REFBIN="$(mktemp)"; REF=""
  if $REFCC -O1 -static -I"$CSMITH_INC" -w "$C" -lm -o "$REFBIN" 2>/dev/null; then
    REF=$(timeout 60 qemu-mips-static "$REFBIN" 2>/dev/null | grep '^checksum' | grep -oiE '[0-9a-f]+$')
  fi
  rm -f "$REFBIN"
  if [ -z "$REF" ]; then
    echo "  seed $seed: no QEMU checksum (hangs), skip"; i=$((i + 1)); continue
  fi
  if $CC -O1 -I"$CSMITH_INC" -w -Dmain=csmith_$i -c "$C" -o "$WORK/p$i.o" 2>/dev/null; then
    OBJS="$OBJS $WORK/p$i.o"
    CALLS="$CALLS $i"
    echo "extern int csmith_$i(int, char **);" >> "$DECLS"
    echo "TEST$i seed=$seed ref=$REF" >> "$OUT.golden"
    echo "  TEST$i seed=$seed ref=$REF"
  else
    echo "  seed $seed: musl compile failed, skip"
  fi
  i=$((i + 1))
done

DRIVER="$WORK/driver.c"
{
  echo '#include <stdio.h>'
  cat "$DECLS"
  echo 'int main(void){ char *av[2]; av[0]="m"; av[1]=0;'
  echo '  printf("MEGA START\n"); fflush(stdout);'
  for i in $CALLS; do
    echo "  printf(\"TEST$i\\n\"); fflush(stdout); csmith_$i(1, av); fflush(stdout);"
  done
  echo '  printf("MEGA DONE\n"); return 0; }'
} > "$DRIVER"
$CC -O1 -I"$CSMITH_INC" -w -c "$DRIVER" -o "$WORK/driver.o"

$CC -static "$WORK/driver.o" $OBJS -lm -o "$OUT" \
  || { echo "LINK FAILED"; exit 1; }

echo "wrote $OUT ($(echo $CALLS | wc -w) tests); goldens in $OUT.golden"
