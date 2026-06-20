/*
 * henry.ld -- linker script for Henry-SoC BARE-METAL tests booted via the
 * henry_arcs FSBL.
 *
 * Boot model: run the test exactly like the kernel.  The FSBL at 0xBFC00000
 * does early bring-up, then `jr`s to the kernel-entry slot, which the mips-axi
 * driver patches with the loaded ELF's e_entry.  So we just link an ordinary
 * ELF at a cached kseg0 address (PA = VA & 0x1fffffff) and let the driver load
 * it into DRAM (sgi_mode: fpga_remap(va2pa(p_vaddr))) -- identical to how `unix`
 * loads.  kseg0 is unmapped+cached, so this sidesteps the mapped bare-metal
 * runtime (start_csmith_mapped.S) that hangs at "state 1" on the Henry FPGA.
 *
 * Address map (kseg0 0x88xxxxxx -> PA 0x08xxxxxx, main DRAM):
 *   0x88000000..0x88003fff  low-reserved (FSBL SPB / exc-vector backing) -- avoid
 *   0x88010000              test code + data
 *   0x88070000             stack (grows down)
 *   0x88fff000             FSBL argv/envp blob -- avoid
 */

OUTPUT_FORMAT("elf32-tradbigmips")
OUTPUT_ARCH(mips)
ENTRY(_start)

SECTIONS
{
    . = 0x88010000;
    .text : {
        *(.text.startup)
        *(.text .text.* .gnu.linkonce.t.*)
    }

    . = ALIGN(4);
    .rodata : {
        *(.rodata .rodata.* .gnu.linkonce.r.*)
    }

    . = ALIGN(4);
    .data : {
        *(.data .data.* .gnu.linkonce.d.*)
        *(.sdata .sdata.* .gnu.linkonce.s.*)
    }

    . = ALIGN(4);
    __bss_start = .;
    .bss : {
        *(.bss .bss.* .gnu.linkonce.b.*)
        *(.sbss .sbss.* .gnu.linkonce.sb.*)
        *(COMMON)
    }
    . = ALIGN(4);
    __bss_end = .;

    . = 0x88070000;
    _stack_top = . - 16;     /* 16-byte margin at the top */

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
        *(.MIPS.abiflags)
        *(.reginfo)
    }
}
