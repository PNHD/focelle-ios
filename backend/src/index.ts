import { handleAnalyze } from "./analyze";
import { handleConfig, handleEvent } from "./beta";

export default {
  async fetch(request, env, context): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health" && request.method === "GET") {
      return Response.json({ ok: true }, {
        headers: { "cache-control": "no-store" },
      });
    }
    if (url.pathname === "/v1/analyze") return handleAnalyze(request, env, fetch, context);
    if (url.pathname === "/v1/config") return handleConfig(request, env);
    if (url.pathname === "/v1/events") return handleEvent(request, env);
    return Response.json(
      { ok: false, error: { code: "NOT_FOUND" } },
      { status: 404, headers: { "cache-control": "no-store" } },
    );
  },
} satisfies ExportedHandler<Env>;
