# Managed Mode

Managed mode is the long-running runtime surface for `agentic-profiler`.

It should exist alongside one-shot commands:

- `run`: bounded profile against a launched process or an attached PID
- `crash`: bounded crash supervision and report capture
- `manage`: keep an application under profiler control while it continues serving traffic

## Goal

Managed mode should make servers, workers, and framework apps easy to profile without forcing operators to:

- look up PIDs manually
- guess which subprocess is the hot one
- accidentally kill a production-like service after a bounded sample

## Proposed CLI

```bash
agentic-profiler manage bun -- bun run src/server.ts
agentic-profiler manage python -- uv run app.py
agentic-profiler manage node -- node server.js
agentic-profiler manage zig -- ./zig-out/bin/server
```

## Managed Responsibilities

The `manage` process should:

1. launch the target runtime as a supervised root process
2. track child processes and worker trees
3. expose a local control surface for bounded profiling and crash capture
4. keep the application alive after routine profile requests
5. emit the same artifact schema used by `run` and `crash`

## Control Surface

The first useful control contract can stay very small:

- `profile`: capture a bounded CPU profile for `n` milliseconds
- `crash-status`: return the latest crash artifact if a child died
- `children`: list the current tracked process tree

That control surface can be exposed through:

- a local Unix socket
- a loopback-only HTTP endpoint
- framework adapters that shell out to the CLI today and talk to the control socket later

## Framework Fit

Framework adapters like FastAPI and Bun should stay thin even after managed mode exists.

They should mainly:

1. authenticate a request
2. ask the managed profiler runtime for a bounded profile
3. return the artifact in a framework-native response

That keeps framework code simple while letting `manage` own process trees, workers, and runtime-specific supervision.
