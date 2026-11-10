import { useCallback, useEffect, useRef, useState } from "react";
import { Aborted, call } from "./api.js";
import { createLatest } from "./latest.js";

// GET a resource; reload() re-reads it. Errors keep Vault's text.
//
// Only the newest answer is applied (createLatest), an obsolete
// read is aborted, polls are scheduled after the previous one finished (they
// never pile up), and a hidden tab stops polling and refreshes when it is
// shown again.
export function useResource(path, { intervalMs = 0 } = {}) {
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
      const data = await call(path, { signal });
      if (latest.current.isCurrent(id))
        setState({ data, error: null, loading: false });
      return data;
    } catch (error) {
      if (error instanceof Aborted || !latest.current.isCurrent(id))
        return null;
      setState((s) => ({ data: s.data, error, loading: false }));
      return null;
    }
  }, [path]);
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
