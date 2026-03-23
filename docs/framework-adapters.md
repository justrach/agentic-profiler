# Framework Adapters

The core profiler should stay process-oriented and language-neutral.
Framework adapters should stay thin and do only three things:

1. authenticate a profiling request
2. decide which PID to sample
3. return the profiler artifact in a framework-native response

## FastAPI

The first adapter lives in `adapters/python/fastapi.py`.

It adds a protected debug endpoint that shells out to:

```bash
agentic-profiler run --json --duration-ms <n> --pid <current-process-pid>
```

This keeps the integration simple:

- no embedded profiler runtime in Python
- no protocol design work before the CLI is stable
- the framework can expose profiling behind existing auth, routing, and ops controls

Example:

```python
from fastapi import FastAPI
from adapters.python.fastapi import install_fastapi_profiler

app = FastAPI()

install_fastapi_profiler(
    app,
    profiler_bin="agentic-profiler",
    route="/__agentic/profile",
    token="replace-me",
)
```

Then request a bounded profile:

```bash
curl -X POST \
  -H 'x-agentic-profiler-token: replace-me' \
  'http://127.0.0.1:8000/__agentic/profile?duration_ms=3000'
```

## Bun

The Bun adapter lives in `adapters/js/bun.ts`.

It wraps a Bun `fetch` handler and reserves a protected profiling route:

```ts
import { withBunProfiler } from "./adapters/js/bun";

const app = withBunProfiler(
  (request) => new Response("ok"),
  {
    token: "replace-me",
    route: "/__agentic/profile",
    profilerBin: "agentic-profiler",
  },
);

Bun.serve({
  port: 3000,
  fetch: app,
});
```

Then request a bounded profile:

```bash
curl -X POST \
  -H 'x-agentic-profiler-token: replace-me' \
  'http://127.0.0.1:3000/__agentic/profile?duration_ms=3000'
```

## Next Steps

- add a Node/Express adapter with the same contract
- add managed mode so framework adapters can talk to a long-running profiler supervisor instead of shelling out directly
- move from subprocess shell-out to a local control protocol once the artifact schema settles
- attach request metadata so profiles can be correlated to routes, workers, and background jobs
