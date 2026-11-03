// lib/pki.js — the Quantum PKI room: two chains side by side, a leaf from
// each, OCSP on each, and the evidence of the ML-DSA CA key move.
import { vault, list, VaultError } from "./vault.js";
import { describe, verifyChain } from "./x509.js";
import * as openssl from "./openssl.js";
import { vaultFanout } from "./limit.js";

// chain id → mounts. `moved` is pki-pqc-next after `make pki-move`: same
// certificate, same key, now held by a different mount.
export const CHAINS = {
  classic: {
    root: "pki-classic-root",
    int: "pki-classic-int",
    label: "Classic (ECDSA)",
    ocsp: true,
  },
  pqc: {
    root: "pki-pqc-root",
    int: "pki-pqc-int",
    label: "Post-quantum (ML-DSA)",
    ocsp: false,
  },
  moved: {
    root: "pki-pqc-root",
    int: "pki-pqc-next",
    label: "Post-quantum, moved key",
    ocsp: false,
  },
};
export const INT_MOUNTS = ["pki-classic-int", "pki-pqc-int", "pki-pqc-next"];

export function chainParam(v) {
  const id = String(v || "");
  if (!CHAINS[id])
    throw new VaultError(
      400,
      `chain must be one of: ${Object.keys(CHAINS).join(", ")}`,
    );
  return id;
}

async function issuerPem(mount) {
  const j = await vault("GET", `${mount}/issuer/default`);
  return {
    pem: j.data.certificate,
    keyId: j.data.key_id,
    issuerId: j.data.issuer_id,
    name: j.data.issuer_name,
    warnings: j.warnings || [],
  };
}

export async function rootPem(chain) {
  return (await issuerPem(CHAINS[chain].root)).pem;
}

async function describeIssuer(mount) {
  const i = await issuerPem(mount);
  return {
    mount,
    issuerId: i.issuerId,
    issuerName: i.name,
    keyId: i.keyId,
    warnings: i.warnings,
    certificate: describe(i.pem),
  };
}

async function role(mount) {
  try {
    const r = await vault("GET", `${mount}/roles/service`);
    const d = r.data;
    return {
      name: "service",
      keyType: d.key_type,
      keyBits: d.key_bits || null,
      parameterSet: d.parameter_set || null,
      ttl: d.ttl,
      maxTtl: d.max_ttl,
      ou: d.ou,
    };
  } catch (e) {
    if (e instanceof VaultError && e.status === 404) return null;
    throw e;
  }
}

async function crlConfig(mount) {
  const c = await vault("GET", `${mount}/config/crl`);
  return {
    ocspDisabled: c.data.ocsp_disable,
    crlDisabled: c.data.disable,
    expiry: c.data.expiry,
  };
}

// Both chains at once (8 independent reads), within the shared fan-out budget.
export async function chains() {
  const one = async (id) => {
    const c = CHAINS[id];
    const [root, int, r, crlCfg] = await vaultFanout.map(
      [
        () => describeIssuer(c.root),
        () => describeIssuer(c.int),
        () => role(c.int),
        () => crlConfig(c.int),
      ],
      (fn) => fn(),
    );
    return [
      id,
      { id, label: c.label, root, intermediate: int, role: r, crl: crlCfg },
    ];
  };
  return Object.fromEntries(await Promise.all(["classic", "pqc"].map(one)));
}

// Issue one leaf from a chain's `service` role, then verify it twice: Node's
// crypto (in-process) and the openssl CLI (independent). The private key in
// Vault's response is dropped here and never leaves the API.
export async function issue(chain, commonName) {
  const c = CHAINS[chain];
  const started = Date.now();
  const r = await vault("POST", `${c.int}/issue/service`, {
    body: { common_name: commonName, ttl: "1h" },
  });
  const issueMs = Date.now() - started;
  const leafPem = r.data.certificate;
  const intermediatePem = r.data.issuing_ca;
  const root = await rootPem(chain);
  const leaf = describe(leafPem);
  const [node, cli] = [
    verifyChain([leafPem, intermediatePem], root),
    await openssl.verify({ leafPem, intermediatePem, rootPem: root }),
  ];
  return {
    chain,
    mount: c.int,
    issueMs,
    leaf,
    certificate: leafPem,
    privateKeyType: r.data.private_key_type,
    privateKeyParameterSet: r.data.private_key_parameter_set || null,
    privateKeyReturned: "dropped by the API",
    verification: {
      node: {
        ...node,
        runtime: `node ${process.versions.node}, OpenSSL ${process.versions.openssl}`,
      },
      openssl: cli,
    },
    vault: {
      request_id: r.request_id,
      serial_number: r.data.serial_number,
      expiration: r.data.expiration,
      private_key_type: r.data.private_key_type,
      warnings: r.warnings,
    },
  };
}

