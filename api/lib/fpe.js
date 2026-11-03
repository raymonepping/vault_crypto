// lib/fpe.js — the Format-preserving room: FF1 encode, decode and rewrap
// through transform/…/payments, on the synthetic fixtures only.
//
// Stateless: the browser holds the encoded values and sends them back. Every
// response names the transformation and its fpe_algorithm as Vault reads it.
import { readFileSync } from "node:fs";
import { vault, VaultError } from "./vault.js";
import { KINDS, formatCheck } from "./formats.js";

const FIXTURES = JSON.parse(
  readFileSync(new URL("../fixtures/fixtures.json", import.meta.url), "utf8"),
).rows;
export const ROLE = "payments";
export const REWRAP = { from: "ccn-legacy", to: "ccn-2026" };
const TRANSFORMATIONS = ["ccn-legacy", "ccn-2026", "iban-ff1", "bsn-ff1"];
const MAX_BATCH = 50;

export function fixtures() {
  return FIXTURES.map((r) => ({
    ...r,
    transformation: KINDS[r.kind].transformation,
    check: formatCheck(r.kind, r.value),
  }));
}

export async function transformations() {
  const out = {};
  await Promise.all(
    TRANSFORMATIONS.map(async (t) => {
      const d = (await vault("GET", `transform/transformations/fpe/${t}`)).data;
      out[t] = {
        name: t,
        type: d.type,
        fpe_algorithm: d.fpe_algorithm,
        template: d.template,
        tweak_source: d.tweak_source,
        allowed_roles: d.allowed_roles,
      };
    }),
  );
  return out;
}

// items: [{ id, kind, value }] → validated against the fixture ids. Only
// fixture rows (or their encodings) go to Vault: this room never handles
// arbitrary personal data.
function items(input, { encoded }) {
  if (!Array.isArray(input) || !input.length)
    throw new VaultError(400, "items: a non-empty array");
  if (input.length > MAX_BATCH)
    throw new VaultError(400, `items: at most ${MAX_BATCH}`);
  return input.map((it) => {
    const fx = FIXTURES.find((r) => r.id === it?.id);
    if (!fx) throw new VaultError(400, `items: unknown fixture id ${it?.id}`);
    const value = encoded ? String(it.value || "") : fx.value;
    if (encoded && !/^[A-Z0-9-]{9,24}$/.test(value))
      throw new VaultError(
        400,
        `items: ${fx.id} value is not an encoded ${fx.kind}`,
      );
    return { id: fx.id, kind: fx.kind, value };
  });
}

const shaped = (rows, results, field, transformationOf) =>
  rows.map((r, i) => {
    const out = results[i]?.[field] ?? null;
    return {
      id: r.id,
      kind: r.kind,
      input: r.value,
      output: out,
      transformation: transformationOf(r),
      check: out ? formatCheck(r.kind, out) : null,
      error: results[i]?.error || null,
    };
  });

export async function encode(input) {
  const rows = items(input, { encoded: false });
  const r = await vault("POST", `transform/encode/${ROLE}`, {
    body: {
      batch_input: rows.map((x) => ({
        value: x.value,
        transformation: KINDS[x.kind].transformation,
      })),
    },
  });
  return {
    role: ROLE,
    items: shaped(
      rows,
      r.data.batch_results || [],
      "encoded_value",
      (x) => KINDS[x.kind].transformation,
    ),
  };
}

// decode: each encoded card says which transformation it is under (legacy or
// 2026, after a rewrap); IBAN and BSN have one each.
export async function decode(input) {
  const rows = items(input, { encoded: true }).map((x, i) => ({
    ...x,
    transformation:
      x.kind === "card" && input[i].transformation === REWRAP.to
        ? REWRAP.to
        : KINDS[x.kind].transformation,
  }));
  const r = await vault("POST", `transform/decode/${ROLE}`, {
    body: {
      batch_input: rows.map((x) => ({
        value: x.value,
        transformation: x.transformation,
      })),
    },
  });
  return {
    role: ROLE,
    items: shaped(
      rows,
      r.data.batch_results || [],
      "decoded_value",
      (x) => x.transformation,
    ).map((it) => ({
      ...it,
      matchesFixture: it.output === FIXTURES.find((f) => f.id === it.id).value,
    })),
  };
}

// One batch call moves every encoded card from ccn-legacy to ccn-2026. The
// value is decoded and re-encoded inside Vault: no plaintext in the response.
export async function rewrap(input) {
  const rows = items(input, { encoded: true }).filter((x) => x.kind === "card");
  if (!rows.length)
    throw new VaultError(
      400,
      "rewrap: card numbers only (the two FF1 card transformations)",
    );
  const r = await vault("POST", `transform/rewrap/${ROLE}`, {
    body: {
      batch_input: rows.map((x) => ({
        value: x.value,
        transformation: REWRAP.to,
        decode_transformation: REWRAP.from,
      })),
    },
  });
  return {
    role: ROLE,
    from: REWRAP.from,
    to: REWRAP.to,
    items: shaped(
      rows,
      r.data.batch_results || [],
      "encoded_value",
      () => REWRAP.to,
    ),
  };
}
