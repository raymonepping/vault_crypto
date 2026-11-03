// scripts/gen-fixtures.js — write fixtures/fixtures.json, the synthetic data
// the FF1 room encodes. Deterministic: same output on every run.
//
// Nothing here belongs to a real person:
//   card  the card networks' published test numbers (Luhn-valid, never issued)
//   iban  NL + computed check digits + bank code "TEST" (no Dutch bank uses it)
//   bsn   numbers from the 99999xxxx block, which the Dutch government
//         reserves for testing, that pass the elfproef
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { luhn, ibanCheckDigits, ibanMod97, bsnElfproef } from "../lib/formats.js";

const cards = [
  ["Visa test", "4111-1111-1111-1111"],
  ["Visa test", "4012-8888-8888-1881"],
  ["Mastercard test", "5555-5555-5555-4444"],
  ["Mastercard test", "5105-1051-0510-5100"],
  ["Discover test", "6011-1111-1111-1117"],
  ["JCB test", "3530-1113-3330-0000"],
];

const ibans = [];
for (let n = 1; ibans.length < 5; n++) {
  const account = String(1000000000 + n * 7919).slice(-10);
  const bban = `TEST${account}`;
  ibans.push(`NL${ibanCheckDigits("NL", bban)}${bban}`);
}

const bsns = [];
for (let n = 99999000; bsns.length < 5 && n < 99999999; n += 7) {
  const s = String(n).padStart(8, "0");
  for (let last = 0; last <= 9; last++) {
    if (bsnElfproef(`${s}${last}`)) {
      bsns.push(`${s}${last}`.slice(-9));
      break;
    }
  }
}

const rows = [
  ...cards.map(([note, value], i) => ({ id: `card-${i + 1}`, kind: "card", value, note })),
  ...ibans.map((value, i) => ({ id: `iban-${i + 1}`, kind: "iban", value, note: "synthetic, bank code TEST" })),
  ...bsns.map((value, i) => ({ id: `bsn-${i + 1}`, kind: "bsn", value, note: "test block 99999xxxx" })),
];

for (const r of rows) {
  const ok = r.kind === "card" ? luhn(r.value) : r.kind === "iban" ? ibanMod97(r.value) : bsnElfproef(r.value);
  if (!ok) throw new Error(`fixture ${r.id} fails its own checksum: ${r.value}`);
}

const out = fileURLToPath(new URL("../fixtures/fixtures.json", import.meta.url));
writeFileSync(out, `${JSON.stringify({ synthetic: true, generatedBy: "api/scripts/gen-fixtures.js", rows }, null, 2)}\n`);
console.log(`gen-fixtures: ${rows.length} synthetic rows → fixtures/fixtures.json`);
