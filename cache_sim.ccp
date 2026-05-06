/*
 * cache_sim.cpp — CPU Cache Simulator
 *
 * Design:
 *  - N-way set-associative cache (1 = direct-mapped, N = sets = fully associative)
 *  - Configurable: cache size, block size, associativity, replacement policy
 *  - Replacement policies: LRU, LFU, FIFO, Random
 *  - Write policies: write-back + write-allocate  |  write-through + no-allocate
 *  - Reads a standard Valgrind/Dinero-style trace (I/L/S/M  addr  size)
 */

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <ctime>

#include <iostream>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <unordered_map>
#include <stdexcept>
#include <iomanip>
#include <algorithm>
#include <cassert>

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

using addr_t   = uint64_t;
using tag_t    = uint64_t;
using index_t  = uint32_t;
using offset_t = uint32_t;
using tick_t   = uint64_t;

enum class ReplacementPolicy { LRU, LFU, FIFO, RANDOM };
enum class WritePolicy        { WRITEBACK_ALLOCATE, WRITETHROUGH_NOALLOCATE };
enum class AccessType         { READ, WRITE };

// ─────────────────────────────────────────────────────────────────────────────
// Cache line (one "block" slot inside a set)
// ─────────────────────────────────────────────────────────────────────────────

struct CacheLine {
    tag_t   tag       = 0;
    bool    valid     = false;
    bool    dirty     = false;
    tick_t  last_used = 0;   // for LRU
    tick_t  inserted  = 0;   // for FIFO
    uint32_t freq     = 0;   // for LFU
};

// ─────────────────────────────────────────────────────────────────────────────
// Per-simulation statistics
// ─────────────────────────────────────────────────────────────────────────────

struct Stats {
    uint64_t reads        = 0;
    uint64_t writes       = 0;
    uint64_t read_hits    = 0;
    uint64_t write_hits   = 0;
    uint64_t read_misses  = 0;
    uint64_t write_misses = 0;
    uint64_t evictions    = 0;
    uint64_t dirty_evict  = 0;   // evictions that require writeback

    uint64_t hits()    const { return read_hits  + write_hits;   }
    uint64_t misses()  const { return read_misses + write_misses; }
    uint64_t accesses()const { return reads + writes;             }

    double hit_rate()  const {
        return accesses() ? static_cast<double>(hits()) / accesses() * 100.0 : 0.0;
    }
    double miss_rate() const { return 100.0 - hit_rate(); }
};

// ─────────────────────────────────────────────────────────────────────────────
// Cache configuration
// ─────────────────────────────────────────────────────────────────────────────

struct CacheConfig {
    uint32_t          cache_size_bytes  = 32768;   // 32 KiB default
    uint32_t          block_size_bytes  = 64;
    uint32_t          associativity     = 4;
    ReplacementPolicy replacement       = ReplacementPolicy::LRU;
    WritePolicy       write_policy      = WritePolicy::WRITEBACK_ALLOCATE;

    // Derived (filled by validate())
    uint32_t num_sets    = 0;
    uint32_t offset_bits = 0;
    uint32_t index_bits  = 0;
    uint32_t tag_bits    = 0;

    void validate() {
        if (cache_size_bytes == 0 || block_size_bytes == 0 || associativity == 0)
            throw std::invalid_argument("Cache parameters must be > 0");
        if ((cache_size_bytes  & (cache_size_bytes  - 1)) != 0 ||
            (block_size_bytes  & (block_size_bytes  - 1)) != 0 ||
            (associativity     & (associativity     - 1)) != 0)
            throw std::invalid_argument("Cache size, block size, and associativity must be powers of 2");
        if (block_size_bytes > cache_size_bytes)
            throw std::invalid_argument("Block size cannot exceed cache size");

        num_sets    = cache_size_bytes / (block_size_bytes * associativity);
        if (num_sets == 0)
            throw std::invalid_argument("Configuration results in 0 sets");

        offset_bits = static_cast<uint32_t>(log2(block_size_bytes));
        index_bits  = static_cast<uint32_t>(log2(num_sets));
        tag_bits    = 64 - offset_bits - index_bits;
    }

    index_t index_of(addr_t addr) const {
        if (num_sets == 1) return 0;
        return static_cast<index_t>((addr >> offset_bits) & (num_sets - 1));
    }

