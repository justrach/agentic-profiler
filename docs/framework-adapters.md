# Framework Adapters

The core profiler should stay process-oriented and language-neutral.
Framework adapters should stay thin and do only three things:

1. authenticate a profiling request
2. decide which PID to sample
3. return the profiler artifact in a framework-native response

The adapter should prefer the first viable control path instead of forcing one backend:

1. framework-native hook if the runtime already exposes a safe profiling surface
2. direct `agentic-profiler --json run --pid <pid>` attach
3. managed-mode control socket once `manage` exists

That keeps the first trial simple while still leaving room for runtime-specific upgrades later.

## FastAPI

The first adapter lives in `adapters/python/fastapi.py`.

It adds a protected debug endpoint that shells out to:

```bash
agentic-profiler --json run --duration-ms <n> --pid <current-process-pid>
```

This keeps the integration simple:

- no embedded profiler runtime in Python
- no protocol design work before the CLI is stable
- the framework can expose profiling behind existing auth, routing, and ops controls
- you can override PID selection or pass extra profiler args for worker-based deployments

Example:

```python
import os

from fastapi import FastAPI
from adapters.python.fastapi import install_fastapi_profiler

app = FastAPI()

install_fastapi_profiler(
    app,
    profiler_bin="agentic-profiler",
    route="/__agentic/profile",
    token="replace-me",
    pid_provider=lambda: os.getpid(),
    profiler_args=("--backend", "macos-sample"),
)
```

Then request a bounded profile:

```bash
curl -X POST \
  -H 'x-agentic-profiler-token: replace-me' \
  'http://127.0.0.1:8000/__agentic/profile?duration_ms=3000'
```

## Next Steps

- add a Node/Express adapter with the same contract
- move from subprocess shell-out to a local control protocol once the artifact schema settles
- attach request metadata so profiles can be correlated to routes, workers, and background jobs
- add runtime-specific hooks when they provide a better profile path than raw PID attach
