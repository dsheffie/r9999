/* CBMC harness: verify the ARCS stubs in henry_fw.c against symbolic (kernel-
 * controlled) inputs -- memory safety of the getenv string scan and the Write loop.
 * Builds only under CBMC; not part of the firmware.  Run:
 *   cbmc henry_fw.c cbmc_harness.c --function harness_getenv  --bounds-check ...
 *   cbmc henry_fw.c cbmc_harness.c --function harness_write   --bounds-check ...
 */

/* externs henry_fw.c references (modelled; real layout lives in henry_arcs.S) */
char monitor_str[2] = { 'h', 0 };
char eaddr_str[18]  = "08:00:69:12:34:56";
unsigned int mdesc_ram[3]      = { 2, 0, 0 };
unsigned int root_component[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };
unsigned char _spb_lma[16], _spb_size[1];
unsigned char arcs_argv_blob[16], arcs_argv_blob_end[1];
unsigned char arcs_argv_arr[16], arcs_envp_arr[16];
void jump_kernel(unsigned int a, char **b, char **c, unsigned int d) { (void)a; (void)b; (void)c; (void)d; }
void newport_init(void) { }

char *stub_getenv(const char *name);
long  stub_write(long h, const char *buf, unsigned long len, unsigned long *cnt);

unsigned long nondet_ulong(void);
char nondet_char(void);

/* getenv: a symbolic, nul-terminated name must never read out of bounds, and the
 * result is always one of the two strings the firmware owns. */
void harness_getenv(void) {
  char name[6];
  for (int i = 0; i < 5; i++) {
    name[i] = nondet_char();
  }
  name[5] = 0;                         /* guaranteed terminator inside the buffer */
  char *r = stub_getenv(name);
  __CPROVER_assert(r == monitor_str || r == eaddr_str, "getenv returns an owned string");
}

/* Write: reads exactly len bytes of buf and reports len back; symbolic len bounded. */
void harness_write(void) {
  char buf[8];
  for (int i = 0; i < 8; i++) {
    buf[i] = nondet_char();
  }
  unsigned long len = nondet_ulong();
  __CPROVER_assume(len <= 8);          /* caller passes a valid buffer/length */
  unsigned long cnt = 0;
  long rc = stub_write(0, buf, len, &cnt);
  __CPROVER_assert(rc == 0 && cnt == len, "Write consumes exactly len bytes");
}
