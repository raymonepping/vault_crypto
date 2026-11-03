// lib/limit.js — a small concurrency limit with a bounded queue (prompt 09).
//
// One limiter is shared by everything that fans out to Vault (inventory
// certificate reads, both mounts at once, every concurrent request), so
// overlapping requests cannot multiply the load. A full queue fails fast with
// a 503 instead of growing without bound. Slots are released on success and
// on error.
import { VaultError } from "./vault.js";

export function createLimiter(max, { queueMax = 1000, name = "limit" } = {}) {
  if (!Number.isInteger(max) || max < 1) throw new Error(`${name}: max must be a positive integer`);
  let active = 0;
  const queue = [];

  const next = () => {
    if (active >= max || !queue.length) return;
    active++;
    const { fn, resolve, reject } = queue.shift();
    // Release the slot before the caller resumes, so work it queues next sees
    // the free slot.
    const done = () => {
      active--;
      next();
    };
    Promise.resolve()
      .then(fn)
      .then(
        (v) => {
          done();
          resolve(v);
        },
        (e) => {
          done();
          reject(e);
        },
      );
  };

  function run(fn) {
    if (queue.length >= queueMax) {
      return Promise.reject(new VaultError(503, `${name}: too much work queued (${queueMax}); try again shortly`));
    }
    return new Promise((resolve, reject) => {
      queue.push({ fn, resolve, reject });
      next();
    });
  }

  // map() keeps input order in the result, like Promise.all.
  const map = (items, fn) => Promise.all(items.map((item, i) => run(() => fn(item, i))));

  return { run, map, get active() { return active; }, get queued() { return queue.length; }, max };
}

const envInt = (name, dflt) => {
  const v = Number(process.env[name]);
  return Number.isInteger(v) && v > 0 ? v : dflt;
};

// The shared budget for Vault fan-out. 8 is a starting hypothesis measured in
// docs/optimization.md, not a proven optimum.
export const vaultFanout = createLimiter(envInt("VCRY_VAULT_FANOUT", 8), { queueMax: envInt("VCRY_VAULT_QUEUE", 4000), name: "vault fan-out" });
