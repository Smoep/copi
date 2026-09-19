# Performance and legacy UI review — 2026-09-19

## Changes

Removed obsolete split-view, segmented collection control, glass menu button,
Search/pane focus-outline classes and their unreachable controller bookkeeping,
outline geometry/animation methods, toolbar menu handlers, old sidebar resize/
anchor handling and unused layout constants. The horizontal filter host still
uses some Sidebar names; it remains active for selection, editing and reordering.
Settings (`ContentView`), Preview (`GlassOverlayView`), persisted compatibility
settings and archived design documents remain intentional. This is a targeted
cleanup, not a claim that every unused declaration in the repository is gone.

Release now explicitly uses `SWIFT_OPTIMIZATION_LEVEL = -O` and
`DEAD_CODE_STRIPPING = YES`. Before this change the actual Swift compiler already
used `-O -whole-module-optimization`, but resolved linker dead-code stripping was
NO. The new linker invocation includes `-dead_strip`. Debug remains unoptimized
and keeps its separate `com.jos.copi.debug` identity. Release retains dSYMs,
whole-module optimization and the existing Apple Development identity; no unsafe
optimization or concurrency settings were introduced.

## Measurements

| Check | Observation |
| --- | --- |
| Installed Release build 14, PID 13517 | `ps` snapshot: 0.3% CPU, RSS 103,888 KB |
| Three-second installed idle stack sample | 86.0 MB footprint; 186.5 MB reported peak; 2,509 of 2,511 main-thread samples waiting in Mach event handling |
| Synthetic Debug interaction, PID 17244 | 34.9 MB footprint; 36.8 MB reported peak; 1,443 of 2,031 main-thread samples in the principal Mach event wait branch |
| Repeated synthetic Favorites → Search → Types → Results path | Three cycles took 3.12 s unprofiled and 2.96 s with a three-second sample; includes driver overhead and deliberate waits, not a latency benchmark |
| Release executable | Installed build 14: 6,161,840 bytes; review build 15: 6,094,896 bytes; reduction 66,944 bytes (about 1.1%) |

The executable comparison combines cleanup, linker configuration and the pending
five-suggestion cap; it does not isolate each contribution. Samples showed no
reproduced busy loop or sustained stall. Active work included normal native/
SwiftUI layout. No runtime speedup or absence of leaks is established by these
short samples. Debug fixture results are not optimized Release benchmarks.
Sampling can itself perturb this app, so elapsed time under attachment is not
used as evidence of a hang.

## Validation and artifacts

- All 14 keyboard-routing and 13 Preview/editor checks passed; off-screen fixture
  rendering completed as an additional diagnostic.
- Signed Debug and Release builds succeeded; strict deep signature verification
  passed. Release was built with `CURRENT_PROJECT_VERSION=15` for identification.
- Pure hover/geometry and ranking suites passed. The synthetic assembly harness
  still passes the five-suggestion cap, deduplication and fallback cases.
- Actual WindowServer captures and native events exercised Light/Dark resting,
  expanded filters, empty/short/full results, first/final rows, animated resizing,
  category drag/reorder, scoped typing, Preview open/close and main Escape.
  Reviewed full-resolution captures retained the intended margins and alignment.
- Local-only diagnostics: `/tmp/copi-performance-installed.sample.txt`,
  `/tmp/copi-performance-active.sample.txt`, `/tmp/copi-clean-ui-qa.log`,
  `/tmp/copi-performance-release.log`, `/tmp/copi-balanced-{dark,light}-*.png`.
  No clipboard payloads, passphrases or keys were collected.
- Debug executable SHA-256:
  `6239e7ed47a5df1026fcdc452c482e99d07da69be08482f543b67761b9c9c07d`.
- Release executable SHA-256:
  `b977bb7def8d5fd3193cf1c43effa6fa2096a8c508a47d4e6bec1102cf15d15b`.

Installed build 14 is unchanged. Review build 15 is built locally, not installed
or published. Large-history search, sustained image/website Preview use, memory
leak analysis and end-to-end physical-hotkey latency remain broader performance
workloads not established by this review.

Final synthetic Debug preview left open: PID 17746, WindowServer 20470,
520 × 300 at (424, 330); `/tmp/copi-clean-review-final.png`.
