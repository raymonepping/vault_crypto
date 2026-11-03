import { test, expect } from '@playwright/test';

test('FF1: shapes kept, checksums honest, decode equal, rewrap, decode equal again', async ({ page }) => {
  await page.goto('/#/fpe');
  await expect(page.locator('.vg-hero .vg-tile__value').first()).toHaveText('FF1');
  await page.getByRole('button', { name: 'Encode all' }).click();
  const table = page.getByRole('table', { name: 'Fixtures and their FF1 encodings' });
  await expect(table.getByText('kept', { exact: true })).toHaveCount(16);
  await expect(page.getByTestId('fx-iban-1')).toContainText(/NL\d{2}TEST\d{10}/);
  await page.getByRole('button', { name: 'Decode all' }).click();
  await expect(table.getByText('equals the fixture')).toHaveCount(16);
  await page.getByRole('button', { name: /Rewrap cards ccn-legacy → ccn-2026/ }).click();
  await expect(page.getByText(/One batch call moved 6 card numbers/)).toBeVisible();
  await expect(page.getByTestId('fx-card-1')).toContainText('ccn-2026');
  await expect(page.getByTestId('fx-card-1')).toContainText('was');
  await page.getByRole('button', { name: 'Decode all' }).click();
  await expect(table.getByText('equals the fixture')).toHaveCount(16);
});
