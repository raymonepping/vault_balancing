// playwright.config.ts: the live stack, a real browser. Only the
// two-primaries state is a fixture (the real drill never reaches it).
import { defineConfig, devices } from '@playwright/test';
import { labCaSpkiArg, urls } from './helpers/env';

export default defineConfig({
  testDir: './tests',
  fullyParallel: false,
  workers: 1, // one lab, one drill at a time
  timeout: 120_000,
  expect: { timeout: 15_000 },
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    ...devices['Desktop Chrome'],
    baseURL: urls.web,
    viewport: { width: 1440, height: 900 },
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    launchOptions: { args: [labCaSpkiArg()] },
  },
});
