/* baremetal_mapped.ld  --  like baremetal.ld but rodata/data/BSS in kuseg.
 *
 * Boot stub and exception vector stay at 0xBFC00000 (kseg1).
 * Text stays at 0x80020000 (kseg0) so I-side TLB is not required.
 *
 * rodata/data/BSS are placed at 0x00400000 (kuseg).  The startup in
 * start_csmith_mapped.S installs 48 TLB entries with a 1:1 VA→PA
 * mapping for that range (0x400000–0x45FFFF, 384 KB) before main()
 * is called, so all data accesses go through the D-side TLB.
 *
 * 1:1 mapping means the interpreter's va2pa() returns the VA unchanged
 * (bit 31 = 0), which equals the TLB-translated PA, so the checker
 * works without any interpreter changes.
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

  . = 0x80020000;
  .text : { *(.text .text.*) }

  /* ---- data in kuseg, TLB-mapped 1:1 ---- */
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
