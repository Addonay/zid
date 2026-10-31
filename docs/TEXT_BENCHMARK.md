# Synthetic text-engine benchmark

```sh
zig build-exe src/bench_text.zig -O ReleaseFast -femit-bin=/tmp/zid-text-bench
/usr/bin/time -v /tmp/zid-text-bench
```

The deterministic workload owns an 8 MiB ASCII file with 128-byte lines, inserts
20,000 characters at the midpoint with word boundaries every eight characters,
undoes and redoes the retained history, then makes 2,000 randomly positioned
single-byte replacements. It does not load SDL or include rendering or disk I/O.

One run on 2026-11-01 with Zig 0.17.0 ReleaseFast: initialization 7.72 ms, typing
34.23 ms, undo/redo of 1,000 retained entries 32 microseconds, random edits 18.42 ms.
Final storage contained 6,049 pieces and 8,408,608 text bytes; process peak RSS
was 12,180 KiB. History eviction means undo reaches the retained-history floor,
not the original document. This synthetic run does not establish interactive
latency, Unicode shaping performance, long-session memory bounds or real editing
trace performance. The append-only add store still needs compaction.
