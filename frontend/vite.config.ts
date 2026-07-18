import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

function nowIsoTime(): string {
  return new Date().toISOString();
}

export default defineConfig({
  plugins: [svelte()],
  resolve: {
    conditions: ["browser"]
  },
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test/setup.ts"],
    exclude: ["e2e/**", "node_modules/**", "dist/**"]
  },
  server: {
    port: 4173,
    strictPort: true,
    proxy: {
      "/api": {
        target: "http://127.0.0.1:8080",
        changeOrigin: true,
        configure(proxy) {
          proxy.on("proxyReq", (proxyReq, req) => {
            const method = req.method ?? "GET";
            const path = req.url ?? "";
            console.log(`[frontend-proxy] ${nowIsoTime()} -> ${method} ${path}`);
            const contentType = proxyReq.getHeader("content-type");
            if (contentType) {
              console.log(`[frontend-proxy] ${nowIsoTime()} content-type=${String(contentType)}`);
            }
          });

          proxy.on("proxyRes", (proxyRes, req) => {
            const method = req.method ?? "GET";
            const path = req.url ?? "";
            console.log(
              `[frontend-proxy] ${nowIsoTime()} <- ${method} ${path} ${proxyRes.statusCode ?? "?"}`
            );
          });

          proxy.on("error", (err, req) => {
            const method = req.method ?? "GET";
            const path = req.url ?? "";
            console.error(`[frontend-proxy] ${nowIsoTime()} !! ${method} ${path} ${err.message}`);
          });
        }
      }
    }
  }
});
