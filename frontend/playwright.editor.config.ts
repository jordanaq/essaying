import { defineConfig, devices } from "@playwright/test";

// Editor component and app workflows use mocked APIs and need no backend.
const port = Number(process.env.PLAYWRIGHT_FRONTEND_PORT ?? 4176);
const baseURL = `http://127.0.0.1:${port}`;

export default defineConfig({
  testDir: "./e2e",
  testMatch: ["markdown-editor.spec.ts", "editor-app.spec.ts", "essay-directories.spec.ts",
    "grading.spec.ts", "context-validity.spec.ts", "context-mutation.spec.ts", "empty-essay.spec.ts"],
  fullyParallel: false,
  workers: 1,
  use: { baseURL, screenshot: "only-on-failure" },
  webServer: {
    command: `npm run dev -- --host 127.0.0.1 --port ${port} --strictPort`,
    url: baseURL,
    reuseExistingServer: false
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }]
});
