/* gemm_exc.c -- int32 GEMM C[M][P] += A[M][K] * B[K][P] with B in the MAPPED kuseg window
 * (one 4 KB page per row, P = 1024), so walking B takes TLB refills mixed into dense
 * load/MAC/store traffic.  Built with exc_start.S (vectors + refill handler).
 *   -DORDER_IJK : inner k-loop walks a B column -> a new page every inner iteration
 *   -DORDER_IKJ : inner j-loop streams a B row  -> refills as k advances (2nd loop)
 *   -DADE_EVERY=n (n>0) : a misaligned `lw $0` every n j-iterations (AdEL, skipped)
 *   -DREPS=r : repeat the whole GEMM r times (C accumulates)
 * main returns 0 iff the checksum matches EXPECT (computed on the host). Build (from tests/):
 *   E=$(./exchammer/gemm_expect.py 4 128 8)
 *   mips-linux-gnu-gcc -march=mips3 -mabi=32 -EB -mno-abicalls -fno-pic -G 0 -O2 -nostdlib \
 *     -nostartfiles -Icommon -DORDER_IJK -DREPS=8 -DEXPECT=${E}u -c exchammer/gemm_exc.c -o g.o
 *   mips-linux-gnu-gcc -march=mips3 -mabi=32 -EB -mno-abicalls -fno-pic -G 0 -Icommon \
 *     -x assembler-with-cpp -c exchammer/exc_start.S -o exchammer/exc_start.o
 *   mips-linux-gnu-ld -T common/link.ld -nostdlib -G 0 -static exchammer/exc_start.o g.o -o g.elf */
#ifndef M
#define M 4
#endif
#ifndef K
#define K 128
#endif
#define P 1024
#ifndef ADE_EVERY
#define ADE_EVERY 0
#endif
#ifndef REPS
#define REPS 1
#endif
typedef int int32_t;
typedef unsigned uint32_t;

static int32_t A[M][K];
static int32_t C[M][P];
#define B ((volatile int32_t (*)[P])0x00400000)

static char misal[64];

static inline void ade(void)
{
  __asm__ volatile("lw $0, 1(%0)" :: "r"(misal) : "memory");
}

int main(void)
{
  for(int i = 0; i < M; i++) {
    for(int k = 0; k < K; k++) {
      A[i][k] = ((i * 7 + k * 3) & 0xff) - 128;
    }
  }
  for(int k = 0; k < K; k++) {
    for(int j = 0; j < P; j++) {
      B[k][j] = ((k * 5 + j * 11) & 0xff) - 100;
    }
  }
  for(int r = 0; r < REPS; r++) {
#if defined(ORDER_IKJ)
    for(int i = 0; i < M; i++) {
      for(int k = 0; k < K; k++) {
        int32_t a = A[i][k];
        for(int j = 0; j < P; j++) {
          C[i][j] += a * B[k][j];
#if ADE_EVERY > 0
          if((j % ADE_EVERY) == 0) {
            ade();
          }
#endif
        }
      }
    }
#else
    for(int i = 0; i < M; i++) {
      for(int j = 0; j < P; j++) {
        int32_t s = C[i][j];
#if ADE_EVERY > 0
        if((j % ADE_EVERY) == 0) {
          ade();
        }
#endif
        for(int k = 0; k < K; k++) {
          s += A[i][k] * B[k][j];
        }
        C[i][j] = s;
      }
    }
#endif
  }
  uint32_t sum = 0;
  for(int i = 0; i < M; i++) {
    for(int j = 0; j < P; j++) {
      sum = sum * 31u + (uint32_t)C[i][j];
    }
  }
  return sum != (uint32_t)EXPECT;
}
