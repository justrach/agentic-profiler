type BunProfilerOptions = {
  token: string;
  profilerBin?: string;
  route?: string;
  maxDurationMs?: number;
  pid?: number;
  profilerArgs?: string[];
};

type BunHandler = (request: Request) => Response | Promise<Response>;

export function withBunProfiler(
  handler: BunHandler,
  options: BunProfilerOptions,
): BunHandler {
  const route = options.route ?? "/__agentic/profile";
  const profilerBin = options.profilerBin ?? "agentic-profiler";
  const maxDurationMs = options.maxDurationMs ?? 30_000;
  const pid = options.pid ?? Bun.pid;
  const profilerArgs = options.profilerArgs ?? [];

  if (!options.token) {
    throw new Error("token is required for the Bun profiler endpoint");
  }

  return async function profiledHandler(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === route) {
      const token = request.headers.get("x-agentic-profiler-token");
      if (token !== options.token) {
        return Response.json({ detail: "invalid profiler token" }, { status: 403 });
      }

      const rawDuration = url.searchParams.get("duration_ms");
      const durationMs = clampDuration(rawDuration, maxDurationMs);

      const result = Bun.spawnSync({
        cmd: [
          profilerBin,
          "--json",
          "run",
          "--duration-ms",
          String(durationMs),
          ...profilerArgs,
          "--pid",
          String(pid),
        ],
        stdout: "pipe",
        stderr: "pipe",
      });

      if (result.exitCode !== 0) {
        const errorText =
          decodeText(result.stderr) ||
          decodeText(result.stdout) ||
          "profiler command failed";
        return Response.json({ detail: errorText }, { status: 500 });
      }

      try {
        return new Response(result.stdout, {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      } catch (error) {
        return Response.json(
          { detail: `invalid profiler JSON: ${String(error)}` },
          { status: 500 },
        );
      }
    }

    return await handler(request);
  };
}

function clampDuration(rawDuration: string | null, maxDurationMs: number): number {
  const parsed = Number.parseInt(rawDuration ?? "2000", 10);
  if (!Number.isFinite(parsed)) return 2000;
  return Math.max(250, Math.min(maxDurationMs, parsed));
}

function decodeText(value: Uint8Array): string {
  return new TextDecoder().decode(value).trim();
}
