// helpers/env.ts — where things are. Ports come from the same two files the
// stack reads (config/defaults.conf, overridden by .env).
import fs from 'node:fs';
import path from 'node:path';
import tls from 'node:tls';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';

export const ROOT = path.resolve(__dirname, '../..');

function readEnvFile(file: string): Record<string, string> {
  const out: Record<string, string> = {};
  if (!fs.existsSync(file)) return out;
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const m = /^([A-Z0-9_]+)=(.*)$/.exec(line);
    if (m) out[m[1]] = m[2];
  }
  return out;
}

const merged = { ...readEnvFile(path.join(ROOT, 'config/defaults.conf')), ...readEnvFile(path.join(ROOT, '.env')) };

/** Effective configuration value. Never log VAULT_LICENSE. */
export function conf(name: string): string {
  const v = merged[name];
  if (v === undefined) throw new Error(`configuration value ${name} is not set`);
  return v;
}

export const urls = {
  web: `https://localhost:${conf('VCRY_PORT_WEB')}`,
  api: `http://127.0.0.1:${conf('VCRY_PORT_API')}`,
  vault: `https://127.0.0.1:${conf('VCRY_PORT_VAULT_1')}`,
};

const LAB_CA = path.join(ROOT, 'vault-tls/ca-chain.pem');

/** A PEM from vault-1's unauthenticated PKI endpoints (TLS verified against the lab CA). */
export function vaultPem(p: 'pki-classic-root/ca/pem' | 'pki-classic-int/ca/pem'): string {
  return execFileSync('curl', ['-sf', '--cacert', LAB_CA, `${urls.vault}/v1/${p}`], { encoding: 'utf8', timeout: 10_000 });
}

/**
 * Chromium flag that makes the browser trust exactly the pki-classic-int
 * intermediate's key (Vault's root is not in any browser trust store) instead
 * of ignoring certificate errors. The intermediate is stable; tls-agent
 * re-issues the leaf, so pinning the leaf would break after a renewal.
 */
export function intermediateSpkiArg(): string {
  const der = crypto.createPublicKey(vaultPem('pki-classic-int/ca/pem')).export({ type: 'spki', format: 'der' });
  return `--ignore-certificate-errors-spki-list=${crypto.createHash('sha256').update(der).digest('base64')}`;
}

/**
 * Open a TLS connection to the web UI the strict way: hostname checked,
 * chain verified against Vault's pki-classic-root and nothing else.
 */
export function servedLeaf(): Promise<tls.PeerCertificate> {
  const root = vaultPem('pki-classic-root/ca/pem');
  return new Promise((resolve, reject) => {
    const s = tls.connect({ host: 'localhost', port: Number(conf('VCRY_PORT_WEB')), servername: 'localhost', ca: [root] }, () => {
      const c = s.getPeerCertificate();
      s.end();
      resolve(c);
    });
    s.on('error', reject);
  });
}

/** Node prints serials as upper-case hex; Vault as lower-case, colon-separated. */
export const toVaultSerial = (hex: string) =>
  (hex.length % 2 ? `0${hex}` : hex).toLowerCase().match(/../g)!.join(':');

/** A persona's password, straight from Vault KV (never logged). */
export function personaPassword(user: string): string {
  return execFileSync(path.join(ROOT, 'scripts/identity-secrets.sh'), ['--print', user], { encoding: 'utf8', timeout: 20_000 }).trim();
}

export const keycloak = `http://localhost:${conf('VCRY_PORT_KEYCLOAK')}`;
