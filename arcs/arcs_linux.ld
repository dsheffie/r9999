/*
 * arcs_linux.ld -- linker script for the IP22-faithful ARCS firmware: a
 * first-stage boot loader (FSBL) that lives in the Boot PROM at kseg1
 * 0xBFC00000 (phys 0x1fc00000) and, at reset, copies the small SPB/romvec
 * block into RAM at kseg1 0xA0001000 (phys 0x1000) before handing off.
 *
 * Why: on a real IP22 the 16 KB of stub CODE lives in the PROM, and only the
 * tiny SPB/romvec DATA sits at 0x1000 (which the "System Memory Alias" maps
 * into the bottom of main DRAM @ 0x08000000).  Loading the whole 16 KB blob at
 * 0x1000 would overlap the kernel _text (@ phys 0x08004000); the FSBL copies
 * only the ~3 KB SPB there, so nothing collides.
 *
 * Layout:
 *   .arcs_boot/.arcs_code  VMA=LMA 0xBFC00000  (PROM: FSBL + stubs + ro data)
 *   .arcs_spb              VMA 0xA0001000, LMA right after the PROM code
 *                          (the FSBL copies _spb_size bytes LMA -> VMA at boot)
 *
 * The simulator/driver load the single flat blob into the PROM region (which
 * the address map shadows into DRAM); the core resets to 0xBFC00000.
 */

OUTPUT_FORMAT("elf32-tradbigmips")
OUTPUT_ARCH(mips)
ENTRY(arcs_boot)

SECTIONS
{
    . = 0xBFC00000;

    .arcs_prom : {
        *(.arcs_boot)               /* arcs_boot FIRST -> reset vector 0xBFC00000 */
        *(.arcs_code)               /* callback stubs + returned ro data */
        *(.text .text.*)
        *(.rodata .rodata.*)
        *(.data .data.*)
        . = ALIGN(8);
    }

    _spb_lma = LOADADDR(.arcs_spb); /* where the SPB block is stored in the PROM */

    .arcs_spb 0xA0001000 : AT(ADDR(.arcs_prom) + SIZEOF(.arcs_prom)) {
        _spb_vma = .;               /* runtime dest = 0xA0001000 */
        *(.arcs_spb)                /* SPB + kentry slot + romvec + pvec */
        . = ALIGN(8);
        _spb_end = .;
    }
    _spb_size = _spb_end - _spb_vma;

    /DISCARD/ : {
        *(.reginfo) *(.MIPS.abiflags) *(.gnu.attributes)
        *(.note .note.*) *(.comment) *(.pdr) *(.bss .sbss COMMON)
    }
}
