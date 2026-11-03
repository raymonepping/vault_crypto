import { test, expect } from '@playwright/test';
import { api, unique } from '../helpers/api';

test('find a fresh ML-DSA leaf in the inventory and revoke it', async ({ page }) => {
  const cn = `${unique('pw')}.lab.local`;
  const r = await api<{ leaf: { serial: string } }>('/api/pki/issue', { chain: 'pqc', cn });
  await page.goto('/#/lifecycle');
  await page.getByLabel('Search by common name or serial').fill(cn);
  const row = page.getByTestId(`cert-${r.leaf.serial}`);
  await expect(row).toContainText('ML-DSA-44');
  await expect(row).toContainText('valid');
  await row.getByRole('button', { name: 'Revoke' }).click();
  const dialog = page.getByRole('dialog', { name: 'Revoke this certificate?' });
  await expect(dialog).toContainText(cn);
  await dialog.getByRole('button', { name: 'Revoke' }).click();
  await expect(row).toContainText('revoked');
  await expect(page.getByRole('region', { name: 'Certificate revocation lists' })).toContainText('ML-DSA-65');
});

test('filters narrow the inventory by family', async ({ page }) => {
  await api('/api/pki/issue', { chain: 'classic', cn: `${unique('pw-classic')}.lab.local` });
  await page.goto('/#/lifecycle');
  await page.getByLabel('Algorithm family').selectOption('classic');
  const rows = page.getByRole('table', { name: 'Certificates' }).getByRole('row');
  await expect(rows.nth(1)).toContainText('EC P-');
  await expect(page.getByRole('table', { name: 'Certificates' }).locator('.fam--pq')).toHaveCount(0);
});
