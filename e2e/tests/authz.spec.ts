// Who may do what: Vault decides, the console only shows it.
import { test, expect } from '@playwright/test';
import { signIn } from '../helpers/auth';

test('signed out: rooms ask you to sign in, the overview stays open', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: { cookies: [], origins: [] } });
  const page = await ctx.newPage();
  await page.goto('/#/overview');
  await expect(page.getByRole('link', { name: 'Sign in' }).first()).toBeVisible();
  await expect(page.getByRole('region', { name: 'Rooms' }).getByRole('article')).toHaveCount(4);
  await page.goto('/#/pki');
  await expect(page.getByText('Sign in to use this room.')).toBeVisible();
  await ctx.close();
});

test('vera (viewer) reads, sees her limits, and Vault refuses an issue', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: { cookies: [], origins: [] } });
  const page = await ctx.newPage();
  await signIn(page, 'vera', 'pki');
  const authority = page.getByRole('region', { name: 'Your authority in this room' });
  await expect(authority).toContainText('vcry-viewer');
  await expect(authority.locator('.vg-pill--healthy')).toContainText('read the chains');
  await expect(authority.locator('.vg-pill--rejected').first()).toContainText('issue');
  const pqc = page.getByRole('region', { name: 'Post-quantum (ML-DSA)' });
  await expect(pqc.getByRole('button', { name: /Issue a leaf.*Vault will refuse/ })).toBeVisible();
  await pqc.getByRole('button', { name: /Issue a leaf/ }).click();
  await expect(pqc.getByRole('alert')).toContainText('permission denied');
  await expect(pqc.getByRole('alert')).toContainText('HTTP 403');
  await expect(authority.locator('.vg-pill--rejected')).toContainText(['revoke']);
  await ctx.close();
});

test('olga signs out through Keycloak and is signed out of the console', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: { cookies: [], origins: [] } });
  const page = await ctx.newPage();
  await signIn(page, 'olga');
  await page.locator('.persona').click();
  await expect(page.getByRole('dialog', { name: 'Signed in' })).toContainText('vcry-key-custodians');
  await page.getByRole('link', { name: 'Sign out' }).click();
  await page.waitForURL(/\/#?\/?$|overview/, { timeout: 30_000 });
  await expect(page.getByRole('link', { name: 'Sign in' }).first()).toBeVisible();
  await ctx.close();
});

test('switching people leaves nothing of the previous one: drawer and rooms start empty', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: { cookies: [], origins: [] } });
  const page = await ctx.newPage();
  await signIn(page, 'olga', 'pki');
  await page.getByRole('region', { name: 'Post-quantum (ML-DSA)' }).getByRole('button', { name: /^Issue a leaf/ }).click();
  await expect(page.getByTestId('leaf-pqc')).toBeVisible();
  await page.locator('.persona').click();
  await page.getByRole('link', { name: 'Sign out' }).click();
  await expect(page.getByRole('link', { name: 'Sign in' }).first()).toBeVisible();
  await signIn(page, 'vera', 'pki');
  await expect(page.getByTestId('leaf-pqc')).toHaveCount(0);
  await page.getByRole('button', { name: /Vault said/ }).click();
  const drawer = page.getByRole('dialog', { name: 'Vault said' });
  await expect(drawer.getByText('POST /api/pki/issue')).toHaveCount(0);
  await expect(page.locator('.persona')).toContainText('Vera');
  await ctx.close();
});
