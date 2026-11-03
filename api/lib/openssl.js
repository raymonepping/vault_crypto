// lib/openssl.js — the openssl CLI (3.5+) as an independent second verifier
// of ML-DSA chains, plus CRL parsing and OCSP (Node has neither). Inputs are
// written to a private temp dir that is removed afterwards.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { serialToVault } from "./x509.js";
import { createLimiter } from "./limit.js";

const exec = promisify(execFile);

// Every openssl child has a deadline and an output cap, and at most a few run
// at once (prompt 09). Measured: an ML-DSA chain verify or CRL parse takes a
// few ms here; 10 s is a generous ceiling, not a target.
const envInt = (n, d) => (Number.isInteger(Number(process.env[n])) && Number(process.env[n]) > 0 ? Number(process.env[n]) : d);
export const OPENSSL_TIMEOUT_MS = envInt("VCRY_OPENSSL_TIMEOUT_MS", 10_000);
const OPENSSL_MAX_OUTPUT = envInt("VCRY_OPENSSL_MAX_OUTPUT", 4 << 20);
const processes = createLimiter(envInt("VCRY_OPENSSL_CONCURRENCY", 4), { queueMax: envInt("VCRY_OPENSSL_QUEUE", 64), name: "openssl" });

export class ToolTimeout extends Error {}

// run(file, args): execFile with a deadline (SIGKILL), an output cap and the
// shared process limit. A timeout rejects with ToolTimeout, so callers can
// tell "could not check" from "checked and invalid".
export function run(file, args, { timeoutMs = OPENSSL_TIMEOUT_MS, maxBuffer = OPENSSL_MAX_OUTPUT } = {}) {
  return processes.run(() =>
    exec(file, args, { timeout: timeoutMs, killSignal: "SIGKILL", maxBuffer }).catch((e) => {
      if (e.killed || e.signal === "SIGKILL") throw new ToolTimeout(`${file} did not finish within ${timeoutMs} ms`);
      throw e;
    }),
  );
}

async function withTmp(fn) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "cryptolab-"));
  try {
    return await fn(dir);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
}

function toDate(s) {
  if (!s) return null;
  const d = new Date(s.replace(/ GMT$/, "Z").replace(/\s+/g, " "));
  return Number.isNaN(d.getTime()) ? s : d.toISOString();
}

let versionCache = null;
export async function opensslVersion() {
  if (versionCache) return versionCache;
  try {
    const { stdout } = await run("openssl", ["version"]);
    versionCache = stdout.trim();
  } catch (e) {
    versionCache = `unavailable: ${e.code || e.message}`;
  }
  return versionCache;
}

// `openssl verify` of leaf → intermediate → root. Returns the CLI's own line.
export async function verify({ leafPem, intermediatePem, rootPem }) {
  return withTmp(async (dir) => {
    const f = (n) => path.join(dir, n);
    await Promise.all([fs.writeFile(f("leaf.pem"), leafPem), fs.writeFile(f("int.pem"), intermediatePem), fs.writeFile(f("root.pem"), rootPem)]);
    const out = await run("openssl", ["verify", "-CAfile", f("root.pem"), "-untrusted", f("int.pem"), f("leaf.pem")])
      .then(({ stdout, stderr }) => ({ ok: true, text: `${stdout}${stderr}` }))
      .catch((e) => ({ ok: false, unavailable: e instanceof ToolTimeout, text: e instanceof ToolTimeout ? e.message : `${e.stdout || ""}${e.stderr || e.message}` }));
    return {
      ok: out.ok && /: OK\s*$/.test(out.text.trim()),
      // unavailable: openssl could not answer in time; that is not "invalid".
      unavailable: Boolean(out.unavailable),
      output: out.text.trim().replace(`${dir}/`, ""),
      openssl: await opensslVersion(),
    };
  });
}

export async function parseCrl(pem) {
  return withTmp(async (dir) => {
    const file = path.join(dir, "crl.pem");
    await fs.writeFile(file, pem);
    const { stdout } = await run("openssl", ["crl", "-in", file, "-noout", "-text"]);
    const revoked = [];
    const re = /Serial Number:\s*([0-9A-Fa-f]+)\s*\n\s*Revocation Date:\s*(.+)/g;
    for (let m; (m = re.exec(stdout)); ) revoked.push({ serial: serialToVault(m[1]), revokedAt: toDate(m[2].trim()) });
    return {
      signatureAlgorithm: /Signature Algorithm:\s*(.+)/.exec(stdout)?.[1]?.trim() || null,
      lastUpdate: toDate(/Last Update:\s*(.+)/.exec(stdout)?.[1]?.trim()),
      nextUpdate: toDate(/Next Update:\s*(.+)/.exec(stdout)?.[1]?.trim()),
      crlNumber: /X509v3 CRL Number:\s*\n\s*(\S+)/.exec(stdout)?.[1] || null,
      revoked,
    };
  });
}

// OCSP: build the request with openssl, send it to Vault's responder through
// `send` (fetch, so TLS to vault-1 is verified like every other call), then
// let openssl read and verify the signed response. An ML-DSA issuer gets
// HTTP 500 "internalerror" from Vault 2.2.1: that answer is returned as is.
export async function ocsp({ leafPem, issuerPem, rootPem, send }) {
  return withTmp(async (dir) => {
    const f = (n) => path.join(dir, n);
    await fs.writeFile(f("leaf.pem"), leafPem);
    await fs.writeFile(f("issuer.pem"), issuerPem);
    await fs.writeFile(f("trust.pem"), `${issuerPem}\n${rootPem}`);
    await run("openssl", ["ocsp", "-issuer", f("issuer.pem"), "-cert", f("leaf.pem"), "-no_nonce", "-reqout", f("req.der")]);
    const req = await fs.readFile(f("req.der"));
    const { httpStatus, bytes } = await send(new Uint8Array(req));
    await fs.writeFile(f("resp.der"), bytes);
    const { stdout, stderr } = await run("openssl", [
      "ocsp", "-respin", f("resp.der"), "-issuer", f("issuer.pem"), "-cert", f("leaf.pem"),
      "-CAfile", f("trust.pem"), "-no_nonce", "-resp_text",
    ]).catch((e) => {
      if (e instanceof ToolTimeout) throw e;
      return { stdout: e.stdout || "", stderr: e.stderr || String(e) };
    });
    const responderError = /Responder Error:\s*(.+)/.exec(`${stdout}\n${stderr}`)?.[1]?.trim() || null;
    const status = /leaf\.pem:\s*(good|revoked|unknown)/.exec(stdout)?.[1] || (responderError ? "responder-error" : "error");
    return {
      httpStatus,
      status,
      responderError,
      signatureVerified: /Response verify OK/.test(`${stdout}\n${stderr}`),
      signatureAlgorithm: /Signature Algorithm:\s*(.+)/.exec(stdout)?.[1]?.trim() || null,
      producedAt: toDate(/Produced At:\s*(.+)/.exec(stdout)?.[1]?.trim()),
      revocationTime: toDate(/Revocation Time:\s*(.+)/.exec(stdout)?.[1]?.trim()),
    };
  });
}
