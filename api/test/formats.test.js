import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { luhn, ibanMod97, ibanCheckDigits, bsnElfproef, formatCheck, KINDS } from "../lib/formats.js";

test("Luhn accepts the networks' test numbers and rejects a changed digit", () => {
  assert.equal(luhn("4111-1111-1111-1111"), true);
  assert.equal(luhn("5555555555554444"), true);
  assert.equal(luhn("4111-1111-1111-1112"), false);
  assert.equal(luhn("123"), false);
});

test("IBAN mod-97: computed check digits validate, a swapped digit does not", () => {
  const kk = ibanCheckDigits("NL", "TEST0123456789");
  assert.match(kk, /^\d{2}$/);
  assert.equal(ibanMod97(`NL${kk}TEST0123456789`), true);
  assert.equal(ibanMod97(`NL${kk}TEST0123456798`), false);
  assert.equal(ibanMod97("not an iban"), false);
});

test("BSN elfproef", () => {
  assert.equal(bsnElfproef("999990007"), true);
  assert.equal(bsnElfproef("999990008"), false);
  assert.equal(bsnElfproef("000000000"), false);
  assert.equal(bsnElfproef("12345678"), false);
});

test("formatCheck reports shape and checksum separately", () => {
  assert.deepEqual(formatCheck("card", "1832-7569-0335-3206"), { shape: true, checksum: luhn("1832-7569-0335-3206"), checksumName: "Luhn" });
  assert.equal(formatCheck("iban", "NL26TEST1000007919").shape, true);
  assert.equal(formatCheck("iban", "DE26TEST1000007919").shape, false);
  assert.throws(() => formatCheck("phone", "x"), /unknown kind/);
});

test("fixtures are synthetic and pass their own checksums", () => {
  const { synthetic, rows } = JSON.parse(readFileSync(new URL("../fixtures/fixtures.json", import.meta.url), "utf8"));
  assert.equal(synthetic, true);
  const testPans = new Set(["4111111111111111", "4012888888881881", "5555555555554444", "5105105105105100", "6011111111111117", "3530111333300000"]);
  for (const r of rows) {
    assert.ok(KINDS[r.kind], r.id);
    assert.equal(formatCheck(r.kind, r.value).checksum, true, r.id);
    if (r.kind === "card") assert.ok(testPans.has(r.value.replace(/-/g, "")), `${r.id} is a published test number`);
    if (r.kind === "iban") assert.match(r.value, /^NL\d{2}TEST\d{10}$/, `${r.id} uses bank code TEST`);
    if (r.kind === "bsn") assert.match(r.value, /^99999\d{4}$/, `${r.id} is in the test block`);
  }
});
