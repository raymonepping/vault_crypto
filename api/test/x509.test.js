import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  derHeader,
  derSizes,
  describe,
  sigAlgorithm,
  serialToVault,
  isSerial,
  verifyChain,
} from "../lib/x509.js";

// Self-signed certificates made by the local openssl. ML-DSA needs 3.5+.
function selfSigned(algArgs) {
  const dir = mkdtempSync(path.join(os.tmpdir(), "x509-test-"));
  try {
    execFileSync(
      "openssl",
      ["genpkey", ...algArgs, "-out", path.join(dir, "k.pem")],
      { stdio: "pipe" },
    );
    execFileSync(
      "openssl",
      [
        "req",
        "-new",
        "-x509",
        "-key",
        path.join(dir, "k.pem"),
        "-subj",
        "/CN=t.lab.local/OU=test",
        "-days",
        "1",
        "-out",
        path.join(dir, "c.pem"),
      ],
      { stdio: "pipe" },
    );
    const pem = readFileSync(path.join(dir, "c.pem"), "utf8");
    const text = execFileSync(
      "openssl",
      ["x509", "-in", path.join(dir, "c.pem"), "-noout", "-text"],
      { encoding: "utf8" },
    );
    return { pem, text };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
let mldsa = null;
try {
  mldsa = selfSigned(["-algorithm", "ML-DSA-44"]);
} catch {
  mldsa = null;
}

test("derHeader reads short and long lengths", () => {
  assert.deepEqual(derHeader(Buffer.from([0x30, 0x03, 1, 2, 3]), 0), {
    tag: 0x30,
    hdr: 2,
    len: 3,
    start: 2,
    end: 5,
  });
  const long = Buffer.concat([
    Buffer.from([0x04, 0x82, 0x01, 0x00]),
    Buffer.alloc(256),
  ]);
  assert.equal(derHeader(long, 0).len, 256);
  assert.throws(() => derHeader(Buffer.from([0x30, 0x05, 1]), 0), /past end/);
});

test("EC certificate: sizes measured from DER, classic family", () => {
  const { pem } = selfSigned([
    "-algorithm",
    "EC",
    "-pkeyopt",
    "ec_paramgen_curve:P-256",
  ]);
  const d = describe(pem);
  assert.equal(d.key.label, "EC P-256");
  assert.equal(d.key.family, "classic");
  assert.equal(d.signatureAlgorithm.family, "classic");
  assert.ok(
    d.bytes.signature >= 68 && d.bytes.signature <= 72,
    `ECDSA P-256 DER signature, got ${d.bytes.signature}`,
  );
  assert.equal(d.bytes.publicKey, 91);
  assert.equal(d.ou, "test");
  assert.equal(verifyChain([pem], pem).ok, true);
});

test(
  "ML-DSA-44 certificate: post-quantum, 2420-byte signature",
  { skip: !mldsa && "local openssl has no ML-DSA" },
  () => {
    const d = describe(mldsa.pem);
    assert.equal(d.key.type, "ml-dsa-44");
    assert.equal(d.key.family, "post-quantum");
    assert.equal(d.signatureAlgorithm.oid, "2.16.840.1.101.3.4.3.17");
    assert.equal(d.signatureAlgorithm.name, "ML-DSA-44");
    assert.equal(d.bytes.signature, 2420); // FIPS 204, ML-DSA-44
    assert.equal(
      d.bytes.der,
      derSizes(
        Buffer.from(mldsa.pem.replace(/-----[^-]+-----|\s/g, ""), "base64"),
      ).total,
    );
  },
);

test("signature OIDs map to names, unknown ones fall back", () => {
  assert.equal(sigAlgorithm("2.16.840.1.101.3.4.3.19").name, "ML-DSA-87");
  assert.deepEqual(sigAlgorithm("1.2.3", "weird"), {
    name: "weird",
    family: "unknown",
  });
});

test("serials: Vault's colon form", () => {
  assert.equal(serialToVault("1A2B3C"), "1a:2b:3c");
  assert.equal(serialToVault("A2B3C"), "0a:2b:3c");
  assert.equal(isSerial("1a:2b:3c:4d:5e"), true);
  assert.equal(isSerial("zz"), false);
});
