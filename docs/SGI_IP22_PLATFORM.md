# SGI IP22 (Indy / Indigo2) Platform Notes

Reference for booting a 64-bit MIPS Linux (IP22) on the r9999 RTL. Sources:
`indy_docs/mc.pdf`, `indy_docs/hpc3.pdf`, and the Linux source at
`/home/dsheffie/code/linux-mips` (`arch/mips/sgi-ip22/`, `arch/mips/include/asm/sgi/`,
`drivers/tty/serial/ip22zilog.c`). All addresses are **physical** unless noted.

IP22 is R4000/R4400-class. The two big custom chips are the **MC** (memory/CPU
controller) and the **HPC3** (high-performance peripheral controller); peripherals
(UART, keyboard, RTC, SCSI, enet) hang off the HPC3's PBUS.

---

## Kernel image / load addresses

From `arch/mips/sgi-ip22/Platform`:

| kernel | load vaddr | notes |
|--------|-----------|-------|
| 32-bit | `0xffffffff80002000` | |
| 64-bit | `0xffffffff88004000` | must be raised 8 KB vs 32-bit for `current` alignment |

For the built 64-bit `vmlinux` (ELF64 big-endian) / `vmlinux.32` (ELF32 wrapper,
same content, low-32 addresses):

- single `PT_LOAD`: vaddr=paddr `0xffffffff88004000`, filesz `0x45fb80` (~4.6 MB),
  memsz `0x4aa280` (~4.9 MB incl BSS)
- `_text` = `0xffffffff88004000`, `_stext` = `0xffffffff88004400`
- **entry = `kernel_entry` = `0xffffffff8830e898`**

`0x88004000` is **ckseg0** (compat kseg0, unmapped+cached). PA = vaddr & `0x1fffffff`
= **`0x08004000`**. The `0x08…` is the tell that **IP22 main RAM is based at physical
`0x08000000`** (the low PA range is I/O); the kernel sits at RAM_base + 16 KB.

### Loading on r9999
`vmlinux.32` is ELF32, so the existing `load_elf` works directly — no special loader:
```
./ooo_core --file /home/dsheffie/code/linux-mips/vmlinux.32 -c 0
```
`va2pa(0x88004000)` → PA `0x08004000`; entry PC sign-extends to `0xffffffff8830e898`.
ckseg0 is unmapped and `mipsseg.sv` takes the compat path even at reset (KX=0), so
early boot needs no TLB.

---

## MC — Memory / CPU controller  @ `0x1fa00000`–`0x1fafffff` (1 MB)

The registers the PROM/kernel reads at boot (the "firmware magic values"):

| reg | addr | purpose |
|-----|------|---------|
| CPUCTRL0 | `0x1fa00000` | CPU control 0 |
| CPUCTRL1 | `0x1fa00008` | CPU control 1 |
| DOGC/DOGR | `0x1fa00010` | watchdog timer (R) / clear (W) |
| SYSID | `0x1fa0001c` | system ID (board/chip rev) |
| RPSS_DIVIDER | `0x1fa0002c` | RPSS divider |
| EEROM | `0x1fa00030` | R4000 EEROM interface |
| CTRLD | `0x1fa00040` | refresh counter preload |
| REF_CTR | `0x1fa0004c` | refresh counter (R) |
| GIO64_ARB | `0x1fa00080` | GIO64 arbitration |
| **MEMCFG0** | **`0x1fa000c0`** | **memory size config, banks 0–3** |
| **MEMCFG1** | **`0x1fa000c8`** | **memory size config, banks 4–7** |
| CPU_MEMACC | `0x1fa000d0` | CPU main-memory access config |
| GIO_MEMACC | `0x1fa000d8` | GIO main-memory access config |

Register stride note: the doc writes e.g. `0x1fa00018/c` meaning the readable byte
sits at the `+0x1c` end of the word (big-endian).

**MEMCFG0/1 are the values that describe installed RAM** — program them (or the sim's
MC model) to advertise RAM at base `0x08000000`, and the kernel's memory probe finds
RAM without a real PROM.

---

