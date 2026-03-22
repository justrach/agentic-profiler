# zigprofiler

An agent-first profiler and debugging toolkit for Zig.

## One-liner

`zigprofiler` is a CLI for answering the questions Zig developers actually have when performance or crashes go sideways:

- Where is time going in this binary?
- Which allocator paths are creating churn or leaks?
- Why did this process crash, and what was the likely Zig-level cause?
- Did this change make the program faster or slower?

Existing tooling can often collect low-level signals. The gap is interpretation. Zig developers still end up translating raw stacks, symbols, allocator events, and crash dumps back into source-level intent by hand. `zigprofiler` exists to close that gap.

That applies to crashes too: a fault report should still be useful even if the user never collected a profile beforehand.

## Thesis

General-purpose profilers are built for systems code in the abstract. `zigprofiler` is built for Zig code specifically.

That means:

- Source-level output that points back to Zig files, functions, and lines instead of dumping opaque runtime frames.
- Tooling that understands Zig patterns such as allocators, error unions, optionals, slices, and cross-language C boundaries.
- Structured output that AI agents, CI systems, and custom dashboards can consume directly.

The goal is not to replace `perf`, Instruments, Valgrind, or Tracy at the kernel/runtime layer. The goal is to sit above them when needed, integrate with platform-specific collection mechanisms, and present results in a form that is useful to Zig developers immediately.

## The Problem

Profiling and debugging Zig code today is still too fragmented.

- CPU profiling often drops you into assembly-heavy or C-oriented stacks that are tedious to map back to Zig code.
- Memory investigation is split between allocator-specific instrumentation, leak detection, and ad hoc logging.
- Crash analysis gives you a stack trace, but not a focused explanation of likely Zig-level failure modes.
- Cross-language code paths, especially Zig called from Python or other runtimes through C ABI boundaries, are hard to reason about end to end.
- None of the above tools are designed to produce deterministic, machine-parseable summaries for agent workflows.

This is especially painful for teams shipping high-performance Zig libraries, CLIs, servers, or language bindings. The data may exist, but the human still has to perform the synthesis.

## Product Goal

Build a single CLI that can do four jobs well:

1. Profile CPU time in a Zig-aware way.
2. Track allocator behavior and memory pressure.
3. Turn faults into actionable crash reports.
4. Compare benchmark and profile outputs over time.

If the tool cannot make the first debugging or optimization decision easier, it is not finished.

## Non-goals

`zigprofiler` should not try to become:

- A full interactive debugger replacement for LLDB or GDB.
- A full tracing platform with distributed systems concerns.
- A giant GUI application.
- A generic profiler for every language under the sun in v1.

The right shape is a sharp CLI with excellent textual and JSON output, plus optional visualization artifacts like flamegraphs.

## User Experience

The interface should feel obvious:

```bash
zigprofiler run ./zig-out/bin/app
zigprofiler mem ./zig-out/bin/app
zigprofiler crash ./zig-out/bin/app
zigprofiler bench ./zig-out/bin/app
zigprofiler diff baseline.json candidate.json
```

Every command should support:

- Human-readable terminal output by default.
- `--json` for machine consumption.
- Stable exit codes for CI and agent workflows.
- Clear separation between collection, analysis, and rendering.

## Core Commands

### `zigprofiler run`

CPU profiler for answering “where is time going?”

Target output:

- Top functions by self time and total time.
- Hot lines and scopes in Zig source.
- Call stacks suitable for flamegraph generation.
- Optional comparison against a previous profile.

Example:

```json
{
  "kind": "cpu_profile",
  "binary": "./zig-out/bin/app",
  "duration_ms": 2000,
  "samples": 48122,
  "functions": [
    {
      "name": "resp.parse",
      "file": "src/resp.zig",
      "line": 42,
      "self_pct": 18.2,
      "total_pct": 31.4,
      "samples": 8758
    },
    {
      "name": "resp.findCRLF",
      "file": "src/resp.zig",
      "line": 15,
      "self_pct": 12.7,
      "total_pct": 12.7,
      "samples": 6112
    }
  ],
  "hotspots": [
    {
      "file": "src/resp.zig",
      "line": 28,
      "label": "simd compare loop",
      "self_pct": 7.1
    }
  ]
}
```