// Ask the chain's OCSP responder about one of its certificates.
export async function ocspCheck(chain, serial) {
  const c = CHAINS[chain];
  const cert = await vault("GET", `${c.int}/cert/${serial}`, { auth: false });
  const issuer = await issuerPem(c.int);
  const root = await rootPem(chain);
  const result = await openssl.ocsp({
    leafPem: cert.data.certificate,
    issuerPem: issuer.pem,
    rootPem: root,
    send: async (req) => {
      const res = await vault("POST", `${c.int}/ocsp`, {
        auth: false,
        raw: true,
        body: req,
        headers: { "content-type": "application/ocsp-request" },
      });
      return {
        httpStatus: res.status,
        bytes: Buffer.from(await res.arrayBuffer()),
      };
    },
  });
  return { chain, mount: c.int, serial, ocspConfigured: c.ocsp, ...result };
}

// CRL of an intermediate, parsed: signature algorithm, freshness, entries.
export async function crl(mount) {
  const res = await vault("GET", `${mount}/crl/pem`, {
    auth: false,
    raw: true,
  });
  const text = await res.text();
  if (!res.ok || !/BEGIN X509 CRL/.test(text))
    return { mount, available: false, httpStatus: res.status };
  return { mount, available: true, ...(await openssl.parseCrl(text)) };
}

// Is one serial on its chain's CRL? The ML-DSA chain's only revocation
// channel (no OCSP), so the room shows it next to the OCSP answer.
export async function crlLookup(chain, serial) {
  const c = CHAINS[chain];
  const parsed = await crl(c.int);
  const hit = parsed.revoked?.find((r) => r.serial === serial) || null;
  return {
    chain,
    mount: c.int,
    serial,
    available: parsed.available,
    signatureAlgorithm: parsed.signatureAlgorithm || null,
    lastUpdate: parsed.lastUpdate || null,
    nextUpdate: parsed.nextUpdate || null,
    entries: parsed.revoked?.length ?? null,
    listed: Boolean(hit),
    revokedAt: hit?.revokedAt || null,
  };
}

// The CA key move, as Vault records it. Read-only: the move itself needs sudo
// on pki-pqc-int/keys/:key/export and is `make pki-move` (an operator).
export async function moveEvidence() {
  const source = await describeIssuer("pki-pqc-int");
  const sourceKey = await vault("GET", `pki-pqc-int/key/${source.keyId}`).catch(
    () => null,
  );
  const [keyIds, issuerIds, exportIds] = await Promise.all([
    list("pki-pqc-next/keys"),
    list("pki-pqc-next/issuers"),
    list("pki-pqc-next/export"),
  ]);
  const keys = await Promise.all(
    keyIds.map(async (k) => (await vault("GET", `pki-pqc-next/key/${k}`)).data),
  );
  const issuers = await Promise.all(
    issuerIds.map(async (i) => {
      const d = (await vault("GET", `pki-pqc-next/issuer/${i}`)).data;
      return {
        issuerId: d.issuer_id,
        issuerName: d.issuer_name,
        keyId: d.key_id,
        fingerprint256: describe(d.certificate).fingerprint256,
      };
    }),
  );
  const exportKeys = await Promise.all(
    exportIds.map(async (u) => {
      const d = (await vault("GET", `pki-pqc-next/export/${u}`)).data;
      return {
        exportKeyUuid: d.export_key_uuid || u,
        name: d.name || null,
        keyType: d.key_type || null,
        exportKeyHmac: d.export_key_hmac,
        publicKeyType: (d.public_key || "")
          .split("\n")[0]
          .replace(/-/g, "")
          .trim(),
      };
    }),
  );
  const exportWarnings = source.warnings.filter((w) =>
    /private key exported/i.test(w),
  );
  return {
    source: {
      mount: "pki-pqc-int",
      keyId: source.keyId,
      keyType: sourceKey?.data?.key_type || null,
      parameterSet: sourceKey?.data?.parameter_set || null,
      fingerprint256: source.certificate.fingerprint256,
      exportWarnings,
    },
    target: {
      mount: "pki-pqc-next",
      keys: keys.map((k) => ({
        keyId: k.key_id,
        keyName: k.key_name,
        keyType: k.key_type,
        parameterSet: k.parameter_set || null,
      })),
      issuers,
      exportKeys,
    },
    moved:
      keys.length > 0 &&
      issuers.some(
        (i) => i.fingerprint256 === source.certificate.fingerprint256,
      ),
    command: "make pki-move",
  };
}
