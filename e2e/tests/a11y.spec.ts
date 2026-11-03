// WCAG 2.1 AA on every screen, desktop and phone, after real data loaded.
import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

const SCREENS = [
  { id: 'overview', ready: 'Vault 2.2, crypto agility' },
  { id: 'pki', ready: 'Move the ML-DSA issuing key', act: 'Issue a leaf' },
  { id: 'agility', ready: 'Same key name, new algorithm' },
  { id: 'fpe', ready: 'Synthetic fixtures', act: 'Encode all' },
  { id: 'lifecycle', ready: 'Inventory' },
];

for (const vp of [{ name: 'desktop', width: 1440, height: 900 }, { name: 'phone', width: 390, height: 844 }]) {
  for (const s of SCREENS) {
    test(`axe: ${s.id} (${vp.name})`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height });
      await page.goto(`/#/${s.id}`);
      await expect(page.getByRole('heading', { name: s.ready })).toBeVisible();
      if (s.act) {
        await page.getByRole('button', { name: s.act }).first().click();
        await page.waitForLoadState('networkidle');
      }
      const r = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
      const summary = r.violations.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(' | ')}`);
      expect(summary, summary.join('\n')).toEqual([]);
    });
  }
}

// Signed out: the overview and a room's sign-in prompt.
for (const id of ['overview', 'pki']) {
  test(`axe: ${id} (signed out)`, async ({ browser }) => {
    const ctx = await browser.newContext({ storageState: { cookies: [], origins: [] } });
    const page = await ctx.newPage();
    await page.goto(`/#/${id}`);
    await expect(page.getByRole('link', { name: 'Sign in' }).first()).toBeVisible();
    await page.waitForLoadState('networkidle');
    const r = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
    const summary = r.violations.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(' | ')}`);
    expect(summary, summary.join('\n')).toEqual([]);
    await ctx.close();
  });
}
