#!/bin/bash
# run_cache_ops.sh -- TDD runner for the D/L2 CACHE-op matrix (test_cache_ops.S).
# Builds the ELF, runs it on the henry_tb Verilator sim, and checks the DRAM that
# each CACHE op left behind against the expected value (the non-CPU DRAM oracle).
#
# A CACHE writeback op is PROVEN only when --dump shows the pattern reached DRAM;
# a CACHE invalidate op is PROVEN only when --dump shows the pattern did NOT.
set -u

R9999=/home/dsheffie/code/r9999
SIM=/home/dsheffie/code/henry-the-wannabe-ip22-soc/sim
SRC=$R9999/tests/cache/test_cache_ops.S
ELF=$R9999/tests/cache/test_cache_ops.elf
TB=$SIM/obj_dir/henry_tb

# addr  expected      label
CASES=(
  "0x08100000 00000000 T0_no_flush(control,cached)"
  "0x08100040 22222222 T1_Hit_WB_Inval_D(0x15)"
  "0x08100080 33333333 T2_Index_WB_Inval_D(0x01)"
  "0x081000c0 00000000 T3_Hit_Inval_D(0x11,no-WB)"
  "0x08100100 55555555 T4_Hit_WB_D+L2(0x15+0x17)"
  "0x08100140 66666666 T5_Hit_WB_D(0x19)"
)

echo "== building $ELF =="
mips-linux-gnu-gcc -march=mips3 -mabi=32 -EB -mno-abicalls -fno-pic -nostdlib \
  -nostartfiles -Wl,-Ttext=0x80010000 -Wl,-e,_start -x assembler-with-cpp \
  "$SRC" -o "$ELF" || { echo "BUILD FAIL"; exit 1; }

[ -x "$TB" ] || { echo "missing $TB -- run 'make build' in $SIM first"; exit 1; }

DUMPS=""
for c in "${CASES[@]}"; do DUMPS="$DUMPS --dump ${c%% *}"; done

OUT=$("$TB" --kernel "$ELF" --start-pc 0x80010000 --maxcyc 300000 $DUMPS 2>&1)

pass=0; fail=0
for c in "${CASES[@]}"; do
  addr=$(echo "$c" | awk '{print $1}')
  exp=$(echo  "$c" | awk '{print $2}')
  lbl=$(echo  "$c" | awk '{print $3}')
  # --dump line: "[dump] PA 0x08100040: 22222222 00000000 ..." -- first word is the addr.
  got=$(echo "$OUT" | grep -i "PA $addr:" | head -1 | awk '{print $4}')
  if [ "$got" = "$exp" ]; then
    printf "  PASS  %-32s %s -> %s\n" "$lbl" "$addr" "$got"
    pass=$((pass+1))
  else
    printf "  FAIL  %-32s %s exp %s got %s\n" "$lbl" "$addr" "$exp" "${got:-<none>}"
    fail=$((fail+1))
  fi
done

echo "== cache-op matrix: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
