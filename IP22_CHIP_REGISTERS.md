# IP22 chip register reference (from SGI docs) + corrections to MAME findings

Mined 2026-06-14 from `~/code/sgi/docs/` (an SGI doc repo): `arcs_spec.pdf` (ARC 1.2 firmware spec),
`indy_docs/ip22/{mc,ioc,vdma}.pdf`. Cross-checked against this session's MAME reverse-engineering. Page
numbers cite the source PDFs. **The "⚠️ vs MAME" tags are the contradictions/corrections to what I had
written from MAME alone.**

---

## ⚠️ CONTRADICTIONS / CORRECTIONS vs my MAME experimentation (read first)

1. **MC registers are on an 8-byte stride; big-endian IRIX reads the +4 alias** (mc.pdf p.25). The MC is on
   sysad[31:0] (low 32 of the 64-bit doubleword); BE CPU → register byte address ends in **4 or c**, LE → 0 or 8.
   So:
   - **`0xbfa000c4`/`0xcc` (what IRIX reads) are the BE aliases of MEMCFG0/MEMCFG1 at table offsets `0xc0`/`0xc8`.**
   - **`0xbfa00004` is NOT a distinct register — it's the BE alias of `CPUCTRL0` (table offset 0x00).** The
     kernel's repeated uncached read there is a legit write-buffer-flush / clock-calibration read of CPUCTRL0,
     not a dedicated "bus-sync register." (My cache/clock notes called it a bus-sync read — behaviorally right,
     but it's CPUCTRL0.)
2. **MEMCFG packs banks {0,2} and {1,3}, not {0,1}** (mc.pdf p.33). MEMCFG0 = banks 0&2, MEMCFG1 = banks 1&3.
   My "two banks, high half / low half" was structurally right but the pairing was wrong.
3. **MEMCFG size field has a real SIMM-size table; my live `0x23200000` decodes to a 16 MB bank, not "size=base".**
   BASE0=0x20 (→ `0x20<<22 = 0x08000000`, ✅ matches MAME), but MSIZE0=`0b00011` = **1M×36 SIMM = 16 MB bank**,
   VLD0=1, BNK0=0 (mc.pdf p.32–33). Base and size are *separate* fields (layout in §MC below).
4. **Physical address space is up to 30 bits, not 29** (mc.pdf p.22). I measured a max of `0x1fffffff` (29 bits)
   because the test Indy had only ~16 MB RAM. The map has a **second 256 MB "High System Memory" window at
   `0x20000000–0x2fffffff`** (kseg-mapped only) → a maxed Indy needs **30-bit PA**. Low RAM window is
   `0x08000000–0x17ffffff` (256 MB max). Also the **bottom 512 KB `0x0–0x7ffff` ALIASES RAM** (for exception
   vectors 0x0/0x80) — r9999 must alias `0x0`/`0x80` to `0x08000000`/`0x08000080`.
5. **IOC2 absolute base = `0x1FBD9800`; the serial console TX reg is `0x1FBD9834`** (ioc.pdf p.13–14). My MAME
   note ("SCC at IOC offset 0x0c-0x0f") was the *word index within the IOC register file* (words 0x0c–0x0f =
   byte 0x30–0x3C) → absolute `0x1FBD9830/34/38/3C`. This CONFIRMS the `IRIX_KERNEL_GAPS.md` guess "≈0x1fbd9830"
   and makes it exact. (Not a contradiction — a sharpening to absolute addresses; see IOC §.)
6. **The `a0=8/a1=0/a2=0` kernel entry is RESOLVED, and it is NOT the ARC `Main(argc,argv,envp)` convention**
   (arcs_spec.pdf p.99–101). ARC's loaded-OS entry IS `Main(Argc,Argv,Envp)` with **Argc=0** typical and
   non-NULL Argv/Envp — but that applies to the **OSLoader (sash)**, which ARC loads. **`/unix` is loaded by
   sash one level below**, with an SGI-private handoff. So my correction (kernel entry is a0=8/a1=0/a2=0, NOT
   argc/argv/envp) is right, and now explained: **r9999's shim replaces sash, so it must emit a0=8/a1=0/a2=0 to
   `/unix` `start` — do NOT use the ARC argc/argv/envp convention for the kernel.** (a0=8 is an SGI boot flag.)
7. **ARCS romvec: my 35-entry mapping is correct** (off only by 0-based vs the spec's 1-based index). GetPeer
   (0x24) before GetChild (0x28) ✅. The spec defines **2 more trailing entries** — TestUnicodeCharacter (0x8C),
   GetDisplayStatus (0x90) — but this kernel's `FirmwareVectorLength=0x8c` = 35 entries, so those two aren't
   present here. (arcs_spec.pdf p.96–98; spec Table 4-4 has a printing typo putting Read & GetReadStatus both at
   0x64 — GetReadStatus is really 0x68.)
8. **VDMA is non-coherent on uniprocessor R4000 — the cache-op writeback-vs-invalidate split I found is
   ARCHITECTURALLY MANDATED, not an IRIX quirk** (vdma.pdf p.1–2, 7). HW snoop is **R4000MP-only**; r9999
   (uniprocessor) doesn't get it, so the driver's `Hit-Invalidate-D` (DMA-in, no writeback) and
   `Hit-WB-Invalidate-D` (DMA-out) are load-bearing. CONFIRMS my cache analysis. (VDMA is the graphics/GIO DMA
   master; the SCSI/Ethernet path is HPC3 — see #9, same coherence story.)
9. **HPC3 (SCSI/enet DMA) has NO coherence hardware — the cache ops are MANDATORY** (hpc3.pdf, whole doc has
   zero snoop/coherence text; DMA is pure-physical scatter-gather to DRAM). This is the *actual* path my
   cache-op findings came from. ⚠️ Also **CORRECTS my MAME HPC3 sub-map**: the WD33C93 SCSI register windows are
   at **0x44000 / 0x4c000** (device-base +0x4000), not 0x40000/0x48000 (those are decode bases); bbRAM window is
   0x60000–0xfffff (broader than my 0x60000–0x7ffff). bbRAM/RTC = ds1386, **1 byte per 32-bit word (×4)**.
10. **GIO64 device probe is READ-based + bus-error-on-empty; slots are 4 MB ×16** (gio64.pdf p.2-12,4-28). ⚠️
    **CORRECTS my MAME slot sizes**: GIO64 slots are natively 4 MB; my "slot0=2 MB" was the GIO32 legacy map.
    For r9999 headless, **bus-error all GIO accesses = "no device"** and IRIX skips graphics/expansion cleanly.

---

## ARCS firmware (arcs_spec.pdf — ARC 1.2; SGI = big-endian, Ver 1 Rev 10)
SPB @ phys 0x1000 (confirms my layout incl. +0x10 DebugBlock=NULL). FirmwareVector = my 35-entry romvec
(confirmed; 1-based in spec). Key structures the shim must lay down (big-endian):
- **MEMORYDESCRIPTOR** = `{ULONG Type; ULONG BasePage; ULONG PageCount}`; Type enum ExceptionBlock=0,
  SystemParameterBlock=1, FreeMemory=2, BadMemory=3, LoadedProgram=4, FirmwareTemporary=5, FirmwarePermanent=6,
  FreeContiguous=7. `GetMemoryDescriptor(NULL)`→first, chain via repeated calls, NULL at end. 4 KB pages. Must
  report ≥1 FreeMemory region. (p.95)
- **COMPONENT** (config tree): `{Class,Type,Flags (u32 each); USHORT Version,Revision; ULONG Key,AffinityMask,
  ConfigurationDataSize,IdentifierLength; CHAR *Identifier}`. `GetChild(NULL)`→root SystemClass node. IRIX 6.5
  mostly ignores the tree for direct `/unix` boot — **GetChild/GetPeer/GetParent must at least return NULL
  cleanly (or a tiny System→CPU→FPU, System→MemoryUnit tree); a wild pointer crashes early probing.** (p.59–82)
- **SYSTEMID** = `{CHAR VendorId[8]; UCHAR ProductId[8]}` (16 B). **TIMEINFO** = 7×USHORT
  `{Year(full),Month,Day,Hour,Minutes,Seconds,Milliseconds}`, UTC. (p.94–96)
- Env vars (standard): ConsoleIn/ConsoleOut, SystemPartition, OSLoader, OSLoadPartition, OSLoadFilename,
  OSLoadOptions, LoadIdentifier, AutoLoad, TimeZone, FWSearchPath. SGI adds non-standard ones (eaddr, dbaud,
  rbaud, bootfile, path…) — reproduce whatever the kernel queries. Names case-insensitive, values case-sensitive,
  `;`-separated. (p.55–57,100)
- Status codes = POSIX-numbered LONG (ESUCCESS=0…EROFS=21, p.48). Path syntax `adapter(k)controller(k)
  peripheral(k)[partition(n)][\file]` (p.74). Exception block (page 0) must be real RAM; SPB at 0x1000. (p.49–51)

## MC — Memory Controller (mc.pdf), base phys `0x1fa00000` / kseg1 `0xbfa00000`
**Remember the BE +4/+c alias when matching IRIX addresses.** Key registers (table offset; BE alias = +4):
| off | reg | notes |
|----|----|----|
| 0x00 | CPUCTRL0 | refresh/parity/endian/watchdog/sysinit; bit18 LITTLE(0=BE); bit9 SIN=full reset |
| 0x08 | CPUCTRL1 | fifo HWM, GIO timeout, HPC/EXP endian |
| 0x10 | DOGC(r)/DOGR(w) | 20-bit watchdog (counts refresh bursts; off unless CPUCTRL0.DOG) |
| 0x18 | **SYSID** | [3:0] CHIP_REV (0=RevA,1=RevB), [4] EISA-present (=0 Indy) — the MC id IRIX checks |
| 0x40 | CTRLD | refresh preload (reset 0x0C30) |
| 0x48 | REF_CTR(r) | refresh counter — **must advance** (calibration loops) |
| 0xc0 | **MEMCFG0** | banks 0&2: BASE0[23:16](×4MB, vs phys[29:22]), MSIZE0[28:24], VLD0[29], BNK0[30]; bank1/3 fields in low half BASE1[7:0]/MSIZE1[12:8]/VLD1[13]/BNK1[14] |
| 0xc8 | **MEMCFG1** | banks 1&3, same layout |
| 0xd0 | CPU_MEMACC | DRAM timing word (my live 0x11453433 = opaque timing; store/return) |
| 0xd8 | GIO_MEMACC | GIO DRAM timing |
| 0xe0–0xf8 | error addr/status (CPU & GIO) | return 0, clear-on-write |
| 0x108/0x110 | LOCK_MEMORY/EISA_LOCK | reset=unlocked; R/W storage |
| 0x01000 | **RPSS_CTR** | free-running **100 ns** 32-bit counter (separate 4 KB page) |
| 0x02000+ | DMA engine (graphics/GIO) | see VDMA |
MSIZE table: 00000=256K×36(1MB/simm), 00001=512K×36(2MB), 00011=1M×36(4MB), 00111=2M×36(8MB), 01111=4M×36(16MB),
11111=8M×36(32MB); bank=4 SIMMs. (mc.pdf §5.12 p.32–33). **Min set for boot:** CPUCTRL0, SYSID(rev+EISA=0),
CTRLD/REF_CTR(advance), MEMCFG0/1(your RAM geometry), CPU/GIO_MEMACC(store), RPSS_CTR, error regs(0/clear), locks.

## IOC2 (ioc.pdf), base phys `0x1FBD9800`; 64 word-spaced regs
**Serial console (the r9999 deliverable) — Port 1 = console:**
- **`0x1FBD9834` write** = TX data → emit byte[7:0] to your console sink (Port1 data; this is what `du_putchar`
  writes; confirmed in MAME = the SCC `ab_dc` data reg).
- **`0x1FBD9830` read** = SCC command/RR0 → return **`0x04`** (RR0 bit2 "Tx Buffer Empty") so the driver's poll
  never stalls; **`0x1FBD9830` write** = WR pointer/init → swallow. (Z85230 indirect addressing: addr bit1=channel,
  bit0=data/command. Port1=cmd 0x30/data 0x34, Port2=cmd 0x38/data 0x3C.) Baud is in DMA_SEL `0x9868[5:4]` —
  irrelevant to a stdout drain.
- **INT3 interrupt controller** (in IOC2, base `0x1FBD9880`): Local0 Status/Mask `0x9880/0x9884` (bit1 SCSI0,
  bit2 SCSI1, bit3 enet, bit5 parallel, bit4 MC-DMA-done, bit7 MAP_INT0); Local1 `0x9888/0x988c` (bit1 panel,
  bit4 HPC-DMA-done, bit3 MAP_INT1, bit7 vretrace); **serial IRQ is a *mappable* int → Map Status `0x9890` bit5**
  (kbd=bit4), routed via Map Mask0/1 `0x9894/0x9898`, polarity Map Pol `0x989c` (serial/kbd bits 4,5 active-low →
  pol 0). Timer Clear `0x98a0`, Error Status `0x98a4`. 5 outputs CPU_INT_N<4:0> → CP0 Cause IP2..IP6
  (Local0→IP2, Local1→IP3, Timer0→IP4, Timer1→IP5, BusErr→IP6). **Not needed for a polled TX console.**
- **8254 PIT** timers at `0x98b0/b4/b8/bc` (Counter0→Timer0 int, system tick).
- **Boot identification regs r9999 must answer:** SYSTEM ID `0x9858` (Guinness/Indy: [7:5]=001, [0]=0),
  Read Reg `0x9860` (power-good bits high, e.g. 0xF0), Power Control `0x9850` (accept 0x03=on; read bit0=1),
  GC/General Control `0x9848/0x984c`(=0xFF), DMA Select `0x9868`(0), Reset `0x9870`, Write `0x9878` — accept
  writes so PROM/IRIX init proceeds.

## VDMA — Virtual DMA (vdma.pdf) — FUTURE WORK
Graphics/GIO DMA master **inside the MC** (FastForward; for user `v3f()` graphics calls). NOT SCSI/enet (HPC3).
- **Translation:** its OWN 4-entry PTEBase µTLB (CAM: VPNhi→physical page-table base + valid bit), software-loaded
  on context switch, **separate from the 48-entry JTLB but walks the same R4000 page tables** — `GIO_TLBLO` PTE
  format "chosen for max compatibility with R4000 EntryLo" (p.20). HW page-table walker: VPNhi→µTLB→PTEBase→
  index VPNlo→load PTE→PFN. Geometry via `GIO_CTL[1:0]` (page 4K/16K, PTE 4/8B). 4 fault causes (PTEBase, TLB-miss,
  Page-Fault, Clean), restartable via `GIO_STDMA.Start`.
- **Coherence: NON-COHERENT on uniprocessor R4000** → driver flushes (the cache ops above). Snoop bit
  `GIO_MODE[5]` is R4000MP-only.
- Descriptor = a *register set* (no in-memory linked list): GIO_MEMADR(D)/GIO_SIZE/GIO_STRIDE/GIO_ADR(S)/GIO_MODE/
  GIO_COUNT (2D strided/zoom blitter over *virtual* memory). Poll `GIO_RUN.Run` (MC stalls the read until
  complete/snoop). Kernel regs: GIO_MASK/SUBST (addr clamp), GIO_CAUSE, GIO_CTL (Xlate bit8 = virtual/physical).
- **r9999 future model:** GIO-DMA state machine in the MC + 4-entry PTEBase µTLB + HW walker (reuse R4000 PTE
  decode) + restartable fault path; model as non-snooping → correctness rests on the L1d cache ops.

## HPC3 — peripheral/DMA controller (hpc3.pdf), base phys `0x1fb80000`–`0x1fbfffff`
The real **SCSI / Ethernet / PBUS DMA** path (where the cache-coherence findings came from). Bridges GIO64 ↔
peripherals.
- **DMA = descriptor-based scatter-gather, addresses are PURE PHYSICAL (no map/page-table, unlike VDMA).**
  Descriptor = 3×u32 {`BP`=buffer phys addr; `BC`= EOX[31] EOXP[30] XIE[29] IPG[23:16] TXD[15] ByteCount[13:0];
  `DP`=next-descriptor phys addr}, quadword-aligned, **buffer ≤1 page & can't cross a page**. Walk `DP` until
  `EOX`; `XIE`=interrupt-on-done. (p6–7)
- **⚠️ COHERENCE: HPC3 has NO snoop / NO coherence hardware — software MUST flush/invalidate.** The whole spec
  has zero coherence language; HPC3 just masters GIO64 to/from physical DRAM. **CONFIRMS my cache-op finding is
  MANDATORY:** DMA-in → `cache Hit-Invalidate-D` (no writeback) after; DMA-out → `cache Hit-WB-Invalidate-D`
  before. (p6–7,10) ⇒ r9999 modeling DMA as direct-to-DRAM + honoring those L1d ops = correct, zero coherence HW.
- Per-channel data endian bit + global `des_endian` (`gio.misc[1]`); BE IRIX → both 0.
- **I/O sub-map** (off from 0x1fb80000): PBUS DMA regs 0x00000–0x0ffff; SCSI(HD0/HD1)+ENET DMA chan regs
  0x10000–0x1ffff; **FIFO ports** 0x20000 (PBUS 0x20000, HD0 0x28000, HD1 0x2a000, ENET rx 0x2c000/tx 0x2e000)
  ✅matches MAME; **general regs** 0x30000 (`intstat`@0x30000 bits4:0 + `@0x3000c` bits9:5 [split, chip bug];
  `gio.misc`@0x30004; `eeprom.data`@0x30008; `bus_error`@0x30010); **SCSI dev regs** HD0 base 0x40000 (WD33C93
  window at **+0x4000 = 0x44000**), HD1 0x48000 (window **0x4c000**); **ENET dev** 0x54000; **PBUS dev** 0x58000
  (PIO), dma/pio cfg 0x5c000/0x5d000; **bbRAM/RTC 0x60000**.
  - **⚠️ CORRECTS MAME sub-map:** the WD33C93 SCSI register windows are at **0x44000/0x4c000** (device-base
    +0x4000), not 0x40000/0x48000 (those are the decode bases). bbRAM window is the full **0x60000–0xfffff**
    (32K-word decode), broader than MAME's 0x60000–0x7ffff.
- **bbRAM / RTC = Dallas ds1386** at 0x60000, **one byte per 32-bit word (×4 spacing)** — the SGI NVRAM holding
  `eaddr`/`console`/`OSLoad*`/`netaddr` (the env we `setenv`'d). ✅CONFIRMS. (Internal ds1386 layout = its
  datasheet, not this doc.) **Required for boot** (PROM reads boot params here).
- **Serial EEPROM (NMC93CS56)** = 5-bit bit-bang reg `eeprom.data`@0x30008 {pre[0],cs[1],clk[2],dato[3],
  dati[4]} — holds chassis serial + boot-monitor env. Distinct from the ds1386 NVRAM.
- Interrupts: all DMA chans except ENET share one `dma_complete_int`; ENET separate; `bus_error_int` for GIO
  parity. All feed INT2/INT3 (IOC2) → MC → CPU. (p8,58)
- **Min for boot:** decode 0x1fb80000+, PIO reg R/W, **bbRAM/RTC @0x60000**, EEPROM @0x30008, general regs, and
  **the SCSI channel + WD33C93 @0x44000** (to read the root disk = load the kernel). ENET/audio/parallel/PBUS
  DMA = stub until real I/O. Known chip bugs to model: SCSI-rx drops last byte (append 0-count descriptor);
  intstat split @0x30000/0x3000c; PIO read-back needs a dummy read first.

## GIO64 bus (gio64.pdf), `0x1f000000`–`0x1fffffff`
- **16 × 4 MB slots**: slot N base = `0x1f000000 + N*0x400000` (board_addr[25:22]=slot). Graphics = slot 0
  (`0x1f000000`). **⚠️ CORRECTS/reconciles MAME:** GIO64 slots are natively **4 MB**; MAME's "slot0=2 MB" is the
  older **GIO32 legacy** option-slot map (0x1f400000/0x1f600000 = 2 MB each) — both valid for their bus gen;
  IP22 wires only a few of the 16 slots, the rest bus-error.
- **Device probe is READ-based, not address-probe:** read the **Product Identification Word** at slot base
  (aliased base+0/+4, endian-independent): `[7:0]`=Product ID (`[7]`=all-bits-valid), `[15:8]`=rev, `[16]`=64-bit,
  `[17]`=ROM-present, `[31:18]`=mfr. **Empty slot → 25 µs bus time-out → bus-error interrupt; IRIX uses that to
  detect "no device."** ⇒ **r9999 headless: bus-error every GIO access (incl. graphics) = "all slots empty," and
  IRIX skips them.** (p2-12,4-20,4-28)
- Interrupts: 3 INT lines/slot (active-low) + 1 status; **graphics uses INT2/INT0, option slots use INT1**;
  shared lines (drivers tolerate spurious). Route through IOC2/INT3 → CP0 Cause IP (mapping = IOC doc).
- DMA: a GIO master moves data **physical, page-bounded** to/from memory; byte-count cycle carries device-ID
  (for MP coherence), endian[28], count-direction, CPU-subblock-ordering[27]. The MC's VDMA graphics engine is a
  GIO64 long-burst master running this. Big-endian byte0→AD[31:24].
- **Min for r9999 headless:** decode 0x1f000000–0x1fffffff; **bus-error unpopulated/all slots** (spec-correct
  "no device"); MC `GIO64_ARB` as R/W storage (PROM writes arbiter timing; no masters → arbitration never runs).
  Everything else (bus protocol, DMA fields, INT routing) only when adding a real GIO device.

## Source docs (for deeper dives)
`~/code/sgi/docs/arcs_spec.pdf`; `~/code/sgi/docs/indy_docs/ip22/{mc,ioc,vdma,hpc3,gio64,dmux1}.pdf`.
Mined: arcs, mc, ioc, vdma, **hpc3, gio64**. Not yet mined: **dmux1.pdf** (data mux), plus `indy_docs/newport/*`
(graphics: rex3/vc2/xmap9/rb2/ro1), `indy_docs/vino/*` (video-in), `o2_docs/ip32/*` (O2: crime/mace/vice/gbe).
