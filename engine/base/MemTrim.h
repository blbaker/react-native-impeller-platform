#pragma once

// memory audit (2026-11-05): glibc kept freed memory resident. Its mmap
// threshold rises to the largest block ever freed (a 3.7 MB video frame, an
// 8.3 MB web frame, a decoded image), the trim threshold to twice that, and
// every arena (up to 8 per core) then keeps that much after a free. Nothing in
// the engine ever handed pages back. This pins the policy and trims after the
// moments a big owner lets go. No-ops outside glibc (Android, darwin, win32).

#include <functional>
#include <string>

namespace rni::memtrim {

// First thing in main, before any thread exists. Caps arenas and pins the
// mmap/trim thresholds, unless MALLOC_* / GLIBC_TUNABLES already chose, or
// RNI_MALLOC_POLICY=off. Prints one `malloc_policy` line either way.
void Configure();

// Any thread: something big was just freed (a video player, a web view, a
// burst of image decodes). Requests inside one quiet period (1.5 s) coalesce
// into ONE malloc_trim(0) on the memtrim thread, which logs `mem_trim`.
void Request(const char* why);

// Extra `key=value ...` text for the mem_stats line (the image cache lives in
// fabric, which base cannot include). Set once by the host.
void SetStatsExtra(std::function<std::string()> extra);

// RNI_MEM_STATS_SEC=N (N > 0): one `mem_stats` line every N seconds, plus one
// after every trim. Off by default.
void StartStats();

}  // namespace rni::memtrim
