// cryptolab — the vault_crypto API. Plain node:http, no dependencies.
//
//   GET  /api/health                   both Vault nodes, agent token, edition
//   GET  /api/capabilities             licence features + which rooms can run
//   GET  /api/pki/chains               classic and ML-DSA hierarchies, roles, CRL config
//   POST /api/pki/issue                { chain, cn } one leaf, decoded, verified twice
//   GET  /api/pki/ocsp?chain=&serial=  ask the chain's OCSP responder
//   GET  /api/pki/crl?chain=&serial=   is the serial on the chain's CRL?
//   GET  /api/pki/move                 evidence of the ML-DSA CA key move (make pki-move)
//   GET  /api/agility                  both demo keys, versions, signatures, ledger
//   POST /api/agility/rotate           { key, target } rotate with algorithm change
//   POST /api/agility/sign             { message }
//   POST /api/agility/verify           every signature so far, against the key now
//   POST /api/agility/ledger/encrypt   { label }
//   POST /api/agility/ledger/rewrap    batch rewrap to the latest version
//   POST /api/agility/ledger/decrypt   batch decrypt (equal to what was typed?)
//   GET  /api/fpe                      fixtures + transformations (fpe_algorithm)
//   POST /api/fpe/encode|decode|rewrap { items: [...] } batch calls
//   GET  /api/certs                    inventory of the three issuing mounts + CRLs
//   POST /api/certs/revoke             { mount, serial }
//   GET  /auth/login | /auth/callback | /auth/logout   sign-in (Keycloak, PKCE)
//   GET  /api/me                       the person, groups, policies, what Vault allows
//
// Room routes run as the signed-in person (lib/session.js): Vault decides.
// Health and capabilities use the API's own token (platform facts only).
// Vault's error text is returned verbatim; the UI shows it unchanged.
import http from "node:http";
import { vault, VaultError, VAULT_ADDR, VAULT_SEAL_ADDR, nodeHealth, tokenPresent, stats, resetStats } from "./lib/vault.js";
import { isSerial, serialToVault } from "./lib/x509.js";
import { opensslVersion } from "./lib/openssl.js";
import * as pki from "./lib/pki.js";
import * as agility from "./lib/agility.js";
import * as fpe from "./lib/fpe.js";
import * as certs from "./lib/certs.js";
import * as session from "./lib/session.js";
import { ToolTimeout } from "./lib/openssl.js";

const PORT = Number(process.env.PORT || 3000);
const MAX_BODY = 64 * 1024;

export class BadRequest extends Error {}

function send(res, code, obj) {
  res.writeHead(code, { "content-type": "application/json", "cache-control": "no-store" });
  res.end(JSON.stringify(obj));
}

async function body(req) {
  let size = 0;
  const chunks = [];
  for await (const c of req) {
    size += c.length;
    if (size > MAX_BODY) throw new BadRequest("request body too large");
    chunks.push(c);
  }
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch {
    throw new BadRequest("invalid JSON body");
  }
}

// ── Input validation ─────────────────────────────────────────────────────────
export function commonName(v) {
  const s = String(v || "").trim().toLowerCase();
  if (!/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\.lab\.local$/.test(s)) {
    throw new BadRequest("cn: a DNS name under lab.local, for example orders.lab.local");
  }
  return s;
}

export function serialParam(v) {
  const s = String(v || "").trim();
  if (!isSerial(s)) throw new BadRequest("serial: hex, optionally colon-separated (as Vault prints it)");
  return serialToVault(s);
}

export function text(v, name, max = 200) {
  const s = String(v ?? "").trim();
  if (!s || s.length > max || /[\u0000-\u001f]/.test(s)) throw new BadRequest(`${name}: 1 to ${max} printable characters`);
  return s;
}

// ── Handlers ─────────────────────────────────────────────────────────────────
async function health() {
  const [seal, node] = await Promise.all([nodeHealth(VAULT_SEAL_ADDR), nodeHealth(VAULT_ADDR)]);
  const agentToken = tokenPresent();
  return {
    ok: Boolean(node.reachable && !node.sealed && agentToken),
    seal,
    vault: node,
    agent: { tokenPresent: agentToken },
    runtime: { node: process.versions.node, nodeOpenssl: process.versions.openssl, openssl: await opensslVersion() },
    vaultUi: `${(process.env.VAULT_UI_URL || "https://localhost:18801").replace(/\/$/, "")}/ui/`,
  };
}

// Which rooms can run: the licence feature they need, and one read that
// proves their configuration exists. Unknown stays distinct from absent.
async function capabilities() {
  const probe = async (path) => {
    try {
      await vault("GET", path);
      return { ok: true };
    } catch (e) {
      return { ok: false, error: e.message, vault: e.errors || [] };
    }
  };
  const license = await vault("GET", "sys/license/status").catch((e) => ({ error: e.message }));
  const lic = license?.data?.autoloaded || license?.data?.persisted_autoload || null;
  const features = lic?.features || null;
  const has = (f) => (features ? features.includes(f) : null);
  const node = await nodeHealth(VAULT_ADDR);
  const ent = Boolean(node.enterprise);
  const [pqc, agilityKey, transform] = await Promise.all([
    probe("pki-pqc-int/issuer/default"),
    probe("transit/keys/orders-signing"),
    probe("transform/transformations/fpe/ccn-legacy"),
  ]);
  const room = (licensed, config, needs) => ({ available: Boolean(licensed && config.ok), licensed, needs, config });
  return {
    version: node.version,
    license: lic ? { expirationTime: lic.expiration_time || null, features } : { error: license?.error || "not readable" },
    rooms: {
      pki: room(ent, pqc, "Vault Enterprise 2.2 (ML-DSA PKI, CA key export)"),
      agility: room(ent, agilityKey, "Vault Enterprise 2.2 (transit/keys/:name/algorithm)"),
      fpe: room(has("Transform Secrets Engine"), transform, "Transform Secrets Engine (ADP)"),
      lifecycle: room(ent, pqc, "Vault Enterprise"),
    },
  };
}

