// @shots — refresh docs/screenshots (make screenshots). Not part of make test-ui.
import { test, expect } from '@playwright/test';
import path from 'node:path';
import { ROOT } from '../helpers/env';

const OUT = path.join(ROOT, 'docs/screenshots');

async function prepare(page: import('@playwright/test').Page, id: string) {
  await page.goto(`/#/${id}`);
  await expect(page.locator('.vg-hero')).toBeVisible();
  if (id === 'pki') {
    // The chains load after the hero: wait for both buttons before collecting them.
    await expect(page.getByRole('button', { name: /^Issue a leaf/ })).toHaveCount(2);
    for (const b of await page.getByRole('button', { name: /^Issue a leaf/ }).all()) await b.click();
    await expect(page.getByRole('table', { name: 'Size comparison in bytes' })).toBeVisible();
  }
  if (id === 'agility') {
    await page.getByRole('region', { name: /orders-signing/ }).getByRole('button', { name: 'Sign', exact: true }).click();
    await page.getByRole('region', { name: /orders-signing/ }).getByRole('button', { name: 'Verify every signature now' }).click();
  }
  if (id === 'fpe') {
    await page.getByRole('button', { name: 'Encode all' }).click();
    await page.getByRole('button', { name: 'Decode all' }).click();
  }
  await page.waitForLoadState('networkidle');
  // A full-page capture paints sticky and fixed elements where the viewport
  // happened to be; unstick them for the docs (screenshot context only).
  await page.addStyleTag({ content: '.topbar-wrap{position:static!important}.vg-sidebar{position:static!important;height:auto!important;min-height:100%!important}.skip-link{display:none!important}' });
}

for (const id of ['overview', 'pki', 'agility', 'fpe', 'lifecycle']) {
  test(`@shots ${id}`, async ({ browser }) => {
    for (const vp of [{ n: 'desktop', width: 1440, height: 900 }, { n: 'phone', width: 390, height: 844 }]) {
      // Signed in as olga (global-setup), so the rooms show their content.
      const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, bypassCSP: true, storageState: path.join(__dirname, '../.auth/olga.json') });
      const page = await ctx.newPage();
      await prepare(page, id);
      await page.screenshot({ path: path.join(OUT, `${id}${vp.n === 'phone' ? '-phone' : ''}.png`), fullPage: true });
      await ctx.close();
    }
  });
}
