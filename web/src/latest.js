// latest.js — "only the newest answer counts" for one resource (prompt 09).
// Each load gets an id and an AbortController; starting a new load aborts the
// previous one, and a late answer from an older load is never applied.
export function createLatest() {
  let current = 0;
  let controller = null;
  return {
    begin() {
      controller?.abort();
      controller = new AbortController();
      current += 1;
      return { id: current, signal: controller.signal };
    },
    isCurrent: (id) => id === current,
    abort() {
      controller?.abort();
      controller = null;
      current += 1;
    },
  };
}
