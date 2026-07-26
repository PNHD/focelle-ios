import { handleAnalyze } from "./analyze";
import { handleConfig, handleEvent } from "./beta";
import { handleQuota, handleTestReward } from "./quota";
import { handleStoreNotification, handleStoreTransaction } from "./store";
import { handleAccount, handleAppleLogin } from "./account";

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
    if (url.pathname === "/v1/quota") return handleQuota(request, env);
    if (url.pathname === "/v1/rewards/test") return handleTestReward(request, env);
    if (url.pathname === "/v1/store/transaction") return handleStoreTransaction(request, env);
    if (url.pathname === "/v1/store/notifications") return handleStoreNotification(request, env);
    if (url.pathname === "/v1/account/apple") return handleAppleLogin(request, env);
    if (url.pathname === "/v1/account") return handleAccount(request, env);
    return Response.json(
      { ok: false, error: { code: "NOT_FOUND" } },
      { status: 404, headers: { "cache-control": "no-store" } },
    );
  },
} satisfies ExportedHandler<Env>;