### `zigprofiler mem`

Allocator-aware memory profiler for answering “what is allocating, growing, or leaking?”

Target output:

- Current heap size and peak heap size.
- Allocation throughput and count.
- Largest live allocation sites.
- Leak summary by Zig source location.
- Allocation call stacks suitable for flamegraph generation.

Example:

```text
Peak heap: 4.2 MiB at 1.3s
Live allocations: 1,842
Throughput: 345 MiB across 1,234,567 allocs

Top live sites
  2.1 MiB  src/resp.zig:88   parseArray
  1.8 MiB  src/client.zig:54 readResponse
  0.3 MiB  src/main.zig:21   py_parse_resp

Leaks
  clean
```

### `zigprofiler crash`

Crash and fault analyzer for answering “why did this die?”

Target output:

- Standalone post-mortem analysis, even when no prior profile exists.
- Fault signal and address.
- Symbolized stack trace.
- Register dump with context where possible.
- Nearby memory mapping information.
- Heuristic hints for likely Zig-level causes such as null optional dereference, bounds violation, invalid enum tag, or use-after-free.

Example:

```text
SIGSEGV at 0x0000000000000008

Likely cause
  null optional dereference
  expression: self.stream.?.write(data)

Stack
  src/client.zig:92 RedisClient.send
  src/client.zig:57 RedisClient.command
  src/main.zig:78   py_command

Registers
  x0 = 0x0000000000000000  self.stream
  x1 = 0x000000016fdfc000  data.ptr
```

### `zigprofiler bench`

Benchmark runner for answering “did this get faster, and is the result statistically credible?”

Target output:

- Warmup handling.
- Repeated measurements with confidence intervals.
- Outlier trimming or robust statistics.
- Baseline comparison mode.
- CI-friendly regression thresholds.

Example:

```text
Benchmark            old            new            delta
parse_simple         58 ns ±2%      52 ns ±1%      -10.3%
parse_bulk           61 ns ±3%      55 ns ±2%       -9.8%
pack_SET            104 ns ±1%     101 ns ±1%       -2.9%

Verdict: 2 wins, 0 regressions
```

### `zigprofiler diff`

Comparison engine for profile and benchmark artifacts.

This command matters because “collecting data” is only half the job. Teams need to compare current behavior against a known baseline and make the change legible.

Target output:

- Regressed functions or benchmarks.
- New hotspots introduced by a change.
- Reduced or increased allocation pressure.
- Summary suitable for PR comments or CI annotations.

## Agent-first by design

This tool should be excellent for humans and excellent for agents.

That means every command should emit structured output that is:

- Stable enough to script against.
- Rich enough to support automated diagnosis.
- Compact enough to feed into an LLM without burying the useful signal.

That includes crash-only workflows, where the agent is reasoning from a fault report or crash artifact rather than from a collected performance profile.

Example workflow:

1. An agent runs `zigprofiler run --json ./zig-out/bin/tests`.
2. It identifies that `findCRLF` dominates self time in short-buffer workloads.
3. It runs `zigprofiler bench --json --function findCRLF`.
4. It concludes that the SIMD path only helps above a certain buffer length.
5. It recommends a short-input scalar fast path.
6. The user applies the change and reruns `zigprofiler diff`.

That is the product: not just measurement, but fast synthesis.

## Architecture

The implementation should be modular and brutally practical.

```text
zigprofiler/
├── src/
│   ├── main.zig
│   ├── cmd/
│   │   ├── run.zig
│   │   ├── mem.zig
│   │   ├── crash.zig
│   │   ├── bench.zig
│   │   └── diff.zig
│   ├── core/
│   │   ├── sampler.zig
│   │   ├── allocator_trace.zig
│   │   ├── symbolizer.zig
│   │   ├── dwarf.zig
│   │   ├── crash_analyzer.zig
│   │   └── stats.zig
│   ├── render/
│   │   ├── terminal.zig
│   │   ├── json.zig
│   │   └── flamegraph.zig
│   └── platform/
│       ├── linux.zig
│       └── macos.zig
└── build.zig
```

Key design choices:

- Keep collection platform-specific, but normalize analysis and output in shared Zig code.
- Treat symbolization as a first-class component rather than a post-processing afterthought.
- Model events and summaries with explicit schemas so terminal and JSON renderers consume the same internal data.
- Avoid introducing a runtime-heavy dependency chain that pollutes measurements or complicates distribution.

## Platform strategy

Cross-platform does not mean pretending the platforms are identical.

Initial target:

- Linux
- macOS

Platform-specific collection is acceptable if the user-facing outputs remain consistent. A Linux backend might rely on `perf_event_open`, while macOS may need a different sampling path. That is an implementation detail. The CLI should preserve one mental model.

## What makes it Zig-aware

“Zig-aware” needs to mean something concrete:

- Symbolization that prefers Zig source names and file locations.
- Memory tooling built around allocator usage rather than bolted-on heap snapshots alone.
- Crash heuristics that understand common Zig failure patterns.
- Rendering that respects Zig concepts such as slices, optionals, and error-returning control flow when presenting findings.

If the result could have been produced unchanged by a generic C profiler, then this tool is not differentiated enough.

## v1 scope

The current draft is ambitious. The right v1 is smaller.

Recommended v1:

- `run`
- `bench`
- shared JSON output
- symbolization pipeline
- flamegraph generation

Recommended v1.1:

- `mem`
- `diff`

Recommended v1.2:

- `crash`

Defer for now:

- broad cross-language profiling
- live TUI dashboards
- MCP server mode
- support for many non-Python host languages

That ordering matters. A credible CPU profiler plus comparison workflow is already valuable. A half-built everything-suite is not.

## Roadmap

### Phase 1

- Build CLI skeleton and shared output schema.
- Implement sampling collection on one platform first.
- Symbolize samples back to Zig source.
- Emit terminal summaries and flamegraph-compatible output.
- Add JSON mode and a fixture-driven test corpus.

### Phase 2

- Add benchmarking mode with baseline comparison.
- Add profile diffing and regression reporting.
- Harden symbolization for optimized and partially stripped binaries.
- Validate outputs on real Zig workloads, not toy examples.

### Phase 3

- Add allocator instrumentation and memory summaries.
- Add leak reporting and peak-heap analysis.
- Add profile-memory cross-links where practical.

### Phase 4

- Add crash analysis path.
- Improve heuristic diagnosis for common Zig failure modes.
- Package for easy installation and CI usage.

## Competitive position

`zigprofiler` should complement existing tooling, not pretend it invented profiling.

| Tool | Good at | Weak for Zig teams |
| --- | --- | --- |
| `perf` | Excellent low-level sampling on Linux | Raw and not Zig-oriented |
| Instruments | Strong macOS profiling UI | Apple-specific and not Zig-aware |
| Valgrind | Powerful memory diagnostics | Heavyweight, slower, not Zig-native |
| Tracy | Great instrumentation workflow | Requires integration and is not source-semantic for Zig out of the box |
| `zigprofiler` | Zig-oriented summaries, JSON workflows, agent usability | Must prove collection accuracy and platform maturity |

## Why this should exist

Zig is attracting exactly the kind of engineers who care about:

- predictable performance
- binary size
- memory behavior
- direct systems visibility

Those engineers need tooling that meets them at the same level of precision. A profiler that speaks Zig well is a natural piece of the ecosystem.

The strongest version of `zigprofiler` is not “a profiler written in Zig.” It is “the shortest path from low-level evidence to a correct Zig-specific optimization or debugging decision.”

## Open questions

These are the real questions worth resolving early:

- Which collection backend gets us to a credible first release fastest on Linux?
- What is the minimum viable symbolization pipeline for optimized Zig binaries?
- How invasive can memory instrumentation be before it distorts the workloads users care about?
- Should crash analysis be built in-process, out-of-process, or both?
- What JSON schema boundaries should remain stable from day one?

## Bottom line

The idea is strong. The draft just needs a firmer shape.

`zigprofiler` should be pitched as a focused developer tool for turning low-level runtime evidence into source-level Zig answers, with agent-grade structured output as a core feature rather than a gimmick.

That framing is sharper, more defensible, and much easier to build against.
