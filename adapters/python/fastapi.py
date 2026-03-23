import json
import os
import subprocess
from collections.abc import Callable, Sequence
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Query
from fastapi.concurrency import run_in_threadpool


def install_fastapi_profiler(
    app: FastAPI,
    *,
    profiler_bin: str = "agentic-profiler",
    route: str = "/__agentic/profile",
    token: str,
    pid_provider: Callable[[], int] | None = None,
    profiler_args: Sequence[str] = (),
) -> None:
    if not token:
        raise ValueError("token is required for the FastAPI profiler endpoint")

    @app.post(route)
    async def profile_current_process(
        duration_ms: int = Query(default=2000, ge=250, le=30000),
        x_agentic_profiler_token: str | None = Header(default=None),
    ) -> dict[str, Any]:
        if x_agentic_profiler_token != token:
            raise HTTPException(status_code=403, detail="invalid profiler token")

        return await run_in_threadpool(
            _profile_pid,
            profiler_bin,
            pid_provider() if pid_provider is not None else os.getpid(),
            duration_ms,
            profiler_args,
        )


def _profile_pid(
    profiler_bin: str,
    pid: int,
    duration_ms: int,
    profiler_args: Sequence[str],
) -> dict[str, Any]:
    command = [
        profiler_bin,
        "--json",
        "run",
        "--duration-ms",
        str(duration_ms),
        *profiler_args,
        "--pid",
        str(pid),
    ]

    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        stderr = result.stderr.strip() or result.stdout.strip() or "profiler command failed"
        raise HTTPException(status_code=500, detail=stderr)

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=500, detail=f"invalid profiler JSON: {exc}") from exc
