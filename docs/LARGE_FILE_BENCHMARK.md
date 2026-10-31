# Large-file backend benchmark

Run with Zig 0.17.0, separately from the SDL application:

```sh
zig build-exe src/bench_large_file.zig -O ReleaseFast -femit-bin=/tmp/zid-large-bench
/usr/bin/time -v /tmp/zid-large-bench /absolute/path/to/file 67108864
```

The optional final argument limits indexing to that many bytes (default 16 MiB).
The benchmark opens the file, reads up to 64 KiB at each end, then indexes in
1 MiB calls. It consumes the read bytes in a checksum and reports each phase
separately. Index metadata reports allocated capacity, excluding the owned path,
allocator bookkeeping and the fixed 64 KiB read/scan buffers.

## Initial backend baseline, 2026-11-01

On this machine, a sparse 10 GiB file opened in 20–25 microseconds over three runs;
first-and-last-window access took 97–104 microseconds. Indexing the first 64 MiB
took 41.2–41.6 milliseconds and allocated 10,312 bytes of index capacity.
The fixture contains a short line at each end and sparse zero bytes between.

A freshly written 128 MiB text file opened in 23 microseconds; both endpoint reads
took 117 microseconds, and indexing 64 MiB took 50.8 milliseconds. This file repeats
63-byte ASCII lines and was still warm in the page cache. `/usr/bin/time -v`
reported 768 KiB maximum RSS for each standalone benchmark process.

A complete index of the sparse 10 GiB fixture took 6.63 seconds, with 1,373,744
bytes of allocated index capacity and 1,664 KiB maximum process RSS. This was one
run, with no pacing between indexing steps; UI scheduling will change elapsed
index completion time. The index uses chunk summaries rather than one entry per
line, so files containing very many short lines do not need a per-line offset array.

These measurements exclude compiler/build time, SDL, fonts, renderer, application
startup, and editor navigation. Sparse and warm-cache reads do not measure cold
physical-disk throughput. The roadmap's full-editor 10 GiB latency and RSS targets
remain unproven until application integration is measured independently.

## First partial application integration

Debug, SDL offscreen Vulkan, 1100x700, three-frame screenshot mode, one-file fixture
directory: the 10 GiB sparse file reached the `window ready` log at 248 ms and
wrote its screenshot at 344 ms. The complete process took 0.40 s and reached
84,384 KiB maximum RSS. This is a first-view measurement, not an interactive
scrolling test or a fully indexed idle-memory measurement. Screenshot mode does
not run the normal event-loop index scheduler. The 200 ms full-editor target is
not met by this Debug observation.

Opening the same fixture directly under the busy `/tmp` directory also scanned
4,000 project entries and reached `window ready` at 1,102 ms. Keep fixture-directory
contents controlled when comparing startup measurements; project scanning and
GPU/font initialization are part of application startup, unlike the backend test.
