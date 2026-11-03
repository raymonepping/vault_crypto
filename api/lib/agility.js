// lib/agility.js — the Crypto agility room: one Transit key name, several
// algorithms over time (Vault Enterprise 2.2: POST transit/keys/:name/algorithm).
//
// What Vault reports about a key's versions is limited, and the room says so:
//   - `type` stays the key's ORIGINAL type; `latest_version_type` is the new one.
//   - signing keys: each version has `name` (P-256, ml-dsa-…, or empty for
//     hybrid) and a public key; the type is derived from those, labelled
//     "derived".
//   - encryption keys: versions are only creation times. The type of an older
//     version is known only if this API saw Vault's answer when it rotated it
//     ("observed"), else "not reported by Vault".
import { vault, VaultError } from "./vault.js";

export const KEYS = {
  "orders-signing": { usage: "signing", start: "ecdsa-p256" },
  "ledger-data": { usage: "encryption", start: "aes128-gcm96" },
};

// What a person may pick as the next algorithm. Cross-usage types are offered
// on purpose: Vault refuses them, and the room shows the refusal.
export const TARGETS = {
  "ecdsa-p256": {},
  "ecdsa-p384": {},
  ed25519: {},
  "ml-dsa-44": { type: "ml-dsa", parameter_set: "44" },
  "ml-dsa-65": { type: "ml-dsa", parameter_set: "65" },
  "ml-dsa-87": { type: "ml-dsa", parameter_set: "87" },
  "slh-dsa-sha2-128s": { type: "slh-dsa", parameter_set: "slh-dsa-sha2-128s" },
  "hybrid-ml-dsa-65-ecdsa-p256": {
    type: "hybrid",
    parameter_set: "65",
    hybrid_key_type_pqc: "ml-dsa",
    hybrid_key_type_ec: "ecdsa-p256",
  },
  "aes128-gcm96": {},
  "aes256-gcm96": {},
  "chacha20-poly1305": {},
};
const PQC = /ml-dsa|slh-dsa|hybrid/;

export function keyParam(v) {
  const k = String(v || "");
  if (!KEYS[k])
    throw new VaultError(
      400,
      `key must be one of: ${Object.keys(KEYS).join(", ")}`,
    );
  return k;
}

export function targetParam(v) {
  const t = String(v || "");
  if (!TARGETS[t])
    throw new VaultError(
      400,
      `target must be one of: ${Object.keys(TARGETS).join(", ")}`,
    );
  return { label: t, body: TARGETS[t].type ? { ...TARGETS[t] } : { type: t } };
}

// Symmetric ciphers are their own family: AES-256 and ChaCha20 keep a
// 128-bit margin against a quantum attacker (Grover), unlike ECDSA or RSA.
export const family = (t) =>
  !t
    ? "unknown"
    : PQC.test(t)
      ? "post-quantum"
      : /aes|chacha|hmac|cmac/.test(t)
        ? "symmetric"
        : "classic";

// In-memory demo state, reset when the key is recreated (make demo-reset gives
// v1 a new creation time). Shared by everyone signed in: it is the lab's
// demo history, not per person (each person's Vault token still decides what
// they may do with it).
const state = {
  epoch: {},
  observed: {},
  requested: {},
  signatures: [],
  ledger: [],
  seq: { sig: 0, ledger: 0 },
};
export const HISTORY_MAX = 50;

// ── Concurrency (prompt 09) ──────────────────────────────────────────────────
// Writes to the same demo key are serialized (rotate, sign, encrypt, rewrap),
// so a rotation cannot interleave with the bookkeeping of a signature, and two
// rewraps cannot apply results to each other's snapshot. Reads stay parallel.
const locks = new Map();
export function withKeyLock(name, fn) {
  const prev = locks.get(name) || Promise.resolve();
  const run = prev.then(fn, fn);
  const tail = run.then(
    () => {},
    () => {},
  );
  locks.set(name, tail);
  tail.then(() => {
    if (locks.get(name) === tail) locks.delete(name);
  });
  return run;
}

// Monotonic ids: never reused after the history cap evicts old entries.
export function pushCapped(list, entry, max = HISTORY_MAX) {
  list.push(entry);
  while (list.length > max) list.shift();
  return entry;
}

// Map a Vault batch answer back to the snapshot it was made for, by the
// `reference` Vault echoes (the entry id), never by array position.
export function byReference(snapshot, results) {
  const out = new Map();
  for (const r of results || []) out.set(String(r.reference), r);
  return snapshot.map((e) => ({
    entry: e,
    result: out.get(String(e.id)) || null,
  }));
}

