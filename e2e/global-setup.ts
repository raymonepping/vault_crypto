// global-setup.ts — fail fast, with the make target that fixes it, when the
// stack is not up; then sign in once as olga (all four groups) through the
// real Keycloak form and keep the session for every journey.
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { chromium } from '@playwright/test';
import { intermediateSpkiArg, urls } from './helpers/env';
import { signIn } from './helpers/auth';

const CORE = ['vcry-vault-s', 'vcry-vault-1', 'vcry-rotator', 'vcry-vault-agent', 'vcry-tls-agent', 'vcry-api', 'vcry-web', 'vcry-openldap', 'vcry-keycloak'];
export const STORAGE = path.join(__dirname, '.auth/olga.json');

export default async function globalSetup(): Promise<void> {
  const running = execFileSync('podman', ['ps', '--filter', 'name=^vcry-', '--format', '{{.Names}}'], { encoding: 'utf8' }).split('\n');
  const down = CORE.filter((c) => !running.includes(c));
  if (down.length) throw new Error(`not running: ${down.join(', ')} — run "make up" (or "make bootstrap" on a fresh machine)`);
  const r = await fetch(`${urls.api}/api/health`, { signal: AbortSignal.timeout(10_000) });
  const h = await r.json();
  if (!h.ok) throw new Error(`api /api/health is not ok: ${JSON.stringify(h)} — run "make doctor"`);

  const browser = await chromium.launch({ args: [intermediateSpkiArg()] });
  const page = await browser.newPage();
  await signIn(page, 'olga');
  await page.context().storageState({ path: STORAGE });
  await browser.close();
}
