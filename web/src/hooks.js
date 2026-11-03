import { useCallback, useEffect, useRef, useState } from "react";
import { Aborted, call, subscribeLog } from "./api.js";
import { createLatest } from "./latest.js";

// GET a resource; reload() re-reads it. Errors keep Vault's text.
//
// Prompt 09: only the newest answer is applied (createLatest), an obsolete
// read is aborted, polls are scheduled after the previous one finished (they
// never pile up), and a hidden tab stops polling and refreshes when it is
// shown again.
export function useResource(
  label,
  path,
  { quiet = true, intervalMs = 0 } = {},
) {
  const [state, setState] = useState({
    data: null,
    error: null,
    loading: true,
  });
  const latest = useRef(null);
  if (!latest.current) latest.current = createLatest();
  const load = useCallback(async () => {
    const { id, signal } = latest.current.begin();
    try {
      const data = await call(label, path, { quiet, signal });
      if (latest.current.isCurrent(id))
        setState({ data, error: null, loading: false });
      return data;
    } catch (error) {
      if (error instanceof Aborted || !latest.current.isCurrent(id))
        return null;
      setState((s) => ({ data: s.data, error, loading: false }));
      return null;
    }
  }, [label, path, quiet]);
  useEffect(() => {
    let timer = null;
    let stopped = false;
    const schedule = () => {
      if (!intervalMs || stopped) return;
      clearTimeout(timer);
      timer = setTimeout(async () => {
        if (document.hidden) return; // resumed by visibilitychange
        await load();
        schedule();
      }, intervalMs);
    };
    const onVisible = () => {
      if (!document.hidden && intervalMs) {
        load().then(schedule);
      }
    };
    load().then(schedule);
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      stopped = true;
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", onVisible);
      latest.current.abort();
    };
  }, [load, intervalMs]);
  return { ...state, reload: load };
}

// An action button's lifecycle: busy while running, last result or error.
export function useAction(fn) {
  const [state, setState] = useState({
    busy: false,
    result: null,
    error: null,
  });
  const run = useCallback(
    async (...args) => {
      setState((s) => ({ ...s, busy: true, error: null }));
      try {
        const result = await fn(...args);
        setState({ busy: false, result, error: null });
        return result;
      } catch (error) {
        setState((s) => ({ busy: false, result: s.result, error }));
        return null;
      }
    },
    [fn],
  );
  const clear = useCallback(
    () => setState({ busy: false, result: null, error: null }),
    [],
  );
  return { ...state, run, clear };
}

export function useVaultLog() {
  const [entries, setEntries] = useState([]);
  useEffect(() => subscribeLog(setEntries), []);
  return entries;
}

// Hash routing: #/pki, #/agility …
export function useRoute(routes, fallback) {
  const read = () => {
    const r = window.location.hash.replace(/^#\/?/, "").split("?")[0];
    return routes.includes(r) ? r : fallback;
  };
  const [route, setRoute] = useState(read);
  useEffect(() => {
    const on = () => setRoute(read());
    window.addEventListener("hashchange", on);
    return () => window.removeEventListener("hashchange", on);
  });
  return route;
}
