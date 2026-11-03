import { test, expect } from '@playwright/test';

test('rotate the signing key to a new algorithm: old signatures still verify', async ({ page }) => {
  await page.goto('/#/agility');
  const card = page.getByRole('region', { name: /orders-signing signs orders/ });
  await card.getByLabel('Message to sign').fill('playwright before');
  await card.getByRole('button', { name: 'Sign', exact: true }).click();
  await expect(card.getByRole('table', { name: 'Signatures' })).toContainText('playwright before');
  const before = await card.getByRole('list', { name: 'orders-signing versions' }).getByRole('listitem').count();
  await card.getByRole('button', { name: /^Rotate to (ml-dsa|hybrid)/ }).click();
  await expect(card.getByRole('list', { name: 'orders-signing versions' }).getByRole('listitem')).toHaveCount(before + 1);
  await card.getByLabel('Message to sign').fill('playwright after');
  await card.getByRole('button', { name: 'Sign', exact: true }).click();
  const row = card.getByRole('row').filter({ hasText: 'playwright after' }).last();
  await expect(row.locator('.fam--pq')).toBeVisible();
  await card.getByRole('button', { name: 'Verify every signature now' }).click();
  await expect(card.getByText('invalid')).toHaveCount(0);
  await expect(card.getByRole('row').filter({ hasText: 'playwright before' }).last().getByText(/valid under v\d+/)).toBeVisible();
  await expect(page.locator('.pinned')).toContainText('transit/sign/orders-signing');
});

test('a signing key cannot become an encryption key: Vault says why', async ({ page }) => {
  await page.goto('/#/agility');
  await page.getByTestId('cross-orders-signing').click();
  await expect(page.getByRole('alert').filter({ hasText: 'incompatible algorithm aes256-gcm96' })).toBeVisible();
});

test('encrypt, rotate the cipher, rewrap in one batch, decrypt equal', async ({ page }) => {
  await page.goto('/#/agility');
  const card = page.getByRole('region', { name: /ledger-data encrypts records/ });
  await card.getByLabel('Record to encrypt (synthetic)').fill('playwright ledger line');
  await card.getByRole('button', { name: 'Encrypt', exact: true }).click();
  await expect(card.getByRole('table', { name: 'Encrypted records' })).toBeVisible();
  await card.getByRole('button', { name: /^Rotate to (?!selected)/ }).click();
  await card.getByRole('button', { name: 'Rewrap all to the latest version' }).click();
  await expect(card.getByText(/One batch call rewrapped \d+ record/)).toBeVisible();
  await card.getByRole('button', { name: 'Decrypt all' }).click();
  await expect(card.getByText('playwright ledger line').last()).toBeVisible();
  await expect(card.locator('.vg-pill--rejected')).toHaveCount(0);
});
