import { test } from "node:test";
import assert from "node:assert/strict";
import { commonName, serialParam, text } from "../server.js";
import { targetParam, keyParam, family } from "../lib/agility.js";
import { chainParam } from "../lib/pki.js";
import { mountParam } from "../lib/certs.js";
import * as fpe from "../lib/fpe.js";

test("common names stay under lab.local", () => {
  assert.equal(commonName("Orders.lab.local"), "orders.lab.local");
  assert.throws(() => commonName("orders.example.com"), /lab\.local/);
  assert.throws(() => commonName("-x.lab.local"), /lab\.local/);
});

test("serial and free text", () => {
  assert.equal(serialParam("1A:2B:3C:4D:5E"), "1a:2b:3c:4d:5e");
  assert.throws(() => serialParam("../etc"), /serial/);
  assert.equal(text(" hi ", "m"), "hi");
  assert.throws(() => text("", "m"), /printable/);
  assert.throws(() => text("a\u0000b", "m"), /printable/);
  assert.throws(() => text("x".repeat(201), "m"), /printable/);
});

test("rotation targets become Vault's algorithm payloads", () => {
  assert.deepEqual(targetParam("ml-dsa-65").body, {
    type: "ml-dsa",
    parameter_set: "65",
  });
  assert.deepEqual(targetParam("aes256-gcm96").body, { type: "aes256-gcm96" });
  assert.deepEqual(targetParam("hybrid-ml-dsa-65-ecdsa-p256").body, {
    type: "hybrid",
    parameter_set: "65",
    hybrid_key_type_pqc: "ml-dsa",
    hybrid_key_type_ec: "ecdsa-p256",
  });
  assert.throws(() => targetParam("rsa-1024"), /target must be one of/);
  assert.throws(() => keyParam("transit-root"), /key must be one of/);
  assert.equal(family("hybrid"), "post-quantum");
  assert.equal(family("ecdsa-p256"), "classic");
  assert.equal(family("aes256-gcm96"), "symmetric");
  assert.equal(family(null), "unknown");
});

test("mount and chain allow-lists", () => {
  assert.equal(chainParam("pqc"), "pqc");
  assert.throws(() => chainParam("pki-pqc-root"), /chain must be one of/);
  assert.equal(mountParam("pki-pqc-next"), "pki-pqc-next");
  assert.throws(() => mountParam("pki-pqc-root"), /mount must be one of/);
});

test("FPE only takes fixture rows, before any call to Vault", async () => {
  await assert.rejects(fpe.encode([]), /non-empty/);
  await assert.rejects(fpe.encode([{ id: "someone-real" }]), /unknown fixture/);
  await assert.rejects(
    fpe.decode([{ id: "card-1", value: "<script>" }]),
    /not an encoded/,
  );
  await assert.rejects(
    fpe.encode(Array.from({ length: 51 }, () => ({ id: "card-1" }))),
    /at most 50/,
  );
  assert.equal(
    fpe.fixtures().every((r) => r.check.checksum),
    true,
  );
});
