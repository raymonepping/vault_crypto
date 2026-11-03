import { test } from "node:test";
import assert from "node:assert/strict";
import { createLatest } from "../src/latest.js";

test("a newer load aborts the older one, and the older answer is not current", () => {
  const l = createLatest();
  const a = l.begin();
  const b = l.begin();
  assert.equal(a.signal.aborted, true);
  assert.equal(l.isCurrent(a.id), false);
  assert.equal(l.isCurrent(b.id), true);
});

test("out-of-order answers: only the newest is applied", async () => {
  const l = createLatest();
  const applied = [];
  const load = async (value, delay) => {
    const { id } = l.begin();
    await new Promise((r) => setTimeout(r, delay));
    if (l.isCurrent(id)) applied.push(value);
  };
  await Promise.all([load("old", 30), load("new", 5)]);
  assert.deepEqual(applied, ["new"]);
});

test("abort on unmount: nothing after it is current", () => {
  const l = createLatest();
  const a = l.begin();
  l.abort();
  assert.equal(a.signal.aborted, true);
  assert.equal(l.isCurrent(a.id), false);
});
