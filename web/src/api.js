// api.js — every call to the cryptolab API goes through here, and every
// answer (success or Vault's refusal) is recorded for the "Vault said" drawer.
export class ApiError extends Error {
  constructor(status, body) {
    super(body?.error || `HTTP ${status}`);
    this.status = status;
    this.body = body || {};
  }
}

const listeners = new Set();
let log = [];
let seq = 0;

export function subscribeLog(fn) {
  listeners.add(fn);
  fn(log);
  return () => listeners.delete(fn);
}

function record(entry) {
  log = [{ id: ++seq, at: new Date().toISOString(), ...entry }, ...log].slice(0, 30);
  listeners.forEach((fn) => fn(log));
}

// A read this page cancelled itself (a newer read replaced it, or the view
// went away). Never shown as a refusal, never recorded.
export class Aborted extends Error {}

// call(label, path, { method, body, quiet, signal }) → parsed JSON, or ApiError.
export async function call(label, path, { method = 'GET', body, quiet = false, signal } = {}) {
  let status = 0;
  let json = null;
  try {
    const r = await fetch(path, {
      method,
      headers: body === undefined ? {} : { 'content-type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal,
    });
    status = r.status;
    try {
      json = await r.json();
    } catch {
      json = null;
    }
    if (!quiet) record({ label, method, path, status, body: json });
    if (!r.ok) throw new ApiError(status, json);
    return json;
  } catch (e) {
    if (e instanceof ApiError) throw e;
    if (signal?.aborted) throw new Aborted('cancelled');
    if (!quiet) record({ label, method, path, status, body: { error: String(e.message || e) } });
    throw new ApiError(status, { error: `The API did not answer: ${e.message || e}` });
  }
}
