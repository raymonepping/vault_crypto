// lib/vault.js — the only place cryptolab talks to Vault.
//
// The token comes from vault-agent's sink and is read on EVERY call: when the
// agent re-authenticates, the next request simply uses the new token. There is
// no VAULT_TOKEN environment variable anywhere in this service.
//
// TLS: vault-1 presents the lab listener certificate; NODE_EXTRA_CA_CERTS adds
// the lab CA to Node's trust store, so fetch() verifies it. Nothing disables
// verification.
import { AsyncLocalStorage } from "node:async_hooks";
import { readFileSync } from "node:fs";

export const VAULT_ADDR = (process.env.VAULT_ADDR || "https://vault-1:8200").replace(/\/$/, "");
export const VAULT_SEAL_ADDR = (process.env.VAULT_SEAL_ADDR || "https://vault-s:8200").replace(/\/$/, "");
const TOKEN_FILE = process.env.VAULT_TOKEN_FILE || "/run/vault/token";

export class VaultError extends Error {
  constructor(status, message, errors = []) {
    super(message);
    this.status = status;
    this.errors = errors;
  }
}

// Set by lib/session.js for a room request: the signed-in person's Vault
// token. Without it (health, capabilities) the API's own agent token is used.
export const userContext = new AsyncLocalStorage();

export function readToken() {
  const person = userContext.getStore()?.token;
  if (person) return person;
  let token = "";
  try {
    token = readFileSync(TOKEN_FILE, "utf8").trim();
  } catch (e) {
    throw new VaultError(503, `Vault Agent token sink not readable (${TOKEN_FILE}): ${e.code || e.message}`);
  }
  if (!token) throw new VaultError(503, `Vault Agent token sink is empty (${TOKEN_FILE}): is vault-agent healthy?`);
  return token;
}

export function tokenPresent() {
  try {
    return readFileSync(TOKEN_FILE, "utf8").trim().length > 0;
  } catch {
    return false;
  }
}

// fetch with a timeout that always fires: a referenced setTimeout aborts the
// request. (AbortSignal.timeout's timer is unreferenced and was seen to never
// fire on a hung connection.) The deadline covers the whole exchange: `read`
// consumes the body before the timer is cleared, so a response whose headers
// arrive in time but whose body stalls is still aborted (prompt 09).
async function fetchWithTimeout(url, opts, timeoutMs, read) {
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(new Error(`timed out after ${timeoutMs} ms`)), timeoutMs);
  try {
    const res = await fetch(url, { ...opts, signal: ac.signal });
    return { res, body: await read(res) };
  } catch (e) {
    if (ac.signal.aborted) throw new VaultError(504, `Vault ${opts.method} ${url.replace(/^.*\/v1\//, "")}: ${ac.signal.reason?.message || "timed out"}`);
    throw e;
  } finally {
    clearTimeout(t);
  }
}

// Optional load counters (VCRY_STATS=1 exposes them at /api/_stats): how many
// Vault requests, and how many at once. Counts only: no paths with secrets,
// no tokens.
export const stats = { requests: 0, inflight: 0, maxInflight: 0 };
export function resetStats() {
  stats.requests = 0;
  stats.maxInflight = stats.inflight;
}

// vault(method, path, { body, auth=true, raw=false, addr })
//   path is relative to /v1/. Returns parsed JSON, or with raw a buffered
//   response ({ ok, status, headers, text(), arrayBuffer() }) read in full
//   inside the deadline.
//   Vault's own error text is kept verbatim in the thrown VaultError.
export async function vault(method, path, { body, auth = true, raw = false, addr = VAULT_ADDR, headers = {}, timeoutMs = 15_000 } = {}) {
  const h = { ...headers };
  if (auth) h["X-Vault-Token"] = readToken();
  if (body !== undefined && !(body instanceof Uint8Array)) h["content-type"] = "application/json";
  stats.requests++;
  stats.inflight++;
  stats.maxInflight = Math.max(stats.maxInflight, stats.inflight);
  try {
    return await request(method, path, h, body, raw, addr, timeoutMs);
  } finally {
    stats.inflight--;
  }
}

async function request(method, path, h, body, raw, addr, timeoutMs) {
  const { res, body: buf } = await fetchWithTimeout(
    `${addr}/v1/${path}`,
    { method, headers: h, body: body === undefined ? undefined : body instanceof Uint8Array ? body : JSON.stringify(body) },
    timeoutMs,
    async (r) => Buffer.from(await r.arrayBuffer()),
  );
  if (raw) {
    return { ok: res.ok, status: res.status, headers: res.headers, text: async () => buf.toString("utf8"), arrayBuffer: async () => buf };
  }
  const text = buf.toString("utf8");
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  if (!res.ok) {
    const errors = json?.errors || [];
    const detail = errors.length ? errors.join("; ") : text.trim() || res.statusText;
    throw new VaultError(res.status, `Vault ${method} ${path}: ${res.status} ${detail}`, errors);
  }
  return json;
}

// LIST that answers [] for an empty path (Vault answers 404).
export async function list(path) {
  try {
    const j = await vault("LIST", path);
    return j?.data?.keys || [];
  } catch (e) {
    if (e instanceof VaultError && e.status === 404) return [];
    throw e;
  }
}

// Unauthenticated sys/health of one node, shaped for the overview.
export async function nodeHealth(addr) {
  try {
    const { body: j } = await fetchWithTimeout(`${addr}/v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200`, { method: "GET" }, 4_000, (r) => r.json());
    return {
      reachable: true,
      initialized: Boolean(j.initialized),
      sealed: Boolean(j.sealed),
      standby: Boolean(j.standby),
      version: j.version || null,
      enterprise: typeof j.enterprise === "boolean" ? j.enterprise : /\+ent/.test(j.version || ""),
    };
  } catch (e) {
    return { reachable: false, error: String(e?.cause?.code || e?.message || e) };
  }
}
