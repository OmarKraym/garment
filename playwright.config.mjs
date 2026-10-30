// End-to-end tests (development only). Each project starts its own throw-away database + local server.
import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "tests/e2e",
  timeout: 240_000,
  workers: 1,
  reporter: [["list"]],
  use: { actionTimeout: 10_000, locale: "ar", timezoneId: "Africa/Tripoli", acceptDownloads: true, trace: "retain-on-failure" },
  projects: [
    { name: "desktop", use: { browserName: "chromium", viewport: { width: 1280, height: 800 } } },
    { name: "phone-360", use: { browserName: "chromium", viewport: { width: 360, height: 740 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 } },
  ],
});
