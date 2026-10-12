// Unit tests for td/telegram/files/FileHashWindow.h (added by patches/0001-parallel-file-hashes.patch).
// Copyright Tucun-app contributors. Distributed under the Boost Software License, Version 1.0.
//
// Build (same language flags as TDLib, CMake/TdSetUpCompiler.cmake, plus sanitizers):
//   g++ -std=c++17 -fno-exceptions -fno-rtti -fsanitize=address,undefined -fno-sanitize-recover=all
//       -I <patched td source root> tests/hash_window_test.cpp -o hash_window_test; ./hash_window_test
#include "td/telegram/files/FileHashWindow.h"

#include <cstdint>
#include <cstdio>
#include <map>
#include <random>
#include <set>
#include <vector>

namespace {

using td::file_hash_window::Counter;
using td::file_hash_window::InflightTable;
using td::file_hash_window::kHashStride;
using td::file_hash_window::pick_offsets;

int failures = 0;
int checks = 0;

#define EXPECT(cond)                                                       \
  do {                                                                     \
    ++checks;                                                              \
    if (!(cond)) {                                                         \
      ++failures;                                                          \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);          \
    }                                                                      \
  } while (0)

constexpr int64_t MiB = kHashStride;

std::vector<int64_t> mib(std::initializer_list<int64_t> values) {
  std::vector<int64_t> result;
  for (auto v : values) {
    result.push_back(v * MiB);
  }
  return result;
}

void first_round_fills_up_to_the_limit_with_a_1_mib_stride() {
  Counter counter;
  auto picked = pick_offsets(0, 64 * MiB, 0, {}, 5, counter);
  EXPECT(picked == mib({0, 1, 2, 3, 4}));
  EXPECT(counter.value() == 5);
}

void skips_covered_and_in_flight_offsets() {
  Counter counter;
  counter.acquire_base();
  counter.acquire_base();  // the two queries below are already in flight and counted
  // prefix 2 MiB is not covered (check_loop only reaches here then); hashes are known up to 4 MiB;
  // queries at 4 and 5 MiB are in flight -> gap at 2 MiB first, then forward from 6 MiB.
  auto picked = pick_offsets(2 * MiB, 64 * MiB, 4 * MiB, mib({4, 5}), 5, counter);
  EXPECT(picked == mib({2, 6, 7}));
  EXPECT(counter.value() == 5);
}

void an_in_flight_query_at_the_prefix_suppresses_the_gap_query() {
  Counter counter;
  counter.acquire_base();
  auto picked = pick_offsets(2 * MiB, 64 * MiB, 2 * MiB, mib({2}), 3, counter);
  EXPECT(picked == mib({3, 4}));
  // an in-flight query that starts 1 MiB before the prefix does not cover the prefix
  Counter counter2;
  counter2.acquire_base();
  auto picked2 = pick_offsets(2 * MiB, 64 * MiB, 2 * MiB, mib({1}), 3, counter2);
  EXPECT(picked2 == mib({2, 3}));
}

void the_gap_at_the_prefix_comes_first_after_a_short_server_answer() {
  Counter counter;
  // The server answered offset 0 with only 12 x 128 KiB; later hashes are known up to 3 MiB.
  const int64_t prefix = 12 * 128 * 1024;
  auto picked = pick_offsets(prefix, 64 * MiB, 3 * MiB, {}, 3, counter);
  EXPECT(picked.size() == 3);
  EXPECT(!picked.empty() && picked[0] == prefix);
  EXPECT(picked.size() == 3 && picked[1] == 3 * MiB && picked[2] == 4 * MiB);
}

void never_asks_past_the_end_of_the_file() {
  {
    Counter counter;
    auto picked = pick_offsets(0, 4 * MiB, 0, {}, 16, counter);
    EXPECT(picked == mib({0, 1, 2, 3}));
    EXPECT(counter.value() == 4);
  }
  {
    Counter counter;
    auto picked = pick_offsets(0, 4 * MiB + 100, 0, {}, 16, counter);
    EXPECT(picked == mib({0, 1, 2, 3, 4}));
  }
  {
    Counter counter;
    auto picked = pick_offsets(0, 0, 0, {}, 16, counter);
    EXPECT(picked.empty());
    EXPECT(counter.value() == 0);
  }
  {
    Counter counter;
    auto picked = pick_offsets(0, 500 * 1024, 0, {}, 16, counter);
    EXPECT(picked == mib({0}));
  }
  {
    Counter counter;
    auto picked = pick_offsets(0, MiB, 0, {}, 16, counter);
    EXPECT(picked == mib({0}));
  }
  {
    Counter counter;
    // prefix already at the end: nothing to ask
    auto picked = pick_offsets(4 * MiB, 4 * MiB, 4 * MiB, {}, 16, counter);
    EXPECT(picked.empty());
  }
}

