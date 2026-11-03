// lib/certs.js — the Lifecycle room: every certificate the three issuing
// mounts hold, with algorithm, issuer, expiry and revocation, and a link to
// the same certificate in Vault's own UI.
import { vault, list, VaultError } from "./vault.js";
import { describe } from "./x509.js";
import { INT_MOUNTS, crl } from "./pki.js";
import { vaultFanout } from "./limit.js";

const MAX_PER_MOUNT = 200;
const VAULT_UI = (process.env.VAULT_UI_URL || "https://localhost:18801").replace(/\/$/, "");

export function mountParam(v) {
  const m = String(v || "");
  if (!INT_MOUNTS.includes(m)) throw new VaultError(400, `mount must be one of: ${INT_MOUNTS.join(", ")}`);
  return m;
}

async function mountInventory(mount) {
  const [serials, revokedList] = await Promise.all([vaultFanout.run(() => list(`${mount}/certs`)), vaultFanout.run(() => list(`${mount}/certs/revoked`))]);
  const revoked = new Set(revokedList);
  // A cap, not a time window: Vault lists serials in serial order, so the
  // cut is by serial, and the response says so (truncated).
  const picked = serials.slice(-MAX_PER_MOUNT);
  // Every certificate read goes through the shared fan-out budget, together
  // with the other mounts and every other request in flight.
  const certs = await vaultFanout.map(picked, async (serial) => {
      const c = (await vault("GET", `${mount}/cert/${serial}`, { auth: false })).data;
      const d = describe(c.certificate);
      return {
        mount,
        serial,
        commonName: d.commonName,
        ou: d.ou,
        ca: d.ca,
        issuer: d.issuerCommonName,
        keyType: d.key.label,
        family: d.key.family,
        signatureAlgorithm: d.signatureAlgorithm.name,
        notBefore: d.notBefore,
        notAfter: d.notAfter,
        expired: new Date(d.notAfter) < new Date(),
        revoked: revoked.has(serial) || Boolean(c.revocation_time),
        revokedAt: c.revocation_time ? new Date(c.revocation_time * 1000).toISOString() : null,
        bytes: d.bytes.der,
        vaultUi: `${VAULT_UI}/ui/vault/secrets/${mount}/pki/certificates/${serial}/details`,
      };
  });
  return { mount, total: serials.length, shown: certs.length, truncated: certs.length < serials.length, certs };
}

export async function inventory() {
  const mounts = await Promise.all(INT_MOUNTS.map(mountInventory));
  const crls = await Promise.all(INT_MOUNTS.map((m) => vaultFanout.run(() => crl(m)).catch((e) => ({ mount: m, available: false, error: e.message }))));
  const certs = mounts.flatMap((m) => m.certs).sort((a, b) => (a.notBefore < b.notBefore ? 1 : -1));
  return {
    totals: Object.fromEntries(mounts.map((m) => [m.mount, { total: m.total, shown: m.shown, truncated: m.truncated }])),
    truncated: mounts.some((m) => m.truncated),
    cap: { perMount: MAX_PER_MOUNT, selection: "the last serials in Vault's list order (by serial, not by date)" },
    crl: crls.map((c) => ({ mount: c.mount, available: c.available, signatureAlgorithm: c.signatureAlgorithm || null, lastUpdate: c.lastUpdate || null, nextUpdate: c.nextUpdate || null, entries: c.revoked?.length ?? null })),
    certs,
    vaultUi: `${VAULT_UI}/ui/vault/secrets/pki-pqc-int/pki/certificates`,
  };
}

// Revoke one certificate; Vault rebuilds the CRL (auto_rebuild is off, so the
// revoke call itself does it).
export async function revoke(mount, serial) {
  const r = await vault("POST", `${mount}/revoke`, { body: { serial_number: serial } });
  const after = await crl(mount).catch(() => null);
  return {
    mount,
    serial,
    revocationTime: r.data?.revocation_time ? new Date(r.data.revocation_time * 1000).toISOString() : null,
    state: r.data?.state || "revoked",
    crl: after ? { lastUpdate: after.lastUpdate, listed: after.revoked?.some((x) => x.serial === serial) || false, signatureAlgorithm: after.signatureAlgorithm } : null,
    warnings: r.warnings || null,
  };
}
