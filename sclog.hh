#ifndef __SCLOG_HH__
#define __SCLOG_HH__
#include <cstdint>
#include <cstdio>
#include <cstdlib>

/* SCLOG=<file>: binary log of every D/SD CACHE op and every HPC3 SCSI DMA
 * descriptor, to see which lines IRIX names (invalidates / writes back) around
 * each disk transfer -- in particular once it believes there is a secondary
 * cache (SCSIZE=<bytes>, see interpret.cc initState).  Decoded by sclog.py. */
struct sclog_rec_t {
  uint64_t icnt;
  uint32_t pa;
  uint32_t len;   /* DMA: bytes this descriptor; CACHE: 0 */
  uint32_t pc;
  uint8_t  type;  /* 1 = CACHE op, 2 = DMA device->mem, 3 = DMA mem->device */
  uint8_t  cop;   /* CACHE: insn[20:16] (op<<2 | cache) */
  uint16_t pad;
};

static inline FILE *sclog_file() {
  static FILE *f = nullptr;
  static bool init = false;
  if(!init) {
    init = true;
    const char *p = getenv("SCLOG");
    if(p) {
      f = fopen(p, "wb");
    }
  }
  return f;
}

static inline void sclog(uint8_t type, uint64_t icnt, uint32_t pa, uint32_t len, uint32_t pc, uint8_t cop) {
  FILE *f = sclog_file();
  if(f == nullptr) {
    return;
  }
  sclog_rec_t r = {icnt, pa, len, pc, type, cop, 0};
  fwrite(&r, sizeof(r), 1, f);
}
#endif