    tag_t tag_of(addr_t addr) const {
        return addr >> (offset_bits + index_bits);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// The cache itself
// ─────────────────────────────────────────────────────────────────────────────

class Cache {
public:
    explicit Cache(CacheConfig cfg) : cfg_(std::move(cfg)) {
        cfg_.validate();
        // Flat 2-D array: sets × ways, row-major
        lines_.assign(cfg_.num_sets * cfg_.associativity, CacheLine{});
        srand(static_cast<unsigned>(time(nullptr)));
    }

    // Process one memory access; returns true on hit
    bool access(addr_t addr, AccessType type) {
        const index_t set_idx = cfg_.index_of(addr);
        const tag_t   tag     = cfg_.tag_of(addr);
        const bool    is_write = (type == AccessType::WRITE);

        tick_++;

        if (is_write) stats_.writes++; else stats_.reads++;

        CacheLine* set_begin = &lines_[set_idx * cfg_.associativity];
        const uint32_t ways  = cfg_.associativity;

        // ── Hit check ──────────────────────────────────────────────────────
        for (uint32_t w = 0; w < ways; ++w) {
            CacheLine& line = set_begin[w];
            if (line.valid && line.tag == tag) {
                // HIT
                if (is_write) { stats_.write_hits++;  line.dirty = true; }
                else          { stats_.read_hits++;                       }
                update_on_hit(line);
                return true;
            }
        }

        // ── Miss ───────────────────────────────────────────────────────────
        if (is_write) stats_.write_misses++;
        else          stats_.read_misses++;

        // Write-through / no-allocate: writes on miss don't fill cache
        if (is_write && cfg_.write_policy == WritePolicy::WRITETHROUGH_NOALLOCATE)
            return false;

        // Allocate: find victim
        CacheLine* victim = find_victim(set_begin, ways);
        if (victim->valid) {
            stats_.evictions++;
            if (victim->dirty) stats_.dirty_evict++;
        }

        victim->tag      = tag;
        victim->valid    = true;
        victim->dirty    = is_write && (cfg_.write_policy == WritePolicy::WRITEBACK_ALLOCATE);
        victim->last_used = tick_;
        victim->inserted  = tick_;
        victim->freq      = 1;

        return false;
    }

    const Stats&       stats()  const { return stats_; }
    const CacheConfig& config() const { return cfg_;   }

private:
    // ── Replacement helpers ────────────────────────────────────────────────

    void update_on_hit(CacheLine& line) {
        line.last_used = tick_;
        line.freq++;
    }

    CacheLine* find_victim(CacheLine* set, uint32_t ways) {
        // Prefer invalid slot
        for (uint32_t w = 0; w < ways; ++w)
            if (!set[w].valid) return &set[w];

        switch (cfg_.replacement) {
        case ReplacementPolicy::LRU: {
            CacheLine* victim = &set[0];
            for (uint32_t w = 1; w < ways; ++w)
                if (set[w].last_used < victim->last_used) victim = &set[w];
            return victim;
        }
        case ReplacementPolicy::LFU: {
            CacheLine* victim = &set[0];
            for (uint32_t w = 1; w < ways; ++w)
                if (set[w].freq < victim->freq) victim = &set[w];
            return victim;
        }
        case ReplacementPolicy::FIFO: {
            CacheLine* victim = &set[0];
            for (uint32_t w = 1; w < ways; ++w)
                if (set[w].inserted < victim->inserted) victim = &set[w];
            return victim;
        }
        case ReplacementPolicy::RANDOM:
        default:
            return &set[rand() % ways];
        }
    }

    CacheConfig            cfg_;
    std::vector<CacheLine> lines_;
    Stats                  stats_;
    tick_t                 tick_ = 0;
};

// ─────────────────────────────────────────────────────────────────────────────
// Trace parsing
//
// Supported formats:
//   Valgrind lackey:   I 0400d7d4,8     (instruction)
//                      S 04227124,4     (store/write)
//                      L 04f6b868,8     (load/read)
//                      M 04227124,4     (modify = read then write)
//   Plain hex:         R 0x7fff1234
//                      W 0x7fff1234
// ─────────────────────────────────────────────────────────────────────────────

struct TraceRecord {
    addr_t     addr = 0;
    AccessType type = AccessType::READ;
    bool       is_modify = false; // M → two accesses
};

static bool parse_line(const std::string& raw, TraceRecord& rec) {
    if (raw.empty() || raw[0] == '#' || raw[0] == '=') return false;

    // Skip leading whitespace (Valgrind adds a space for instructions)
    const char* p = raw.c_str();
    while (*p == ' ' || *p == '\t') ++p;
    if (!*p) return false;

    char op = *p++;
    while (*p == ' ' || *p == '\t') ++p;

    // Eat optional "0x" prefix
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) p += 2;

    char* end = nullptr;
    rec.addr = strtoull(p, &end, 16);
    if (end == p) return false;

    switch (op) {
    case 'I': case 'i': case 'L': case 'l': case 'R': case 'r':
        rec.type       = AccessType::READ;
        rec.is_modify  = false;
        break;
    case 'S': case 's': case 'W': case 'w':
        rec.type       = AccessType::WRITE;
        rec.is_modify  = false;
        break;
    case 'M': case 'm':
        rec.type       = AccessType::READ;
        rec.is_modify  = true;
        break;
    default:
        return false;
    }
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Output / reporting
// ─────────────────────────────────────────────────────────────────────────────

static std::string policy_name(ReplacementPolicy p) {
    switch (p) {
    case ReplacementPolicy::LRU:    return "LRU";
    case ReplacementPolicy::LFU:    return "LFU";
    case ReplacementPolicy::FIFO:   return "FIFO";
    case ReplacementPolicy::RANDOM: return "Random";
    }
    return "?";
}

static std::string write_policy_name(WritePolicy p) {
    return p == WritePolicy::WRITEBACK_ALLOCATE
        ? "Write-back + Write-allocate"
        : "Write-through + No-allocate";
}

static void print_report(const Cache& cache, std::ostream& out = std::cout) {
    const CacheConfig& cfg = cache.config();
    const Stats&       st  = cache.stats();

    const int W = 34;
    const std::string sep(W + 20, '-');

    out << "\n" << sep << "\n";
    out << "  CPU CACHE SIMULATOR — RESULTS\n";
    out << sep << "\n\n";

    out << "  CONFIGURATION\n";
    out << "  " << std::string(W - 2, '-') << "\n";
    auto row = [&](const std::string& label, const std::string& val) {
        out << "  " << std::left  << std::setw(W) << label
                    << std::right << val << "\n";
    };
    row("Cache size:",      std::to_string(cfg.cache_size_bytes) + " B  (" +
                            std::to_string(cfg.cache_size_bytes / 1024) + " KiB)");
    row("Block size:",      std::to_string(cfg.block_size_bytes) + " B");
    row("Associativity:",   std::to_string(cfg.associativity) + "-way");
    row("Number of sets:",  std::to_string(cfg.num_sets));
    row("Replacement:",     policy_name(cfg.replacement));
    row("Write policy:",    write_policy_name(cfg.write_policy));
    row("Address bits — offset:", std::to_string(cfg.offset_bits));
    row("Address bits — index:",  std::to_string(cfg.index_bits));
    row("Address bits — tag:",    std::to_string(cfg.tag_bits));

    out << "\n  STATISTICS\n";
    out << "  " << std::string(W - 2, '-') << "\n";

    auto rowu = [&](const std::string& label, uint64_t val) {
        out << "  " << std::left  << std::setw(W) << label
                    << std::right << std::setw(12) << val << "\n";
    };
    auto rowf = [&](const std::string& label, double val, const std::string& suffix = "%") {
        out << "  " << std::left  << std::setw(W) << label
                    << std::right << std::setw(11) << std::fixed << std::setprecision(3)
                    << val << suffix << "\n";
    };

    rowu("Total accesses:",         st.accesses());
    rowu("  Reads:",                st.reads);
    rowu("  Writes:",               st.writes);
    out << "\n";
    rowu("Hits (total):",           st.hits());
    rowu("  Read hits:",            st.read_hits);
    rowu("  Write hits:",           st.write_hits);
    out << "\n";
    rowu("Misses (total):",         st.misses());
    rowu("  Read misses:",          st.read_misses);
    rowu("  Write misses:",         st.write_misses);
    out << "\n";
    rowu("Evictions:",              st.evictions);
    rowu("  Dirty evictions (WB):", st.dirty_evict);
    out << "\n";
    rowf("Hit rate:",               st.hit_rate());
    rowf("Miss rate:",              st.miss_rate());

    out << "\n" << sep << "\n\n";
}

// ─────────────────────────────────────────────────────────────────────────────
// CLI
// ─────────────────────────────────────────────────────────────────────────────

static void usage(const char* prog) {
    std::cerr
        << "Usage: " << prog << " [options] <trace_file>\n\n"
        << "Options:\n"
        << "  -s <size>    Cache size in bytes            [default: 32768]\n"
        << "  -b <size>    Block (line) size in bytes     [default: 64]\n"
        << "  -a <ways>    Associativity (ways per set)   [default: 4]\n"
        << "  -r <policy>  Replacement: lru|lfu|fifo|rand [default: lru]\n"
        << "  -w <policy>  Write: wb (write-back+alloc) | wt (write-through+no-alloc)\n"
        << "               [default: wb]\n"
        << "  -o <file>    Write report to file instead of stdout\n"
        << "  -q           Quiet mode (suppress progress)\n"
        << "  -h           Show this help\n\n"
        << "Trace format (one access per line):\n"
        << "  I/L/R <hex_addr>[,size]   — instruction/load/read\n"
        << "  S/W   <hex_addr>[,size]   — store/write\n"
        << "  M     <hex_addr>[,size]   — modify (read + write)\n"
        << "  Lines starting with # are comments.\n\n"
        << "Examples:\n"
        << "  " << prog << " -s 65536 -b 64 -a 8 -r lru trace.txt\n"
        << "  " << prog << " -s 4096 -b 16 -a 1 -r fifo trace.txt\n";
}

static uint32_t parse_uint(const char* s, const char* opt) {
    char* end;
    long v = strtol(s, &end, 0);
    if (*end || v <= 0)
        throw std::invalid_argument(std::string("Invalid value for ") + opt + ": " + s);
    return static_cast<uint32_t>(v);
}

int main(int argc, char* argv[]) {
    CacheConfig cfg;
    std::string trace_path;
    std::string out_path;
    bool        quiet = false;

    // ── Argument parsing ─────────────────────────────────────────────────
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        auto need = [&]() -> const char* {
            if (i + 1 >= argc) {
                std::cerr << "Option " << arg << " requires an argument\n";
                exit(1);
            }
            return argv[++i];
        };

        if      (arg == "-h" || arg == "--help") { usage(argv[0]); return 0; }
        else if (arg == "-q")                    { quiet = true; }
        else if (arg == "-s")                    { cfg.cache_size_bytes = parse_uint(need(), "-s"); }
        else if (arg == "-b")                    { cfg.block_size_bytes = parse_uint(need(), "-b"); }
        else if (arg == "-a")                    { cfg.associativity    = parse_uint(need(), "-a"); }
        else if (arg == "-o")                    { out_path = need(); }
        else if (arg == "-r") {
            std::string p = need();
            if      (p == "lru")  cfg.replacement = ReplacementPolicy::LRU;
            else if (p == "lfu")  cfg.replacement = ReplacementPolicy::LFU;
            else if (p == "fifo") cfg.replacement = ReplacementPolicy::FIFO;
            else if (p == "rand") cfg.replacement = ReplacementPolicy::RANDOM;
            else { std::cerr << "Unknown replacement policy: " << p << "\n"; return 1; }
        }
        else if (arg == "-w") {
            std::string p = need();
            if      (p == "wb") cfg.write_policy = WritePolicy::WRITEBACK_ALLOCATE;
            else if (p == "wt") cfg.write_policy = WritePolicy::WRITETHROUGH_NOALLOCATE;
            else { std::cerr << "Unknown write policy: " << p << "\n"; return 1; }
        }
        else if (arg[0] == '-') {
            std::cerr << "Unknown option: " << arg << "\n";
            usage(argv[0]); return 1;
        }
        else {
            if (!trace_path.empty()) { std::cerr << "Multiple trace files not supported\n"; return 1; }
            trace_path = arg;
        }
    }

    if (trace_path.empty()) {
        std::cerr << "Error: no trace file specified\n\n";
        usage(argv[0]); return 1;
    }

    // ── Open trace ───────────────────────────────────────────────────────
    std::ifstream fin(trace_path);
    if (!fin) {
        std::cerr << "Cannot open trace file: " << trace_path << "\n";
        return 1;
    }

    // ── Build cache ──────────────────────────────────────────────────────
    Cache* cache_ptr = nullptr;
    try { cfg.validate(); cache_ptr = new Cache(cfg); }
    catch (const std::exception& e) {
        std::cerr << "Error: invalid cache configuration: " << e.what() << "\n";
        return 1;
    }
    Cache& cache = *cache_ptr;

    // ── Simulate ─────────────────────────────────────────────────────────
    if (!quiet)
        std::cerr << "[cache_sim] Processing " << trace_path << " …\n";

    std::string line;
    uint64_t    line_no      = 0;
    uint64_t    skipped      = 0;
    uint64_t    access_count = 0;
    TraceRecord rec;

    while (std::getline(fin, line)) {
        ++line_no;
        if (!parse_line(line, rec)) { ++skipped; continue; }

        cache.access(rec.addr, rec.type);
        ++access_count;

        if (rec.is_modify) {
            cache.access(rec.addr, AccessType::WRITE);
            ++access_count;
        }
    }

    if (!quiet)
        std::cerr << "[cache_sim] " << access_count << " accesses processed ("
                  << skipped << " lines skipped).\n";

    // ── Report ───────────────────────────────────────────────────────────
    if (!out_path.empty()) {
        std::ofstream fout(out_path);
        if (!fout) { std::cerr << "Cannot write to: " << out_path << "\n"; return 1; }
        print_report(cache, fout);
        if (!quiet) std::cerr << "[cache_sim] Report written to " << out_path << "\n";
    } else {
        print_report(cache, std::cout);
    }

    return 0;
}
