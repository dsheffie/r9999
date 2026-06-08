/*
 * arcs.ld  --  linker script for the synthetic ARCS firmware blob.
 *
 * Link everything at kseg1 0xA0001000 so the absolute pointers inside the SPB
 * and romvec (and `la` in the stubs) resolve to the addresses the kernel will
 * actually call/dereference.  The kernel reads the SPB at PROMBLOCK == kseg1
 * 0xA0001000; objcopy -O binary flattens from this VMA and the simulator loads
 * the blob at physical 0x1000 (vaddr & 0x1fffffff).
 */

OUTPUT_FORMAT("elf32-tradbigmips")
OUTPUT_ARCH(mips)
ENTRY(arcs_spb)

SECTIONS
{
    . = 0xA0001000;

    .arcs : {
        *(.arcs)
        *(.text .text.*)
        *(.rodata .rodata.*)
        *(.data .data.*)
    }

    /DISCARD/ : {
        *(.reginfo)
        *(.MIPS.abiflags)
        *(.gnu.attributes)
        *(.note .note.*)
        *(.comment)
        *(.pdr)
        *(.bss .sbss COMMON)
    }
}
