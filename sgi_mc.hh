#ifndef __sgi_mc__
#define __sgi_mc__

#include <cstdint>
#include <cstddef>

static const uint32_t sys_id = 0x3; /* mame says rev c */  

struct state_t;

class sgi_mc {
  state_t *s;
  uint32_t eeprom_ctrl;
  uint32_t cpu_error_status;
  uint32_t gio_error_status;
  uint32_t cpu_mem_access_config;
  uint32_t gio_mem_access_config;
  uint32_t gio64_arb_param;
  uint32_t rpss_divider;
  uint32_t rpss_counter;
  uint32_t cpu_control[2] = {0};
  uint32_t memcfg[2] = {0};
  uint32_t systemid = 0;   /* low nibble = MC revision (rev<5 -> 22/14 shifts) */
public:
  sgi_mc(state_t *s) : s(s),
		       eeprom_ctrl(0),
		       cpu_error_status(0),
		       gio_error_status(0),
		       cpu_mem_access_config(0),
		       gio_mem_access_config(0),
		       gio64_arb_param(0),
		       rpss_divider(0x104),
		       rpss_counter(0) {
    /* Advertise installed DRAM as the IP22 PROM would, so the kernel MC probe
     * (ip22-mc.c) finds it.  bank0 = mconfig0[31:16] describes 128 MiB at
     * physical 0x08000000 (MC rev<5: addr=(cfg&0xff)<<22, size=((cfg&0x1f00)+
     * 0x100)<<14).  cfg = BVALID(0x2000)|RMASK(0x1f00)|BASE(0x20) = 0x3f20. */
    /* The MC register read path delivers the word byte-swapped relative to the
     * big-endian value the kernel reads, so store the byte-swapped form. */
    memcfg[0] = __builtin_bswap32(0x3f20u << 16);   /* kernel reads 0x3f200000 */
    memcfg[1] = 0;
    systemid  = 0;
  };
  uint32_t read(uint32_t offs, size_t sz);
  void write(uint32_t offs, uint32_t x, size_t sz);  
};


#endif


