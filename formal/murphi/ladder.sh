#!/bin/bash
# ladder.sh -- rerun the fix ladder on the current model; one line per step
cd "$(dirname "$0")"
steps=( "main_0_rtl|"
        "main_1_markmiss|FIX_MARK_MISS=1"
        "main_2_probe|FIX_MARK_MISS=1 FIX_PROBE=1"
        "main_3_drain|FIX_MARK_MISS=1 FIX_PROBE=1 FIX_FLUSH_DRAIN=1"
        "main_4_ebp2|FIX_MARK_MISS=1 FIX_PROBE=1 FIX_FLUSH_DRAIN=1 FIX_EB_P2=1"
        "main_5_pmh|FIX_MARK_MISS=1 FIX_PROBE=1 FIX_FLUSH_DRAIN=1 FIX_EB_P2=1 PMH_EVICT_RMW=1" )
for st in "${steps[@]}"; do
  n=${st%%|*}; k=${st#*|}
  ./run.sh $n $k > /dev/null 2>&1
  L=build/$n/run.log
  what=$(grep -m1 -oE "(Assertion failed|Error): .*|Invariant \".*\" failed|No error found|Too many active states|Closed hash table full" $L | head -1)
  steps_n=$(grep -c "^Rule" $L)
  printf "%-18s %-70s %s\n" "$n" "${what}" "$( [ $steps_n -gt 0 ] && echo "($steps_n steps)" )"
done
