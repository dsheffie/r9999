/*
 * link.ld  --  bare-metal linker script for R4000 MIPS tests
 *
 * Address map (kseg0 = VA 0x80xxxxxx, PA = VA & 0x1fffffff):
 *
 *   0x80000000  BEV=0 exception vectors  (512 bytes reserved)
 *   0x80010000  test code and data
 *   0x80070000  stack (grows down, 64 KB)
 */

OUTPUT_FORMAT("elf32-tradbigmips")
OUTPUT_ARCH(mips)
ENTRY(_start)

SECTIONS
{
    /* ----------------------------------------------------------------
     * Exception vectors (BEV=0 layout)
     * Tests that exercise exceptions must populate this region.
     * --------------------------------------------------------------- */
    . = 0x80000000;
    .except_vec : {
        KEEP(*(.except_vec))
    }

    /* ----------------------------------------------------------------
     * Normal code and read-only data
     * --------------------------------------------------------------- */
    . = 0x80010000;
    .text : {
        *(.text.startup)
        *(.text .text.* .gnu.linkonce.t.*)
    }

    . = ALIGN(4);
    .rodata : {
        *(.rodata .rodata.* .gnu.linkonce.r.*)
    }

    /* ----------------------------------------------------------------
     * Writable data
     * --------------------------------------------------------------- */
    . = ALIGN(4);
    .data : {
        *(.data .data.* .gnu.linkonce.d.*)
        *(.sdata .sdata.* .gnu.linkonce.s.*)
    }

    /* ----------------------------------------------------------------
     * BSS (zero-initialised, but sparse_mem is already zeroed anyway)
     * --------------------------------------------------------------- */
    . = ALIGN(4);
    __bss_start = .;
    .bss : {
        *(.bss .bss.* .gnu.linkonce.b.*)
        *(.sbss .sbss.* .gnu.linkonce.sb.*)
        *(COMMON)
    }
    . = ALIGN(4);
    __bss_end = .;

    /* ----------------------------------------------------------------
     * Stack: 64 KB immediately above BSS, capped at 0x80070000
     * --------------------------------------------------------------- */
    . = 0x80070000;
    _stack_top = . - 16;    /* 16-byte margin at the very top */

    /* ----------------------------------------------------------------
     * Discard Linux/libc sections that have no meaning here
     * --------------------------------------------------------------- */
    /DISCARD/ : {
        *(.note*)
        *(.eh_frame*)
        *(.gnu_debuglink*)
        *(.interp)
        *(.dynamic)
        *(.got*)
        *(.plt*)
        *(.rel.*)
        *(.rela.*)
    }
}
