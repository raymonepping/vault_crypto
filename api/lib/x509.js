// lib/x509.js — certificate decoding on top of node:crypto (Node 24 with
// OpenSSL 3.5 parses and verifies ML-DSA certificates; see docs/capabilities.md).
//
// Sizes come from the DER itself, never from a table: the room's comparison
// is only honest if every byte count is measured on the certificate Vault
// just issued.
import crypto from "node:crypto";

const PEM_RE = /-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g;

export function splitPem(text) {
  return String(text || "").match(PEM_RE) || [];
}

// Vault writes serials as "1a:2b:…" (lower case); node:crypto as "1A2B…".
export function serialToVault(serial) {
  const hex = String(serial || "").replace(/[^0-9a-fA-F]/g, "").toLowerCase();
  const even = hex.length % 2 ? `0${hex}` : hex;
  return even.match(/../g)?.join(":") || "";
}

export function isSerial(s) {
  return typeof s === "string" && /^[0-9a-fA-F]{2}([:-]?[0-9a-fA-F]{2}){4,63}$/.test(s.trim());
}

// Signature algorithm OIDs this lab meets, with the name a person reads.
export const SIG_OIDS = {
  "1.2.840.10045.4.3.2": { name: "ECDSA with SHA-256", family: "classic" },
  "1.2.840.10045.4.3.3": { name: "ECDSA with SHA-384", family: "classic" },
  "1.2.840.10045.4.3.4": { name: "ECDSA with SHA-512", family: "classic" },
  "1.2.840.113549.1.1.11": { name: "RSA with SHA-256", family: "classic" },
  "1.3.101.112": { name: "Ed25519", family: "classic" },
  "2.16.840.1.101.3.4.3.17": { name: "ML-DSA-44", family: "post-quantum" },
  "2.16.840.1.101.3.4.3.18": { name: "ML-DSA-65", family: "post-quantum" },
  "2.16.840.1.101.3.4.3.19": { name: "ML-DSA-87", family: "post-quantum" },
};

export function sigAlgorithm(oid, fallbackName) {
  return SIG_OIDS[oid] || { name: fallbackName || oid || "unknown", family: "unknown" };
}

// ── Minimal DER reader: enough to find the signature inside a certificate ───
// Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue BIT STRING }
export function derHeader(buf, off) {
  if (off + 2 > buf.length) throw new Error("DER: truncated header");
  const tag = buf[off];
  let len = buf[off + 1];
  let hdr = 2;
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n < 1 || n > 4 || off + 2 + n > buf.length) throw new Error("DER: bad length");
    len = 0;
    for (let i = 0; i < n; i++) len = len * 256 + buf[off + 2 + i];
    hdr = 2 + n;
  }
  if (off + hdr + len > buf.length) throw new Error("DER: length past end");
  return { tag, hdr, len, start: off + hdr, end: off + hdr + len };
}

// Byte counts of a DER certificate: total, the to-be-signed part and the
// signature value (BIT STRING contents minus its unused-bits byte).
export function derSizes(der) {
  const cert = derHeader(der, 0);
  if (cert.tag !== 0x30) throw new Error("DER: certificate is not a SEQUENCE");
  const tbs = derHeader(der, cert.start);
  const alg = derHeader(der, tbs.end);
  const sig = derHeader(der, alg.end);
  if (sig.tag !== 0x03) throw new Error("DER: signatureValue is not a BIT STRING");
  return { total: der.length, tbs: tbs.end - cert.start, signature: sig.len - 1 };
}

function dnField(dn, key) {
  const m = new RegExp(`(?:^|\\n)${key}=([^\\n]+)`).exec(dn || "");
  return m ? m[1] : null;
}

function keyDescription(k) {
  const d = k.asymmetricKeyDetails || {};
  if (k.asymmetricKeyType === "ec") {
    const curve = { prime256v1: "P-256", secp384r1: "P-384", secp521r1: "P-521" }[d.namedCurve] || d.namedCurve;
    return { type: "ec", label: `EC ${curve}`, family: "classic" };
  }
  if (k.asymmetricKeyType === "rsa") return { type: "rsa", label: `RSA ${d.modulusLength}`, family: "classic" };
  if (/^ml-dsa-/.test(k.asymmetricKeyType)) return { type: k.asymmetricKeyType, label: k.asymmetricKeyType.toUpperCase(), family: "post-quantum" };
  return { type: k.asymmetricKeyType, label: k.asymmetricKeyType, family: k.asymmetricKeyType === "ed25519" ? "classic" : "unknown" };
}

export function describe(pem) {
  const x = new crypto.X509Certificate(pem);
  const notBefore = new Date(x.validFrom);
  const notAfter = new Date(x.validTo);
  const sizes = derSizes(x.raw);
  const spki = x.publicKey.export({ type: "spki", format: "der" });
  return {
    commonName: dnField(x.subject, "CN"),
    subject: x.subject.replace(/\n/g, ", "),
    issuer: x.issuer.replace(/\n/g, ", "),
    issuerCommonName: dnField(x.issuer, "CN"),
    ou: dnField(x.subject, "OU"),
    serial: serialToVault(x.serialNumber),
    notBefore: notBefore.toISOString(),
    notAfter: notAfter.toISOString(),
    lifetimeSeconds: Math.round((notAfter - notBefore) / 1000),
    sans: (x.subjectAltName || "").split(/,\s*/).filter(Boolean).map((s) => s.replace(/^DNS:/, "").replace(/^IP Address:/, "")),
    ca: x.ca,
    key: keyDescription(x.publicKey),
    signatureAlgorithm: { oid: x.signatureAlgorithmOid, ...sigAlgorithm(x.signatureAlgorithmOid, x.signatureAlgorithm) },
    bytes: { der: sizes.total, pem: Buffer.byteLength(pem.trim()), publicKey: spki.length, signature: sizes.signature, tbs: sizes.tbs },
    fingerprint256: x.fingerprint256,
  };
}

// Does `chain` (leaf first) verify link by link and end at `rootPem`?
export function verifyChain(chainPems, rootPem) {
  try {
    const certs = chainPems.map((p) => new crypto.X509Certificate(p));
    const root = new crypto.X509Certificate(rootPem);
    for (let i = 0; i < certs.length - 1; i++) {
      if (!certs[i].checkIssued(certs[i + 1]) || !certs[i].verify(certs[i + 1].publicKey)) {
        return { ok: false, reason: `link ${i} → ${i + 1} does not verify` };
      }
    }
    const last = certs[certs.length - 1];
    if (last.fingerprint256 === root.fingerprint256) return { ok: true, depth: certs.length };
    if (!last.checkIssued(root) || !last.verify(root.publicKey)) {
      return { ok: false, reason: "the last certificate is not signed by the chain's root" };
    }
    return { ok: true, depth: certs.length + 1 };
  } catch (e) {
    return { ok: false, reason: String(e?.message || e) };
  }
}
