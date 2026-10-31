/*
 * sgi_shim.cc -- what the indysim device models (sgi_hpc/mc/scc/scsi/seeq/ps2, copied
 * from indysim d6f4a44) link against but ooo_core does not carry: indysim's L1 cache
 * model (its DMA-study hooks are off: g_cmodel stays null), the MAME CHD disk reader
 * (needs libchdr; ooo_core boots no disk image yet), and the Newport graphics board
 * (no GIO graphics: s->np stays null).  None of these is ever reached.
 */
#include <cstdlib>
#include "cache_model.hh"
#include "chd_reader.hh"
#include "sgi_newport.hh"

cache_model *g_cmodel = nullptr;

chd_reader::~chd_reader() {}
bool chd_reader::open(int) {
  return false;
}
bool chd_reader::is_magic(const uint8_t *) {
  return false;
}
void chd_reader::read_block(uint64_t, uint8_t *) {
  abort();
}

uint64_t sgi_newport::read(uint32_t, size_t) {
  abort();
}
void sgi_newport::write(uint32_t, uint64_t, size_t) {
  abort();
}
void sgi_newport::dump_ppm(const char *) {
  abort();
}
/* called on every MC DMA (sgi_mc.cc), Newport or not: indysim's trace hook, a no-op here */
void sgi_newport::trace_dma(uint64_t, bool, uint32_t, uint32_t) {
}
