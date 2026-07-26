import { handleAnalyze } from "./analyze";

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health" && request.method === "GET") {
      return Response.json({ ok: true }, {
        headers: { "cache-control": "no-store" },
      });
    }
    if (url.pathname !== "/v1/analyze") {
      return Response.json(
        { ok: false, error: { code: "NOT_FOUND" } },
        { status: 404, headers: { "cache-control": "no-store" } },
      );
    }
    return handleAnalyze(request, env);
  },
} satisfies ExportedHandler<Env>;
