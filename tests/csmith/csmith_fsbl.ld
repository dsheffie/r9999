/* csmith_fsbl.ld -- linker script for csmith tests booted via the henry_arcs FSBL.
 *
 * Everything in cached, unmapped kseg0 (PA = VA & 0x1fffffff) -- no kuseg, no TLB,
 * so the mapped-runtime "state 1" hang on the Henry FPGA does not apply.  The FSBL
 * jumps to e_entry (= _start); the driver loads the ELF into DRAM exactly like the
 * kernel (sgi_mode: fpga_remap(va2pa(p_vaddr))).
 *
 * Layout (kseg0 0x88xxxxxx -> PA 0x08xxxxxx, main DRAM):
 *   0x88000000..0x88003fff  FSBL low-reserved (SPB / exc-vector backing) -- avoid
 *   0x88010000              _start, .text, .rodata, .data, .bss  (grows up)
 *   0x8c000000              stack (grows down; 64 MB into the 128 MB DRAM)
 *   0x88fff000              FSBL argv/envp blob -- below the stack, above bss (unused)
 *
 * No OUTPUT_FORMAT: built with -Wl,-melf32btsmipn32 (N32, like the QEMU-checked sizes).
 */
ENTRY(_start)

SECTIONS
{
  . = 0x88010000;
  .text : {
    KEEP(*(.text.startup))          /* _start FIRST -> e_entry = 0x88010000 */
    *(.text .text.*)
  }

  . = ALIGN(16);
  .rodata : { *(.rodata .rodata.*) }

  . = ALIGN(16);
  .data   : { *(.data .data.*) *(.sdata .sdata.*) }

  . = ALIGN(16);
  __bss_start = .;
  .bss : {
    *(.bss .bss.*)
    *(.sbss .sbss.*)
    *(COMMON)
  }
  . = ALIGN(16);
  __bss_end = .;
  _end = .;

  . = 0x8c000000;
  _stack_top = . - 16;            /* 16-byte margin at the top */

  /DISCARD/ : {
    *(.MIPS.abiflags)
    *(.reginfo)
    *(.gnu.attributes)
    *(.comment)
    *(.note .note.*)
    *(.pdr)
    *(.eh_frame*)
    *(.got*)
    *(.rel.*)
    *(.rela.*)
  }
}