## HPC3 — Peripheral controller  @ chip0 `0x1fb80000`, chip1 `0x1fb00000`

`HPC3_CHIP0_BASE = 0x1fb80000`, `HPC3_CHIP1_BASE = 0x1fb00000`
(`arch/mips/include/asm/sgi/hpc3.h`).

Selected HPC3 chip0 register windows (from the HPC3 spec §3 address map):

| range (offset from `0x1fb80000`) | contents |
|-----|------|
| `0x00000`–`0x0ffff` | PBUS DMA channel registers (8 channels) |
| `0x10000`–`0x1ffff` | HD0/HD1/ENET DMA channel registers |
| `0x20000`–`0x2ffff` | FIFO access ports |
| `0x4c000`/`0x54000` | SCSI ch0/ch1 external regs |
| `0x58000` + ch*`0x400` | **PBUS PIO channel external regs** (`pbus_extregs[16][256]` u32) |
| `0x5d0008` (chip-rel) | serial EEPROM data (`eeprom.data`) |

Peripherals on PBUS: Boot PROM, INT2 interrupt controller, FDC (PC8477), SCSI
(WD33C93), **UARTs**, Keyboard/Mouse, RTC. The HPC3 spec explicitly notes it does
not know which PBUS channel a device is on — that mapping is the IP22 board design,
so the kernel source is authoritative.

---

## UART / serial console — `0x1fbd9830`

**Zilog 85230 SCC**, on HPC3 chip0 **PBUS PIO channel 6**. Driver:
`drivers/tty/serial/ip22zilog.c`. Computed from `arch/mips/sgi-ip22/ip22-platform.c`:

```
SGI_ZILOG_BASE = HPC3_CHIP0_BASE            0x1fb80000
               + offsetof(hpc3_regs, pbus_extregs[6])   0x59800   (0x58000 + 6*0x400)
               + offsetof(sgioc_regs, uart)             0x30      (pi1_regs=0x28 + _unused0[2]=8)
               = 0x1fbd9830
```

`struct sgioc_uart_regs { ctrl1; data1; ctrl2; data2; }` — each is `u8 _x[3];
volatile u8 x;`, so the live byte is at **+3** of each word (big-endian):

| reg | addr |
|-----|------|
| ctrl1 (cmd/status) | `0x1fbd9833` |
| data1 (tx/rx) | `0x1fbd9837` |
| ctrl2 | `0x1fbd983b` |
| data2 | `0x1fbd983f` |

The SCC has two channels (A/B); `ip22zilog` maps channel B then channel A — console
is normally channel B. **Caveat:** the `ip22zilog` console registers as a
`device_initcall`, i.e. *late* in boot — it will not show output during the earliest
boot phase.

---

## r9999 sim integration notes

- The sim already has device models `sgi_mc.cc` / `sgi_hpc.cc` (used only by the
  `--indy` ROM path, not `--file`). `sgi_mc` **already implements `memcfg[]`**
  (reads at `0xc0`/`0xc8`); `sgi_hpc` has **no UART** yet.
- Plan to get past early boot + gain console ("jam magic values like firmware"):
  1. instantiate `sgi_mc` + `sgi_hpc` on the kernel-boot path (as `--indy` does),
  2. program MEMCFG0/1 (+ SYSID) to advertise RAM at base `0x08000000`,
  3. add a Tx path in `sgi_hpc` at the SCC data register (`0x1fbd9837`/`0x1fbd983f`)
     that writes the byte to stdout.
- Console output also available immediately via the CP0-reg-7 putchar port
  (`mtc0 rt, $7`) if the kernel's earlycon is patched to use it.

## Current boot status (2026-06-07)
`--file vmlinux.32 -c 0` runs ~133K instructions of real boot, then takes an
exception (last kernel PC `0x8801c69c`) that vectors to `0xbfc00180` (BEV=1 general
vector, our RTL base `0xbfc00000`). No PROM/handler there → NOP-slides in empty
kseg1. Suspected cause: reading an unpopulated MC/HPC register (returns 0) → bad
address/fault. Next: populate MC/HPC magic values and/or disassemble around
`0x8801c69c` to identify the faulting access.