function syncEpoch(name, v1Created) {
  if (state.epoch[name] && state.epoch[name] !== v1Created) {
    state.observed[name] = {};
    state.requested[name] = {};
    if (name === "orders-signing") state.signatures = [];
    if (name === "ledger-data") state.ledger = [];
  }
  state.epoch[name] = v1Created;
  state.observed[name] ||= {};
  state.requested[name] ||= {};
}

function derivedType(v) {
  if (!v || typeof v !== "object") return null;
  const n = v.name || "";
  if (/^P-(256|384|521)$/.test(n)) return `ecdsa-p${n.slice(2)}`;
  if (/^ed25519$/i.test(n)) return "ed25519";
  if (/^ml-dsa-\d+$/.test(n)) return n;
  if (/^ml-dsa-?$/.test(n)) return "ml-dsa";
  if (/^slh-dsa/.test(n)) return n;
  if (!n && /BEGIN PUBLIC KEY/.test(v.hybrid_public_key || "")) return "hybrid";
  return null;
}

export async function readKey(name) {
  const k = (await vault("GET", `transit/keys/${name}`)).data;
  const v1 = k.keys?.["1"];
  syncEpoch(name, typeof v1 === "object" ? v1.creation_time : v1);
  const versions = Object.entries(k.keys || {})
    .map(([ver, v]) => {
      const version = Number(ver);
      const created =
        typeof v === "object"
          ? v.creation_time
          : new Date(Number(v) * 1000).toISOString();
      const derived = derivedType(v);
      const observed =
        state.observed[name][version] ||
        (version === 1 ? k.type : null) ||
        (version === k.latest_version ? k.latest_version_type : null);
      const type = derived || observed || null;
      return {
        version,
        created,
        type,
        typeSource: derived
          ? "derived from Vault's key read"
          : observed
            ? version === k.latest_version
              ? "latest_version_type"
              : version === 1
                ? "type (the original)"
                : "observed at rotation"
            : "not reported by Vault",
        family: family(type),
        // What this API asked for when it made the version (Vault reports a
        // rotated ML-DSA version as plain "ml-dsa", without its parameter set).
        requested: state.requested[name][version] || null,
        vaultName: typeof v === "object" ? (v.name ?? null) : null,
        publicKeyChars:
          typeof v === "object"
            ? (v.public_key || v.hybrid_public_key || "").length
            : null,
      };
    })
    .sort((a, b) => a.version - b.version);
  return {
    name,
    usage: KEYS[name].usage,
    vault: {
      type: k.type,
      latest_version: k.latest_version,
      latest_version_type: k.latest_version_type,
      min_decryption_version: k.min_decryption_version,
      key_usages: k.key_usages,
      supports_signing: k.supports_signing,
      supports_encryption: k.supports_encryption,
    },
    versions,
  };
}

export async function overview() {
  const [signing, ledger] = await Promise.all([
    readKey("orders-signing"),
    readKey("ledger-data"),
  ]);
  return {
    keys: { "orders-signing": signing, "ledger-data": ledger },
    callerConfig: {
      "orders-signing": "transit/sign/orders-signing",
      "ledger-data": "transit/encrypt/ledger-data",
    },
    signatures: state.signatures,
    ledger: state.ledger.map(
      ({ id, label, ciphertext, at, rewrappedFrom }) => ({
        id,
        label,
        ciphertext,
        version: cipherVersion(ciphertext),
        at,
        rewrappedFrom,
      }),
    ),
    targets: Object.keys(TARGETS),
  };
}

// Rotate to a new algorithm. Vault's refusal (incompatible key usages) comes
// back as a VaultError with Vault's own text.
export function rotate(name, target) {
  return withKeyLock(name, () => rotateLocked(name, target));
}

async function rotateLocked(name, target) {
  const r = await vault("POST", `transit/keys/${name}/algorithm`, {
    body: target.body,
  });
  const d = r?.data || {};
  if (d.latest_version) {
    state.observed[name][d.latest_version] =
      d.latest_version_type || target.body.type;
    state.requested[name][d.latest_version] = target.label;
  }
  return {
    name,
    requested: target.body,
    vault: {
      latest_version: d.latest_version,
      latest_version_type: d.latest_version_type,
      type: d.type,
      warnings: r?.warnings || null,
    },
    key: await readKey(name),
  };
}

const b64 = (s) => Buffer.from(String(s), "utf8").toString("base64");
const cipherVersion = (c) => Number(/^vault:v(\d+):/.exec(c || "")?.[1] || 0);

export function sign(message) {
  return withKeyLock("orders-signing", async () => {
    const r = await vault("POST", "transit/sign/orders-signing", {
      body: { input: b64(message) },
    });
    const key = await readKey("orders-signing");
    const signature = r.data.signature;
    const version = cipherVersion(signature);
    const v = key.versions.find((x) => x.version === version);
    const entry = pushCapped(state.signatures, {
      id: ++state.seq.sig,
      message,
      signature,
      version,
      type: v?.type || null,
      family: v?.family || "unknown",
      chars: signature.length,
      at: new Date().toISOString(),
    });
    return { entry, vault: { key_version: r.data.key_version } };
  });
}

