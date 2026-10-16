# Murphi models of the r9999 cache hierarchy

These are the protocol proofs behind `INCLUSIVE_L2_PROTOCOL.md` and the DMA / page-walk
work. Each model is explicit-state checked with CMurphi 5.4.9 (not vendored: the runners
use `$CMURPHI`, default `~/code/murphi/cmurphi`). Rumur reads the same files.

| Model | What it covers |
|---|---|
| `r9999_main.m` | the hierarchy at main `3b78e9b` (L1D, L1I, non-inclusive L2); `r9999_main_l1_extract.md` is the RTL extract it was built from |
| `r9999_incl.m` | inclusive L2 with back-invalidate probes, presence bits and DMA snoop. **Generated** from `r9999_main.m` by `gen/make_incl.py` (+ `gen/{rsp_inline,tagonly,presence,dmasnoop}.py`): edit the generators, then `python3 gen/make_incl.py` in this directory |
| `r9999_va.m` | VA-indexed L1D with L2 alias tracking (`pd`/`pidx`). Push (the RTL, stage C2b) is `ALIAS_PULL=0`; the file default is pull |
| `r9999_nb.m` | the probe protocol with a non-blocking L2 |
| `r9999_dma.m`, `r9999_pagewalk.m` | DMA coherence options; the injected page-walk (XPG) order |
| `r9999_caches.m`, `rv64core_*.m` | earlier r9999 model; rv64core's caches, credits and DMA |

## Running

`./run_<model>.sh NAME KNOB=VAL ...` copies the model to `$MURPHI_BUILD/NAME` (default
`./build`, gitignored), sets the knobs, compiles and checks it, and prints the verdict.
`BIG=1 MEM=<MB>` switches to bit-state + hash compaction for the large configurations.

Each model lists its knobs and negative controls in its header. Every negative control
(`BUG_*`) must FAIL; a passing negative control means the check is blind. Example:

    ./run_va.sh push      ALIAS_PULL=0                        # the C2b protocol
    ./run_va.sh blocked   ALIAS_PULL=0 BUG_PROBE_BLOCKED=1    # must deadlock

`ladder.sh` replays the fix ladder on `rv64core_caches.m`; `sweep_dma.sh` runs every knob
combination of `r9999_dma.m` in parallel.
