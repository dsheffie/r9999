/* iss_main.cc -- run a bare-metal ELF on the interpreter alone (no RTL), to
 * test ISS paths the RTL does not implement (e.g. -DISS_FULL_MIPS4). */
#include <cstdio>
#include <cstdlib>
#include "interpret.hh"
#include "loadelf.hh"
#include "sparse_mem.hh"
#include "globals.hh"

namespace globals {
  bool trace_retirement = false;
}

int main(int argc, char *argv[]) {
  if(argc != 2) {
    fprintf(stderr, "usage: %s <elf>\n", argv[0]);
    return 1;
  }
  sparse_mem *sm = new sparse_mem();
  state_t *s = new state_t(*sm);
  initState(s);
  load_elf(argv[1], s);
  uint64_t n = 0;
  while(not(s->brk) and (n < (1UL << 32))) {
    execMips(s);
    n++;
  }
  fprintf(stderr, "iss: %lu insns, pc %lx\n", n, (unsigned long)s->pc);
  return 0;
}
