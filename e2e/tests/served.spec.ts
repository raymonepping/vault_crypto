import { test, expect } from '@playwright/test';
import { servedLeaf } from '../helpers/env';

test('the console is served with a classic ECDSA certificate from pki-classic-int', async () => {
  const leaf = await servedLeaf();
  expect(leaf.subject.OU).toBe('web');
  expect(leaf.issuer.CN).toBe('Vault Crypto Lab Classic Intermediate CA');
  expect(leaf.asn1Curve || leaf.nistCurve).toMatch(/prime256v1|P-256/);
});
