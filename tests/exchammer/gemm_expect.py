#!/usr/bin/env python3
"""gemm_expect.py M K REPS -> the checksum gemm_exc.c must produce (both loop orders)."""
import sys
M, K, REPS = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
P = 1024
w = lambda x: ((x + (1 << 31)) & 0xffffffff) - (1 << 31)
A = [[((i * 7 + k * 3) & 0xff) - 128 for k in range(K)] for i in range(M)]
B = [[((k * 5 + j * 11) & 0xff) - 100 for j in range(P)] for k in range(K)]
C = [[0] * P for _ in range(M)]
for _ in range(REPS):
    for i in range(M):
        for j in range(P):
            C[i][j] = w(C[i][j] + sum(A[i][k] * B[k][j] for k in range(K)))
s = 0
for i in range(M):
    for j in range(P):
        s = (s * 31 + (C[i][j] & 0xffffffff)) & 0xffffffff
print(s)