// Verify every signature made so far against the key as it is now: one batch
// call (Transit batch_input, proven on 2.2.1 across ECDSA, ML-DSA and hybrid
// versions), results mapped back by reference. valid:false (a signature that
// does not verify), a per-item error (e.g. "version is too new") and a refusal
// of the whole request (403) stay three different answers.
export async function verifyAll() {
  const latest = (await readKey("orders-signing")).vault.latest_version;
  const snapshot = state.signatures.slice();
  if (!snapshot.length) return { latestVersion: latest, results: [] };
  const r = await vault("POST", "transit/verify/orders-signing", {
    body: {
      batch_input: snapshot.map((s) => ({
        input: b64(s.message),
        signature: s.signature,
        reference: String(s.id),
      })),
    },
  });
  return {
    latestVersion: latest,
    results: byReference(snapshot, r.data.batch_results).map(
      ({ entry, result }) => ({
        id: entry.id,
        version: entry.version,
        type: entry.type,
        valid: Boolean(result?.valid),
        ...(result?.error ? { vault: [result.error] } : {}),
        ...(result
          ? {}
          : {
              vault: ["no result for this signature in Vault's batch answer"],
            }),
      }),
    ),
  };
}

export function ledgerEncrypt(label) {
  return withKeyLock("ledger-data", async () => {
    const r = await vault("POST", "transit/encrypt/ledger-data", {
      body: { plaintext: b64(label) },
    });
    const entry = pushCapped(state.ledger, {
      id: ++state.seq.ledger,
      label,
      ciphertext: r.data.ciphertext,
      at: new Date().toISOString(),
      rewrappedFrom: null,
    });
    return {
      entry: { ...entry, version: cipherVersion(entry.ciphertext) },
      vault: { key_version: r.data.key_version },
    };
  });
}

// One batch call: every stored ciphertext moves to the latest version.
// Plaintext never appears in the response. Results are applied by id to the
// entries that still hold the ciphertext that was sent.
export function ledgerRewrap() {
  return withKeyLock("ledger-data", async () => {
    const epoch = state.epoch["ledger-data"];
    const snapshot = state.ledger.map((e) => ({
      id: e.id,
      ciphertext: e.ciphertext,
    }));
    if (!snapshot.length) return { rewrapped: 0, errors: [], entries: [] };
    const r = await vault("POST", "transit/rewrap/ledger-data", {
      body: {
        batch_input: snapshot.map((e) => ({
          ciphertext: e.ciphertext,
          reference: String(e.id),
        })),
      },
    });
    const mapped = byReference(snapshot, r.data.batch_results);
    let rewrapped = 0;
    if (state.epoch["ledger-data"] === epoch) {
      for (const { entry, result } of mapped) {
        const live = state.ledger.find((e) => e.id === entry.id);
        if (
          live &&
          live.ciphertext === entry.ciphertext &&
          result?.ciphertext
        ) {
          live.rewrappedFrom = cipherVersion(live.ciphertext);
          live.ciphertext = result.ciphertext;
          rewrapped++;
        }
      }
    }
    return {
      rewrapped,
      errors: mapped.map(({ result }) => result?.error).filter(Boolean),
      entries: state.ledger.map((e) => ({
        id: e.id,
        version: cipherVersion(e.ciphertext),
        rewrappedFrom: e.rewrappedFrom,
      })),
    };
  });
}

export async function ledgerDecrypt() {
  const snapshot = state.ledger.map((e) => ({
    id: e.id,
    ciphertext: e.ciphertext,
    label: e.label,
  }));
  if (!snapshot.length) return { entries: [] };
  const r = await vault("POST", "transit/decrypt/ledger-data", {
    body: {
      batch_input: snapshot.map((e) => ({
        ciphertext: e.ciphertext,
        reference: String(e.id),
      })),
    },
  });
  return {
    entries: byReference(snapshot, r.data.batch_results).map(
      ({ entry, result }) => {
        const plaintext = result?.plaintext
          ? Buffer.from(result.plaintext, "base64").toString("utf8")
          : null;
        return {
          id: entry.id,
          version: cipherVersion(entry.ciphertext),
          plaintext,
          equal: plaintext === entry.label,
          error: result?.error || (result ? null : "no result"),
        };
      },
    ),
  };
}

export function resetMemory() {
  state.observed = {};
  state.requested = {};
  state.signatures = [];
  state.ledger = [];
  state.epoch = {};
}
