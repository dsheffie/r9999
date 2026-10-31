#ifndef __GLOBALSH__
#define __GLOBALSH__

namespace globals {
  extern bool enClockFuncts;
  extern uint64_t icountMIPS;
  extern uint64_t cycle;
  extern bool trace_retirement;
  extern bool trace_fp;
  extern bool report_syscalls;
  /* --ip28: the Indigo2 R10000 board (the indysim device models read it) */
  extern bool ip28;
};

#endif
