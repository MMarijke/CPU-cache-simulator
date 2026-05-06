CXX      := g++
CXXFLAGS := -std=c++17 -O2 -Wall -Wextra -pedantic

TARGET   := cache_sim
SRC      := cache_sim.cpp

.PHONY: all clean test

all: $(TARGET)

$(TARGET): $(SRC)
	$(CXX) $(CXXFLAGS) -o $@ $<

test: $(TARGET)
	@echo "\n=== Generating traces ==="
	python3 gen_trace.py sequential 50000 > trace_seq.txt
	python3 gen_trace.py random     50000 > trace_rand.txt
	python3 gen_trace.py loop       50000 > trace_loop.txt
	python3 gen_trace.py mixed      50000 > trace_mixed.txt

	@echo "\n=== 32KiB 4-way LRU (sequential) ==="
	./$(TARGET) -s 32768 -b 64 -a 4 -r lru trace_seq.txt

	@echo "\n=== 32KiB 4-way LRU (random) ==="
	./$(TARGET) -s 32768 -b 64 -a 4 -r lru trace_rand.txt

	@echo "\n=== 32KiB 4-way LRU (loop / high hit rate) ==="
	./$(TARGET) -s 32768 -b 64 -a 4 -r lru trace_loop.txt

	@echo "\n=== 4KiB direct-mapped FIFO (mixed) ==="
	./$(TARGET) -s 4096 -b 32 -a 1 -r fifo trace_mixed.txt

	@echo "\n=== 64KiB 8-way LFU write-through (mixed) ==="
	./$(TARGET) -s 65536 -b 64 -a 8 -r lfu -w wt trace_mixed.txt

clean:
	rm -f $(TARGET) trace_*.txt
