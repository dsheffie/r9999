#!/bin/bash
# run_chop_remap.sh -- runner for test_chop_remap.S (CACHE Hit ops through a remapped window VA,
# the Windows NT/MIPS flush-window pattern). Builds the ELF, runs it on henry_tb, and checks DRAM
# (--dump) against the expected value of each case: the store and the Hit op after a remap must act
# on the NEW page, and the OLD page's dirty data must neither be written back early nor discarded.
set -u

R9999=/home/dsheffie/code/r9999
SIM=/home/dsheffie/code/henry-the-wannabe-ip22-soc/sim
SRC=$R9999/tests/cache/test_chop_remap.S
ELF=$R9999/tests/cache/test_chop_remap.elf
TB=$SIM/obj_dir/henry_tb

# addr  expected      label
CASES=(
  "0x08101000 00000005 progress_all_done"
  "0x08111000 22222222 R1_remap_store_and_CHWBINV_hit_new_page"
  "0x08110000 a0000000 R1_old_page_not_written_back"
  "0x08110100 33333333 R2_CHINV_after_remap_keeps_old_dirty"
  "0x08110200 c000003e R3_loop_last_A"
  "0x08111200 c000003f R3_loop_last_B"
  "0x08111300 55555555 R4_odd_half_remap_hits_new_page"
  "0x08110300 a0000300 R4_odd_half_old_page_untouched"
)

echo "== building $ELF =="
mips-linux-gnu-gcc -march=mips3 -mabi=32 -EB -mno-abicalls -fno-pic -nostdlib \
  -nostartfiles -T "$R9999/tests/common/link.ld" -I "$R9999/tests/common" -x assembler-with-cpp \
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
    printf "  PASS  %-44s %s -> %s\n" "$lbl" "$addr" "$got"
    pass=$((pass+1))
  else
    printf "  FAIL  %-44s %s exp %s got %s\n" "$lbl" "$addr" "$exp" "${got:-<none>}"
    fail=$((fail+1))
  fi
done

echo "== chop remap: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
