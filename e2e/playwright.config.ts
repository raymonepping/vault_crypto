// playwright.config.ts — the live stack, a real browser, nothing mocked.
import { defineConfig, devices } from '@playwright/test';
import { intermediateSpkiArg, urls } from './helpers/env';

export default defineConfig({
  testDir: './tests',
  globalSetup: './global-setup.ts',
  fullyParallel: false,
  workers: 1, // journeys share one Vault and its demo keys
  timeout: 60_000,
  expect: { timeout: 15_000 },
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    ...devices['Desktop Chrome'],
    baseURL: urls.web,
    viewport: { width: 1440, height: 900 },
    trace: 'retain-on-failure',
    // Signed in as olga by global-setup (all four groups). Tests that need
    // another person or none open their own context.
    storageState: '.auth/olga.json',
    screenshot: 'only-on-failure',
    // Trust the pki-classic-int intermediate's key, never ignoreHTTPSErrors.
    launchOptions: { args: [intermediateSpkiArg()] },
  },
});
