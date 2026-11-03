// scripts/bench.js — prompt 09 measurements against the live API.
//
//   node api/scripts/bench.js [samples]      (needs the API started with VCRY_STATS=1)
//
// Runs each operation `samples` times (default 20) sequentially, as olga, and
// prints one JSON line per operation: median and p95 latency, errors, Vault
// requests per call and the most Vault requests in flight at once. Prints no
// token, cookie, password or response body.
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const API = process.env.API || "http://127.0.0.1:13500";
const KC = process.env.KC || "http://127.0.0.1:13502";
const N = Number(process.argv[2] || 20);

async function token(user) {
  const password = execFileSync(path.join(ROOT, "scripts/identity-secrets.sh"), ["--print", user], { encoding: "utf8" }).trim();
  const r = await fetch(`${KC}/realms/vcry/protocol/openid-connect/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "password", client_id: "vcry-cli", username: user, password, scope: "openid" }),
  });
  return (await r.json()).access_token;
}

let auth = "";
async function call(method, p, body) {
  const r = await fetch(`${API}${p}`, {
    method,
    headers: { authorization: `Bearer ${auth}`, ...(body ? { "content-type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  await r.arrayBuffer();
  return r.status;
}
const stats = async () => (await (await fetch(`${API}/api/_stats`)).json());
const reset = () => fetch(`${API}/api/_stats/reset`, { method: "POST" }).then((r) => r.arrayBuffer());

const q = (xs, p) => {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1)];
};

async function measure(name, fn, { samples = N, parallel = 1 } = {}) {
  await fn(); // warm: the person's Vault login, connection reuse
  const times = [];
  let errors = 0;
  await reset();
  for (let i = 0; i < samples; i++) {
    const t0 = performance.now();
    const codes = await Promise.all(Array.from({ length: parallel }, fn));
    times.push(performance.now() - t0);
    errors += codes.filter((c) => c >= 400).length;
  }
  const s = await stats();
  const row = {
    op: name,
    samples,
    parallel,
    median_ms: Math.round(q(times, 50) * 10) / 10,
    p95_ms: Math.round(q(times, 95) * 10) / 10,
    errors,
    vault_requests_per_call: Math.round((s.requests / (samples * parallel)) * 10) / 10,
    max_inflight: s.maxInflight,
  };
  console.log(JSON.stringify(row));
  return row;
}

const s0 = await fetch(`${API}/api/_stats`);
if (s0.status !== 200) {
  console.error("bench: /api/_stats is off. Start the API with VCRY_STATS=1 (see docs/optimization.md).");
  process.exit(1);
}
auth = await token("olga");

const only = process.env.ONLY ? process.env.ONLY.split(",") : null;
const want = (n) => !only || only.includes(n);

if (want("inventory")) await measure("GET /api/certs (inventory)", () => call("GET", "/api/certs"));
if (want("inventory5")) await measure("GET /api/certs x5 parallel", () => call("GET", "/api/certs"), { samples: Math.max(5, N / 4), parallel: 5 });
if (want("chains")) await measure("GET /api/pki/chains", () => call("GET", "/api/pki/chains"));
if (want("me")) await measure("GET /api/me", () => call("GET", "/api/me"));
if (want("verify")) {
  const sigs = Number(process.env.SIGS || 0);
  await measure(`POST /api/agility/verify (${sigs} signatures)`, () => call("POST", "/api/agility/verify"));
}
