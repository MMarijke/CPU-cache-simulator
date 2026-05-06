# cache_sim — CPU Cache Simulator

A single-file C++17 cache simulator that models realistic CPU cache behaviour
from a memory access trace, producing accurate hit/miss/eviction statistics.

---

## Quick Start

```bash
# Build
make

# Run against a Valgrind-style trace
./cache_sim -s 32768 -b 64 -a 4 -r lru trace.txt

# Generate synthetic traces for testing
python3 gen_trace.py mixed 100000 > trace.txt

# Run the full test suite
make test
```

---

## Usage

```
./cache_sim [options] <trace_file>

Options:
  -s <bytes>   Cache size in bytes         [default: 32768  (32 KiB)]
  -b <bytes>   Block (cache line) size     [default: 64 B]
  -a <ways>    Associativity               [default: 4-way]
  -r <policy>  Replacement: lru|lfu|fifo|rand  [default: lru]
  -w <policy>  Write: wb | wt             [default: wb]
               wb = write-back + write-allocate
               wt = write-through + no-allocate
  -o <file>    Write report to file
  -q           Quiet (suppress progress line)
  -h           Help
```

All size/associativity parameters must be powers of 2.

---

## Trace Format

The simulator accepts the standard Valgrind lackey / Dinero IV format:

```
# comment lines are ignored
I 0400d7d4,8      # instruction fetch (treated as read)
L 04f6b868,8      # load  (read)
S 04227124,4      # store (write)
M 04227124,4      # modify = read then write (two accesses)
```

Plain `R`/`W` prefixes are also accepted for simple traces.
The `,size` suffix is parsed but ignored — the simulator operates at
address-level granularity, not byte-level.

---

## Example Output

```
------------------------------------------------------
  CPU CACHE SIMULATOR — RESULTS
------------------------------------------------------

  CONFIGURATION
  --------------------------------
  Cache size:                       32768 B  (32 KiB)
  Block size:                       64 B
  Associativity:                    4-way
  Number of sets:                   128
  Replacement:                      LRU
  Write policy:                     Write-back + Write-allocate
  Address bits — offset:          6
  Address bits — index:           7
  Address bits — tag:             51

  STATISTICS
  --------------------------------
  Total accesses:                          50000
    Reads:                                 50000
    Writes:                                    0
  Hits (total):                            49936
  Misses (total):                             64
  Evictions:                                   0
  Hit rate:                              99.872%
  Miss rate:                              0.128%
------------------------------------------------------
```

---

## Cache Architecture

### Address Decomposition

For a 64-bit address, given cache size *C*, block size *B*, and associativity *A*:

```
Number of sets  S = C / (B × A)

Address layout:
  [ tag : 64-offset_bits-index_bits | index : log2(S) | offset : log2(B) ]
```

The index selects the set; the tag is compared against every way in that set;
the offset locates the byte within the block (unused here — we track
block-level presence only).

### Set-Associative Lookup

On each access:
1. Compute `set = (addr >> offset_bits) & (S-1)`.
2. Compare the tag against all *A* valid lines in that set → **hit** or **miss**.
3. On a hit: update metadata (LRU timestamp / LFU frequency).
4. On a miss: select a victim (see below), evict it, fill the new line.

Direct-mapped (A=1) and fully-associative (S=1) are degenerate special cases
handled by the same code path.

### Replacement Policies

| Flag   | Policy | Selection criterion |
|--------|--------|---------------------|
| `lru`  | Least Recently Used  | Line with the lowest `last_used` tick |
| `lfu`  | Least Frequently Used | Line with the lowest access count |
| `fifo` | First-In First-Out   | Line with the lowest `inserted` tick |
| `rand` | Random               | Uniform random among all ways |

Invalid (empty) lines are always chosen before evicting a valid line.

### Write Policies

**Write-back + Write-allocate (default, `wb`)**
- Write hit: mark line dirty, do not write to memory.
- Write miss: allocate a new cache line (fill + mark dirty).
- Eviction of a dirty line increments `dirty_evict` — these require a
  writeback to backing memory in a real system.

**Write-through + No-allocate (`wt`)**
- Write hit: write to cache and to memory simultaneously.
- Write miss: write directly to memory, do NOT allocate a cache line.
- No dirty bits needed; no dirty evictions.

---

## Design Decisions

### Data Layout — Flat 2-D Array

```cpp
std::vector<CacheLine> lines_;  // size = num_sets × associativity
CacheLine* set = &lines_[set_idx * associativity];
```

A single flat allocation with row-major indexing (sets as rows, ways as
columns) is used instead of `vector<vector<CacheLine>>`. This keeps each set's
ways contiguous in memory, improving cache-line utilisation during the inner
hit-check loop and eliminating the pointer-indirection of a 2-D vector.

### Minimal CacheLine Struct (32 bytes)

```cpp
struct CacheLine {
    uint64_t tag;        // 8 bytes
    bool valid, dirty;   // 2 bytes
    uint64_t last_used;  // 8 bytes  (LRU / FIFO reuse)
    uint64_t inserted;   // 8 bytes
    uint32_t freq;       // 4 bytes  (LFU)
};
```

All four replacement policies share the same struct rather than using
virtual dispatch or union trickery. The overhead is negligible (a few extra
bytes per line) and avoids branch-heavy polymorphism on the hot path.

### Hot Path — Zero Allocation

The `Cache::access()` method performs zero dynamic allocation after
construction. The only operations are integer arithmetic, array indexing,
and comparisons — suitable for simulating tens of millions of accesses per
second.

### Single-Pass Streaming Parse

The trace is read line-by-line with `std::getline` into a reused
`std::string`, parsed with `strtoull` (faster than `std::stoi` for hex),
and discarded immediately. Memory usage is O(cache size), not O(trace size).

---

## Trace Generator

`gen_trace.py` produces synthetic traces for benchmarking and sanity-checking:

| Pattern      | Description                              | Expected hit rate |
|--------------|------------------------------------------|-------------------|
| `sequential` | Stride-1 word reads                      | High (spatial locality) |
| `stride`     | Cache-line-strided reads                 | Moderate |
| `random`     | Uniform random over 1 MiB                | Low (no locality) |
| `loop`       | Repeated sweep of small working set      | Very high (temporal locality) |
| `mixed`      | I/L/S/M mix, moderate address space      | Moderate |

```bash
python3 gen_trace.py loop 200000 > my_trace.txt
```

---

## Building

Requires a C++17-capable compiler (GCC ≥ 7, Clang ≥ 5).

```bash
make          # release build (-O2)
make test     # build + run 5 canned scenarios
make clean    # remove binary and generated traces
```

Manual compile:
```bash
g++ -std=c++17 -O2 -o cache_sim cache_sim.cpp
```

No external dependencies.

---

## Files

```
cache_sim/
├── cache_sim.cpp    Single-file simulator (~350 lines)
├── gen_trace.py     Synthetic trace generator
├── Makefile
└── README.md
```
