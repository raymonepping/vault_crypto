// Prompt 09: bounded fan-out, bounded processes, deadlines, ordering.
import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { createLimiter } from "../lib/limit.js";
import { withKeyLock, pushCapped, byReference } from "../lib/agility.js";
import { run, ToolTimeout } from "../lib/openssl.js";
import { vault, VaultError } from "../lib/vault.js";
import { once } from "../lib/session.js";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test("limiter: never more than max at once, across overlapping callers, order kept", async () => {
  const lim = createLimiter(3);
  let now = 0;
  let peak = 0;
  const job = (v) => lim.run(async () => {
    now++;
    peak = Math.max(peak, now);
    await sleep(5);
    now--;
    return v;
  });
  // Two "requests" fanning out at the same time share the one budget.
  const [a, b] = await Promise.all([lim.map([1, 2, 3, 4, 5], (v) => v * 10).then(() => Promise.all([1, 2, 3, 4, 5].map(job))), Promise.all([6, 7, 8, 9].map(job))]);
  assert.deepEqual(a, [1, 2, 3, 4, 5]);
  assert.deepEqual(b, [6, 7, 8, 9]);
  assert.ok(peak <= 3, `peak ${peak}`);
  assert.equal(lim.active, 0);
});

test("limiter: a failing job releases its slot; a full queue fails fast with 503", async () => {
  const lim = createLimiter(1, { queueMax: 2 });
  await assert.rejects(lim.run(async () => { throw new Error("boom"); }), /boom/);
  assert.equal(await lim.run(async () => "after"), "after");
  const blocker = lim.run(() => sleep(30));
  const q1 = lim.run(async () => 1);
  const q2 = lim.run(async () => 2);
  await assert.rejects(lim.run(async () => 3), (e) => e instanceof VaultError && e.status === 503);
  await Promise.all([blocker, q1, q2]);
  assert.equal(lim.active, 0);
  assert.equal(lim.queued, 0);
});

test("key lock: same key serialized, other keys run alongside", async () => {
  const order = [];
  const slow = (k, tag, ms) => withKeyLock(k, async () => { order.push(`${tag}+`); await sleep(ms); order.push(`${tag}-`); });
  await Promise.all([slow("a", "a1", 20), slow("a", "a2", 1), slow("b", "b1", 1)]);
  assert.ok(order.indexOf("a1-") < order.indexOf("a2+"), order.join(" "));
  assert.ok(order.indexOf("b1-") < order.indexOf("a1-"), "b did not wait for a");
  await assert.rejects(withKeyLock("a", async () => { throw new Error("x"); }), /x/);
  assert.equal(await withKeyLock("a", async () => "next"), "next");
});

test("history: capped at 50, ids monotonic and never reused after eviction", () => {
  const list = [];
  let seq = 0;
  for (let i = 0; i < 120; i++) pushCapped(list, { id: ++seq });
  assert.equal(list.length, 50);
  assert.equal(list[0].id, 71);
  assert.equal(new Set(list.map((e) => e.id)).size, 50);
});

test("batch answers map back by reference, not position", () => {
  const snap = [{ id: 7 }, { id: 9 }, { id: 12 }];
  const mapped = byReference(snap, [
    { reference: "12", valid: false },
    { reference: "7", valid: true },
    { reference: "9", error: "invalid signature: version is too new" },
  ]);
  assert.deepEqual(mapped.map((m) => [m.entry.id, m.result.valid ?? m.result.error]), [[7, true], [9, "invalid signature: version is too new"], [12, false]]);
  assert.equal(byReference([{ id: 1 }], [])[0].result, null);
});

test("child process: a hung tool is killed at the deadline and reported as a timeout", async () => {
  const t0 = Date.now();
  await assert.rejects(run("sleep", ["5"], { timeoutMs: 150 }), (e) => e instanceof ToolTimeout);
  assert.ok(Date.now() - t0 < 2000, "not killed in time");
  const { stdout } = await run("echo", ["still works"]);
  assert.equal(stdout.trim(), "still works");
});

test("Vault client: a body that stalls after the headers is aborted at the deadline", async () => {
  const server = http.createServer((req, res) => {
    res.writeHead(200, { "content-type": "application/json" });
    res.write('{"data":');
    // ...and never finish.
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const addr = `http://127.0.0.1:${server.address().port}`;
  const t0 = Date.now();
  await assert.rejects(vault("GET", "sys/slow", { auth: false, addr, timeoutMs: 200 }), (e) => e instanceof VaultError && e.status === 504);
  assert.ok(Date.now() - t0 < 2000);
  server.closeAllConnections();
  server.close();
});

test("concurrent logins for the same credential share one call; different keys do not", async () => {
  let calls = 0;
  const login = () => once("session:abc", async () => { calls++; await sleep(10); return "token"; });
  assert.deepEqual(await Promise.all([login(), login(), login()]), ["token", "token", "token"]);
  assert.equal(calls, 1);
  const other = await once("session:xyz", async () => "other");
  assert.equal(other, "other");
});
