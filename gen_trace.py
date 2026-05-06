#!/usr/bin/env python3
"""
gen_trace.py — Generate synthetic memory access traces for cache_sim.

Usage:
    python3 gen_trace.py [pattern] [n_accesses] > trace.txt

Patterns:
    sequential  — stride-1 reads (best-case for prefetchers)
    stride      — stride-8 reads (causes cache misses at small sizes)
    random      — uniform random addresses (worst-case)
    loop        — tight loop over a working set (tests hit rate)
    mixed       — mix of loads, stores, modifies
"""

import sys
import random

pattern     = sys.argv[1] if len(sys.argv) > 1 else "mixed"
n_accesses  = int(sys.argv[2]) if len(sys.argv) > 2 else 100_000
base        = 0x10000000
stride      = 8

print(f"# Synthetic trace: pattern={pattern}  n={n_accesses}")

if pattern == "sequential":
    for i in range(n_accesses):
        print(f"L {base + i * 8:08x},8")

elif pattern == "stride":
    for i in range(n_accesses):
        print(f"L {base + i * 64:08x},8")

elif pattern == "random":
    mem_size = 1 << 20  # 1 MiB address space
    for _ in range(n_accesses):
        op   = random.choice(["L", "S"])
        addr = random.randint(0, mem_size // 8) * 8 + base
        print(f"{op} {addr:08x},8")

elif pattern == "loop":
    working_set = 512   # number of 8-byte words
    addrs = [base + i * 8 for i in range(working_set)]
    for i in range(n_accesses):
        addr = addrs[i % working_set]
        print(f"L {addr:08x},8")

elif pattern == "mixed":
    mem_size = 1 << 18
    ops = ["I", "L", "L", "L", "S", "M"]
    for _ in range(n_accesses):
        op   = random.choice(ops)
        addr = (random.randint(0, mem_size // 8) * 8) + base
        print(f"{op} {addr:08x},8")

else:
    print(f"Unknown pattern: {pattern}", file=sys.stderr)
    sys.exit(1)