// Platform routes: the API's own token. Everything else in `routes` runs as
// the signed-in person.
const PLATFORM = new Set(["GET /api/health", "GET /api/capabilities", "GET /api/me", "GET /api/_stats", "POST /api/_stats/reset"]);

const STATS = process.env.VCRY_STATS === "1";

const routes = {
  ...(STATS ? { "GET /api/_stats": () => ({ ...stats }), "POST /api/_stats/reset": () => (resetStats(), { ...stats }) } : {}),
  "GET /api/health": health,
  "GET /api/capabilities": capabilities,
  "GET /api/me": (req) => session.me(req),

  "GET /api/pki/chains": async () => ({ chains: await pki.chains() }),
  "POST /api/pki/issue": async (req) => {
    const b = await body(req);
    return pki.issue(pki.chainParam(b.chain), commonName(b.cn || `${b.chain}-demo.lab.local`));
  },
  "GET /api/pki/ocsp": (_req, url) => pki.ocspCheck(pki.chainParam(url.searchParams.get("chain")), serialParam(url.searchParams.get("serial"))),
  "GET /api/pki/crl": (_req, url) => pki.crlLookup(pki.chainParam(url.searchParams.get("chain")), serialParam(url.searchParams.get("serial"))),
  "GET /api/pki/move": () => pki.moveEvidence(),

  "GET /api/agility": () => agility.overview(),
  "POST /api/agility/rotate": async (req) => {
    const b = await body(req);
    return agility.rotate(agility.keyParam(b.key), agility.targetParam(b.target));
  },
  "POST /api/agility/sign": async (req) => agility.sign(text((await body(req)).message, "message")),
  "POST /api/agility/verify": () => agility.verifyAll(),
  "POST /api/agility/ledger/encrypt": async (req) => agility.ledgerEncrypt(text((await body(req)).label, "label")),
  "POST /api/agility/ledger/rewrap": () => agility.ledgerRewrap(),
  "POST /api/agility/ledger/decrypt": () => agility.ledgerDecrypt(),

  "GET /api/fpe": async () => ({ fixtures: fpe.fixtures(), transformations: await fpe.transformations(), role: fpe.ROLE, rewrap: fpe.REWRAP }),
  "POST /api/fpe/encode": async (req) => fpe.encode((await body(req)).items),
  "POST /api/fpe/decode": async (req) => fpe.decode((await body(req)).items),
  "POST /api/fpe/rewrap": async (req) => fpe.rewrap((await body(req)).items),

  "GET /api/certs": () => certs.inventory(),
  "POST /api/certs/revoke": async (req) => {
    const b = await body(req);
    return certs.revoke(certs.mountParam(b.mount), serialParam(b.serial));
  },
};

function redirect(res, location, cookie) {
  const h = { location, "cache-control": "no-store" };
  if (cookie) h["set-cookie"] = cookie;
  res.writeHead(302, h);
  res.end();
}

async function authRoute(req, res, url) {
  try {
    if (url.pathname === "/auth/login") return redirect(res, session.login(url));
    if (url.pathname === "/auth/callback") {
      const { sid, returnTo } = await session.callback(url);
      return redirect(res, `${session.CONSOLE_URL}${returnTo}`, session.sessionCookie(sid, 8 * 3600));
    }
    if (url.pathname === "/auth/logout") return redirect(res, await session.logout(req), session.sessionCookie("", 0));
  } catch (e) {
    console.error(`[cryptolab] ${url.pathname}: ${e.message}`);
    return redirect(res, `${session.CONSOLE_URL}/#/overview?signin=failed`);
  }
  return send(res, 404, { ok: false, error: "not found" });
}

export const server = http.createServer(async (req, res) => {
  res.setHeader("x-content-type-options", "nosniff");
  const url = new URL(req.url, "http://api");
  if (req.method === "GET" && url.pathname.startsWith("/auth/")) return authRoute(req, res, url);
  try {
    const key = `${req.method} ${url.pathname}`;
    const handler = routes[key];
    if (!handler) {
      const known = Object.keys(routes).some((k) => k.endsWith(` ${url.pathname}`));
      return send(res, known ? 405 : 404, { ok: false, error: known ? "method not allowed" : "not found" });
    }
    const out = PLATFORM.has(key) ? await handler(req, url) : await session.asPerson(req, () => handler(req, url));
    // /api/health answers 503 when vault-1 or the agent token is not usable,
    // so container and proxy health checks see the real state.
    return send(res, url.pathname === "/api/health" && !out.ok ? 503 : 200, { ok: true, ...out });
  } catch (e) {
    if (e instanceof BadRequest) return send(res, 400, { ok: false, error: e.message, status: 400 });
    if (e instanceof ToolTimeout) return send(res, 504, { ok: false, error: e.message, status: 504 });
    if (e instanceof session.Unauthenticated) return send(res, 401, { ok: false, error: e.message, status: 401, signIn: "/auth/login" });
    if (e instanceof VaultError) {
      const code = e.status >= 500 ? 502 : e.status;
      return send(res, code, { ok: false, error: e.message, status: e.status, vault: e.errors });
    }
    console.error(`[cryptolab] ${req.method} ${url.pathname}:`, e);
    return send(res, 500, { ok: false, error: String(e?.message || e), status: 500 });
  }
});

if (process.env.NODE_ENV !== "test") {
  server.listen(PORT, () => console.log(`[cryptolab] listening on :${PORT}, Vault ${VAULT_ADDR}`));
}
