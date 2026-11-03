import { test, expect } from '@playwright/test';

test('overview: four rooms available, Vault Enterprise 2.2 named', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Vault 2.2, crypto agility' })).toBeVisible();
  const rooms = page.getByRole('region', { name: 'Rooms' }).getByRole('article');
  await expect(rooms).toHaveCount(4);
  await expect(rooms.getByText('available', { exact: true })).toHaveCount(4);
  await expect(page.getByRole('status').filter({ hasText: /vault-1 2\.2\.\d+\+ent/ })).toBeVisible();
});

test('every room is one click away, with exactly one ink hero', async ({ page }) => {
  await page.goto('/');
  for (const [link, heading] of [
    ['Quantum PKI', 'What does post-quantum cost a certificate?'],
    ['Crypto agility', 'Same key name, new algorithm'],
    ['FF1', 'Encrypted, and still the right shape'],
    ['Lifecycle', 'Every certificate, both worlds'],
    ['Overview', 'Vault 2.2, crypto agility'],
  ]) {
    await page.locator('.vg-sidebar').getByRole('link', { name: link }).click();
    await expect(page.getByRole('heading', { name: heading })).toBeVisible();
    await expect(page.locator('.vg-hero')).toHaveCount(1);
  }
});

test('phone: no horizontal page scroll, rooms reachable from the top nav', async ({ browser }) => {
  // Not isMobile: a mobile layout viewport widens to fit overflowing content,
  // which would hide exactly the sideways scroll this test looks for.
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await ctx.newPage();
  for (const id of ['overview', 'pki', 'agility', 'fpe', 'lifecycle']) {
    await page.goto(`/#/${id}`);
    await expect(page.locator('.vg-hero')).toBeVisible();
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(300); // tables render after their data arrives
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    expect(overflow, `${id} scrolls sideways by ${overflow}px`).toBeLessThanOrEqual(0);
  }
  await page.locator('.mobile-nav').getByRole('link', { name: 'FF1' }).click();
  await expect(page.getByRole('heading', { name: 'Encrypted, and still the right shape' })).toBeVisible();
  await ctx.close();
});

test('the Vault said drawer shows the raw answers, and Escape closes it', async ({ page }) => {
  await page.goto('/#/pki');
  await page.getByRole('button', { name: 'Issue a leaf' }).first().click();
  await expect(page.getByTestId('leaf-classic')).toBeVisible();
  await page.getByRole('button', { name: /Vault said/ }).click();
  const drawer = page.getByRole('dialog', { name: 'Vault said' });
  await expect(drawer.getByText('POST /api/pki/issue').first()).toBeVisible();
  await expect(drawer.locator('pre').first()).not.toContainText('PRIVATE KEY');
  await page.keyboard.press('Escape');
  await expect(drawer).toBeHidden();
});

test('the sidebar folds to icons, keeps its names for screen readers, and remembers', async ({ page }) => {
  await page.goto('/#/overview');
  const rail = page.locator('.vg-sidebar');
  const toggle = rail.getByRole('button', { name: 'Collapse the sidebar' });
  await expect(toggle).toHaveAttribute('aria-expanded', 'true');
  const open = (await rail.boundingBox())!.width;
  await toggle.click();
  await expect(rail).toHaveClass(/collapsed/);
  await expect.poll(async () => (await rail.boundingBox())!.width).toBeLessThan(open / 2);
  await expect(rail.getByRole('link', { name: 'Quantum PKI' })).toBeVisible();
  await rail.getByRole('link', { name: 'Quantum PKI' }).click();
  await expect(page.getByRole('heading', { name: 'What does post-quantum cost a certificate?' })).toBeVisible();
  await page.reload();
  await expect(page.locator('.vg-sidebar')).toHaveClass(/collapsed/);
  await page.getByRole('button', { name: 'Expand the sidebar' }).click();
  await expect(page.locator('.vg-sidebar')).not.toHaveClass(/collapsed/);
  await expect(page.locator('.vg-sidebar .nav-label', { hasText: 'Quantum PKI' })).toBeVisible();
});

test('footer: signature, motto, verbs and the four links', async ({ page }) => {
  await page.goto('/#/overview');
  const footer = page.getByRole('contentinfo');
  await expect(footer).toContainText('Raymon Epping');
  await expect(footer).toContainText('Change the algorithm, keep the name.');
  for (const w of ['Sign', 'Rotate', 'Rewrap', 'Verify']) await expect(footer.getByText(w, { exact: true })).toBeVisible();
  for (const name of ['GitHub', 'X', 'LinkedIn', 'Medium']) {
    await expect(footer.getByRole('link', { name: `${name} (opens in a new tab)` })).toHaveAttribute('rel', /noopener/);
  }
});
