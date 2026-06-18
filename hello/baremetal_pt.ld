/* baremetal_pt.ld -- "real page table" csmith variant.
 *
 * Unlike baremetal_mapped.ld (which pre-installs a 1:1 TLB and never faults),
 * this layout runs with an EMPTY TLB and a software TLB-refill handler, so the
 * program's data accesses fault in dynamically and churn through Random
 * eviction -- hammering the refill/eviction/V/D/ASID path.
 *
 * Vectoring: the RTL sends a TLB refill to (BEV?0xbfc00000:0x80000000)|offset
 * (core.sv). BEV=1's refill vector (0xbfc00000) COLLIDES with reset, so the
 * reset stub clears BEV and we place handlers in kseg0:
 *   0x80000000  TLB refill vector (32-bit; KX=0 so misses land here, not XTLB)
 *   0x80000180  general exception vector (break/unaligned/timer)
 *
 * Memory map:
 *   0xbfc00000  .boot.reset   reset entry (BEV=1 at reset; stub clears BEV)
 *   0x80000000  .vec.refill   asm TLB-refill fast path (kseg0, unmapped)
 *   0x80000180  .vec.gen      general handler stub (kseg0, unmapped)
 *   0x80010000  .kdata        page table + exc_regfile + kstack (kseg0, NEVER
 *                             faults -- the refill handler reads the PT here)
 *   0x80020000  .text         program text (kseg0, unmapped -- I-side not mapped)
 *   0x00400000  .rodata/.data/.bss  USER data, kuseg, TLB-mapped (512 KB / 128
 *                             pages -- power of two so an XOR page-permutation
 *                             is a bijection for the scrambled mapping).
 *
 * The VA->PA scramble is a runtime physical page-permutation done by pt_setup()
 * before main(), so the program still links+loads 1:1 at 0x400000 -- no LMA!=VMA
 * loader support needed.
 */
ENTRY(_start)

SECTIONS
{
  . = 0xbfc00000;
  .boot.reset : { KEEP(*(.boot.reset)) }

  . = 0x80000000;
  .vec.refill : { KEEP(*(.vec.refill)) }

  . = 0x80000180;
  .vec.gen : { KEEP(*(.boot.exc)) }

  . = 0x80010000;
  .kdata : {
    *(.kdata .kdata.*)
  }

  . = 0x80020000;
  .text : { *(.text .text.*) }

  /* ---- user data in kuseg, TLB-mapped (scrambled) ---- */
  . = 0x00400000;
  .rodata : { *(.rodata .rodata.*) }
  .data   : { *(.data .data.*) *(.sdata .sdata.*) }
  . = ALIGN(16);
  .bss    : {
    *(.bss .bss.*)
    *(.sbss .sbss.*)
    *(COMMON)
  }
  . = ALIGN(16);
  _end = .;

  /DISCARD/ : {
    *(.MIPS.abiflags)
    *(.reginfo)
    *(.gnu.attributes)
    *(.comment)
    *(.note .note.*)
    *(.pdr)
  }
}