void limit_one_always_gives_exactly_one_query_per_file() {
  Counter counter;
  auto picked = pick_offsets(0, 64 * MiB, 0, {}, 1, counter);
  EXPECT(picked == mib({0}));
  auto again = pick_offsets(0, 64 * MiB, 0, picked, 1, counter);
  EXPECT(again.empty());
  // a second file still gets its base query
  auto other = pick_offsets(0, 64 * MiB, 0, {}, 1, counter);
  EXPECT(other == mib({0}));
  EXPECT(counter.value() == 2);
}

void the_base_query_is_never_starved_by_the_counter() {
  Counter counter;
  for (int i = 0; i < 40; i++) {
    counter.acquire_base();
  }
  auto picked = pick_offsets(0, 64 * MiB, 0, {}, 8, counter);
  EXPECT(picked == mib({0}));
  // a file that already has a query in flight gets nothing more while the counter is at/over the limit
  auto more = pick_offsets(0, 64 * MiB, 0, picked, 8, counter);
  EXPECT(more.empty());
}

void counter_release_clamps_at_zero() {
  Counter counter;
  EXPECT(!counter.release());
  EXPECT(counter.value() == 0);
  counter.acquire_base();
  EXPECT(counter.try_acquire_extra(2));
  EXPECT(!counter.try_acquire_extra(2));
  EXPECT(counter.value() == 2);
  EXPECT(counter.release());
  EXPECT(counter.release());
  EXPECT(!counter.release());
  EXPECT(counter.value() == 0);
}

void clamp_limit_bounds() {
  using td::file_hash_window::clamp_limit;
  EXPECT(clamp_limit(-5) == 1);
  EXPECT(clamp_limit(0) == 1);
  EXPECT(clamp_limit(1) == 1);
  EXPECT(clamp_limit(8) == 8);
  EXPECT(clamp_limit(32) == 32);
  EXPECT(clamp_limit(33) == 32);
  EXPECT(clamp_limit(int64_t{1} << 40) == 32);
}

void inflight_table_releases_each_token_once() {
  Counter counter;
  InflightTable<int> table;
  counter.acquire_base();
  table.add(11, 0, 1);
  EXPECT(counter.try_acquire_extra(4));
  table.add(12, MiB, 2);
  EXPECT(table.size() == 2);
  int payload = 0;
  EXPECT(table.take(12, counter, &payload));
  EXPECT(payload == 2);
  EXPECT(counter.value() == 1);
  EXPECT(!table.take(12, counter, &payload));  // duplicate answer: no second release
  EXPECT(counter.value() == 1);
  EXPECT(!table.take(99, counter, &payload));  // unknown token
  EXPECT(counter.value() == 1);
  EXPECT(table.offsets() == mib({0}));
  int drained = 0;
  table.drain(counter, [&](int &p) { drained += p; });
  EXPECT(drained == 1);
  EXPECT(table.empty());
  EXPECT(counter.value() == 0);
  table.drain(counter, [&](int &) { drained += 100; });  // draining an empty table changes nothing
  EXPECT(drained == 1);
  EXPECT(counter.value() == 0);
}

// The worst case of the process-wide bound is reachable: one file holds T queries, every other file adds its base.
void the_process_wide_bound_is_t_plus_n_minus_1() {
  const int32_t limit = 8;
  const int files = 4;
  Counter counter;
  auto a = pick_offsets(0, 64 * MiB, 0, {}, limit, counter);
  EXPECT(static_cast<int32_t>(a.size()) == limit);
  int total = static_cast<int>(a.size());
  for (int i = 1; i < files; i++) {
    auto b = pick_offsets(0, 64 * MiB, 0, {}, limit, counter);
    EXPECT(b.size() == 1);
    total += static_cast<int>(b.size());
    auto more = pick_offsets(0, 64 * MiB, 0, b, limit, counter);
    EXPECT(more.empty());
  }
  EXPECT(total == limit + files - 1);
  EXPECT(counter.value() == limit + files - 1);
}

