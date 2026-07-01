/*
 * scsi_read.c -- bare-metal directed test of the "radically different DMA controller".
 *
 * Plays the GUEST: programs the WD33C93 + HPC3 SCSI DMA channel exactly as IRIX/Linux
 * would, issues a READ(10) of LBA 0, waits for INTRQ, and checks the DMA'd buffer.
 * Under henry_tb --disk, the TB plays the ARM: on the doorbell it preads the disk and
 * streams the bytes across the beat conduit; the scsi_dma RTL engine (the only agent
 * that touches MIPS memory) walks the descriptor and writes mem[BP] via M00.
 *
 * LBA 0 of an IRIX disk is the SGI volume header -> word0 = magic 0x0be5a941.  Pre-fill
 * the buffer with a sentinel so we can tell "engine wrote disk data" from "nothing
 * happened".  Everything here is uncached (kseg1), so no cache management is needed to
 * see the engine's DRAM writes -- this isolates the DMA path itself.
 *
 * Run: henry_tb --kernel scsi_read.elf --arcs henry_arcs.bin --start-pc 0xbfc00000 \
 *               --disk irix65-clean.img --maxcyc 400000
 */
#include "henry_io.h"

/* WD33C93 indirect-register ports (HD0 device region, SASR=byte3, SCMD=byte7) */
#define SASR (*(volatile unsigned char *)0xbfbc0003u)
#define SCMD (*(volatile unsigned char *)0xbfbc0007u)
/* HPC3 SCSI0 DMA channel registers */
#define HPC_NBDP (*(volatile unsigned int *)0xbfb90004u)   /* offs 0x10004: next-descriptor ptr */
#define HPC_BC   (*(volatile unsigned int *)0xbfb91000u)   /* offs 0x11000: byte count */
#define HPC_CTRL (*(volatile unsigned int *)0xbfb91004u)   /* offs 0x11004: ctrl (bit4=ACTIVE, bit2=DIR) */

/* scratch DRAM (uncached kseg1 views): descriptor + DMA target buffer */
#define DESC ((volatile unsigned int *)0xa9000000u)        /* phys 0x09000000 */
#define BUF  ((volatile unsigned int *)0xa9001000u)        /* phys 0x09001000 */
#define DESC_PHYS 0x09000000u
#define BUF_PHYS  0x09001000u

/* write a WD33C93 indirect register: SASR<-index, then SCMD<-value */
static void wd(unsigned idx, unsigned val) { SASR = (unsigned char)idx; SCMD = (unsigned char)val; }

int main(void)
{
    unsigned i;

    /* 1. sentinel-fill the 512-byte buffer (uncached -> straight to DRAM) */
    for (i = 0; i < 128; i++) BUF[i] = 0x5e5e5e5eu;

    /* 2. HPC3 descriptor @DESC: BP=buffer, BC=EOX|512, DP=0 (engine bswaps on read) */
    DESC[0] = BUF_PHYS;               /* BP  */
    DESC[1] = 0x80000000u | 512u;     /* BC  = EOX(bit31) | count 512 */
    DESC[2] = 0u;                     /* DP  = 0 (single descriptor) */
    DESC[3] = 0u;

    /* 3. arm the HPC3 channel: chain head = DESC, ACTIVE, direction = READ */
    HPC_NBDP = DESC_PHYS;
    HPC_BC   = 0x80000000u | 512u;
    HPC_CTRL = 0x10u;                 /* bit4 ACTIVE, bit2=0 -> disk->mem */

    /* 4. WD33C93: dest=1 (the disk), lun=0, CDB = READ(10) LBA 0, 1 block */
    wd(0x15, 1u);                     /* DEST_ID    */
    wd(0x0f, 0u);                     /* TARGET_LUN */
    wd(0x03, 0x28u);                  /* CDB[0] = READ(10) */
    wd(0x04, 0u);
    wd(0x05, 0u); wd(0x06, 0u); wd(0x07, 0u); wd(0x08, 0u);  /* LBA = 0 */
    wd(0x09, 0u);
    wd(0x0a, 0u); wd(0x0b, 1u);      /* transfer length = 1 block */
    wd(0x0c, 0u);

    /* 5. issue SELECT-AND-TRANSFER -> the shim doorbell */
    wd(0x18, 0x08u);

    /* 6. spin until INTRQ (aux-status bit7) -- the engine has landed the data */
    while (!(SASR & 0x80u)) { }

    /* 7. verify: buffer should hold LBA 0 = SGI volume header (magic 0x0be5a941) */
    {
        unsigned w0 = BUF[0];
        puts_("scsi_read: buf[0]="); puthex32(w0); putch('\n');
        if (w0 == 0x0be5a941u)        puts_("scsi_read: PASS (SGI vh magic)\n");
        else if (w0 != 0x5e5e5e5eu)   puts_("scsi_read: FAIL (wrote, but wrong data)\n");
        else                          puts_("scsi_read: FAIL (sentinel intact, no DMA)\n");
    }
    sim_halt();
    return 0;
}
