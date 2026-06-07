/* baremetal_mapped_insn.ld -- .text in kuseg (I-TLB mapped 1:1), data in kseg0.
 *
 * Boot stub and exception vectors stay at 0xBFC00000 (kseg1, unmapped).
 * .text is placed at 0x00200000 (kuseg); start_csmith_mapped_insn.S installs
 * 48 TLB entries with 1:1 VA→PA mapping for 0x200000-0x25FFFF before
 * jumping there, so all instruction fetches go through the I-side TLB.
 *
 * rodata/data/BSS stay at 0x80020000 (kseg0, unmapped), so the D-side TLB
 * is not exercised.  Stack grows down from _end + 64 KB in kseg0.
 *
 * 1:1 mapping: va2pa() returns VA unchanged for bit-31=0 addresses, matching
 * the TLB-translated PA, so the checker requires no modification.
 */
ENTRY(_start)

SECTIONS
{
  . = 0xbfc00000;
  .boot : {
    KEEP(*(.boot.reset))
    . = 0x180;
    KEEP(*(.boot.exc))
  }

  /* kuseg instruction text, I-TLB mapped 1:1 to PA 0x200000-0x25FFFF */
  . = 0x00200000;
  .text : { *(.text .text.*) }

  /* kseg0 data, unmapped */
  . = 0x80020000;
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