// Several files checked at the same time; answers arrive in random order, some are short (server returns less
// than 1 MiB), some are answered twice. Invariants: process-wide in flight <= T + N - 1, the counter equals the
// sum of the tables, every file still gets checked to the end.
void multi_file_simulation(int32_t limit, int files, uint32_t seed) {
  struct SimFile {
    int64_t size = 0;
    int64_t prefix = 0;
    int64_t covered_end = 0;
    std::map<int64_t, int64_t> covered;  // offset -> end
    InflightTable<int> table;
  };
  std::mt19937 rng(seed);
  Counter counter;
  std::vector<SimFile> sim(files);
  for (int i = 0; i < files; i++) {
    sim[i].size = static_cast<int64_t>(1 + rng() % 24) * MiB + static_cast<int64_t>(rng() % 3) * 128 * 1024;
  }
  uint64_t next_token = 1;
  int max_total = 0;
  int duplicates = 0;
  bool invariant_ok = true;
  bool per_file_ok = true;
  for (int step = 0; step < 200000; step++) {
    bool all_done = true;
    for (auto &f : sim) {
      all_done = all_done && f.prefix >= f.size;
    }
    if (all_done) {
      break;
    }
    auto &f = sim[rng() % files];
    if (f.prefix < f.size && rng() % 2 == 0) {
      auto picked = pick_offsets(f.prefix, f.size, f.covered_end, f.table.offsets(), limit, counter);
      for (auto offset : picked) {
        f.table.add(next_token++, offset, 0);
      }
      if (static_cast<int32_t>(f.table.size()) > limit) {
        per_file_ok = false;
      }
    } else if (!f.table.empty()) {
      // answer one in-flight query (random one)
      auto offsets = f.table.offsets();
      auto tokens = f.table.tokens();
      size_t k = rng() % tokens.size();
      int payload = 0;
      if (!f.table.take(tokens[k], counter, &payload)) {
        invariant_ok = false;
      }
      if (rng() % 7 == 0) {
        duplicates++;
        if (f.table.take(tokens[k], counter, &payload)) {
          invariant_ok = false;
        }
      }
      int64_t offset = offsets[k];
      int64_t len = (rng() % 5 == 0) ? 3 * 128 * 1024 : MiB;
      int64_t end = offset + len < f.size ? offset + len : f.size;
      if (end > offset) {
        auto &slot = f.covered[offset];
        slot = slot > end ? slot : end;
        f.covered_end = f.covered_end > end ? f.covered_end : end;
      }
      // advance the checked prefix over contiguous coverage (what check_loop's comparison does)
      bool moved = true;
      while (moved && f.prefix < f.size) {
        moved = false;
        auto it = f.covered.upper_bound(f.prefix);
        if (it != f.covered.begin()) {
          --it;
          if (it->first <= f.prefix && it->second > f.prefix) {
            f.prefix = it->second;
            moved = true;
          }
        }
      }
    }
    int total = 0;
    for (auto &g : sim) {
      total += static_cast<int>(g.table.size());
    }
    if (total != counter.value() || total > limit + files - 1) {
      invariant_ok = false;
    }
    max_total = max_total > total ? max_total : total;
  }
  bool all_done = true;
  for (auto &f : sim) {
    all_done = all_done && f.prefix >= f.size;
    // a finished file is torn down: remaining in-flight queries are cancelled and released
    f.table.drain(counter, [](int &) {});
  }
  EXPECT(invariant_ok);
  EXPECT(per_file_ok);
  EXPECT(all_done);
  EXPECT(counter.value() == 0);
  EXPECT(duplicates > 0);
  EXPECT(max_total <= limit + files - 1);
  std::printf("INFO simulation T=%d N=%d seed=%u max_in_flight=%d bound=%d\n", limit, files, seed, max_total,
              limit + files - 1);
}

}  // namespace

int main() {
  first_round_fills_up_to_the_limit_with_a_1_mib_stride();
  skips_covered_and_in_flight_offsets();
  an_in_flight_query_at_the_prefix_suppresses_the_gap_query();
  the_gap_at_the_prefix_comes_first_after_a_short_server_answer();
  never_asks_past_the_end_of_the_file();
  limit_one_always_gives_exactly_one_query_per_file();
  the_base_query_is_never_starved_by_the_counter();
  counter_release_clamps_at_zero();
  clamp_limit_bounds();
  inflight_table_releases_each_token_once();
  the_process_wide_bound_is_t_plus_n_minus_1();
  multi_file_simulation(1, 4, 1);
  multi_file_simulation(5, 4, 2);
  multi_file_simulation(8, 4, 3);
  multi_file_simulation(16, 8, 4);
  multi_file_simulation(3, 1, 5);
  std::printf("%s: %d checks, %d failures\n", failures == 0 ? "OK" : "FAILED", checks, failures);
  return failures == 0 ? 0 : 1;
}
