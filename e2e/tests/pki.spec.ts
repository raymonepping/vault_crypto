import { test, expect } from '@playwright/test';

test('a leaf from each chain: measured, verified twice, ML-DSA larger', async ({ page }) => {
  await page.goto('/#/pki');
  const classic = page.getByRole('region', { name: 'Classic (ECDSA)' });
  const pqc = page.getByRole('region', { name: 'Post-quantum (ML-DSA)' });
  await classic.getByRole('button', { name: 'Issue a leaf' }).click();
  await pqc.getByRole('button', { name: 'Issue a leaf' }).click();
  await expect(page.getByTestId('leaf-classic')).toContainText('EC P-256');
  await expect(page.getByTestId('leaf-pqc')).toContainText('ML-DSA-44');
  await expect(page.getByTestId('leaf-pqc')).toContainText('ML-DSA-65');
  for (const id of ['leaf-classic', 'leaf-pqc']) {
    await expect(page.getByTestId(id).getByText('Node verifies')).toBeVisible();
    await expect(page.getByTestId(id).getByText('OpenSSL verifies')).toBeVisible();
  }
  const hero = page.locator('.vg-hero');
  await expect(hero.locator('.vg-tile').first().locator('.vg-tile__value')).toHaveText(/^\d+\.\d×$/);
  await expect(page.getByRole('table', { name: 'Size comparison in bytes' })).toBeVisible();
});

test('revocation: OCSP for classic, the ML-DSA chain points to its ML-DSA-signed CRL', async ({ page }) => {
  await page.goto('/#/pki');
  for (const name of ['Classic (ECDSA)', 'Post-quantum (ML-DSA)']) {
    const col = page.getByRole('region', { name });
    await col.getByRole('button', { name: 'Issue a leaf' }).click();
    await col.getByRole('button', { name: 'Ask the OCSP responder' }).click();
    await col.getByRole('button', { name: 'Check the CRL' }).click();
  }
  await expect(page.getByTestId('ocsp-classic')).toContainText('good');
  await expect(page.getByTestId('ocsp-classic')).toContainText('the signature verifies');
  await expect(page.getByTestId('ocsp-pqc')).toContainText('no answer');
  await expect(page.getByTestId('ocsp-pqc')).toContainText('responder is off on this mount');
  await expect(page.getByTestId('crl-pqc')).toContainText('not revoked');
  await expect(page.getByTestId('crl-pqc')).toContainText('ML-DSA-65');
  await expect(page.getByTestId('crl-classic')).toContainText('ecdsa-with-SHA256');
});

test('the CA key move card shows what Vault recorded', async ({ page }) => {
  await page.goto('/#/pki');
  const move = page.getByRole('region', { name: 'Move the ML-DSA issuing key' });
  await expect(move).toContainText('make pki-move');
  await expect(move).toContainText('ML-DSA-65');
  await expect(move.getByText(/^(moved|not moved yet)$/)).toBeVisible();
});

test('revoke an ML-DSA leaf here: it appears on the ML-DSA-signed CRL', async ({ page }) => {
  await page.goto('/#/pki');
  const pqc = page.getByRole('region', { name: 'Post-quantum (ML-DSA)' });
  await pqc.getByRole('button', { name: /^Issue a leaf/ }).click();
  await expect(page.getByTestId('leaf-pqc')).toBeVisible();
  await pqc.getByRole('button', { name: /^Revoke this leaf/ }).click();
  const dialog = page.getByRole('dialog', { name: 'Revoke this leaf?' });
  await expect(dialog).toContainText('pqc-orders.lab.local');
  await dialog.getByRole('button', { name: 'Revoke' }).click();
  await expect(pqc.getByRole('status').filter({ hasText: 'Vault rebuilt the CRL at once, signed with ML-DSA-65' })).toBeVisible();
  await expect(page.getByTestId('crl-pqc')).toContainText(/revoked .*ago|revoked in/);
  await expect(page.getByTestId('crl-pqc')).toContainText('This leaf is on');
});

test('classic: after revoking, OCSP answers revoked too', async ({ page }) => {
  await page.goto('/#/pki');
  const classic = page.getByRole('region', { name: 'Classic (ECDSA)' });
  await classic.getByRole('button', { name: /^Issue a leaf/ }).click();
  await classic.getByRole('button', { name: /^Revoke this leaf/ }).click();
  await page.getByRole('dialog', { name: 'Revoke this leaf?' }).getByRole('button', { name: 'Revoke' }).click();
  await expect(page.getByTestId('ocsp-classic')).toContainText('revoked');
  await expect(page.getByTestId('ocsp-classic')).toContainText('the signature verifies');
  await expect(page.getByTestId('crl-classic')).toContainText('This leaf is on');
});
