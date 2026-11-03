// helpers/auth.ts — sign in the way a person does: the console's "Sign in",
// Keycloak's own login form, back to the console with a session cookie.
import { expect, type Page } from '@playwright/test';
import { keycloak, personaPassword, urls } from './env';

export async function signIn(page: Page, user: string, route = 'overview') {
  await page.goto(`${urls.web}/auth/login?return=${encodeURIComponent(`/#/${route}`)}`);
  await page.waitForURL((u) => u.toString().startsWith(keycloak), { timeout: 30_000 });
  await page.locator('#username').fill(user);
  await page.locator('#password').fill(personaPassword(user));
  await page.locator('#kc-login').click();
  await page.waitForURL((u) => u.toString().startsWith(urls.web), { timeout: 30_000 });
  await expect(page.locator('.persona')).toBeVisible();
}

/** Keycloak access token for scripted API calls (lab-only client vcry-cli). */
export async function bearer(user: string): Promise<string> {
  const r = await fetch(`${keycloak}/realms/vcry/protocol/openid-connect/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'password', client_id: 'vcry-cli', username: user, password: personaPassword(user), scope: 'openid' }),
  });
  const j = await r.json();
  if (!j.access_token) throw new Error(`Keycloak refused ${user}: ${j.error_description || j.error}`);
  return j.access_token;
}
