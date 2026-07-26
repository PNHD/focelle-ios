import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

process.env.APP_SHARED_TOKEN ??= "test-token";
process.env.GEMINI_API_KEY ??= "test-key";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          APP_SHARED_TOKEN: "test-token",
          GEMINI_API_KEY: "test-key",
        },
      },
    }),
  ],
});
