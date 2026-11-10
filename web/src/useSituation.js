// useSituation: one EventSource for the whole console. The browser
// reconnects on its own; every reconnect starts with a full snapshot.
import { useEffect, useReducer, useState } from 'react';
import { initial, reduce } from './situation.js';

const TYPES = ['snapshot', 'site', 'frontdoor', 'ticker', 'drill', 'journal'];

export function useSituation() {
  const [state, dispatch] = useReducer(reduce, initial);
  useEffect(() => {
    const es = new EventSource('/api/events');
    es.onopen = () => dispatch({ type: 'open' });
    es.onerror = () => dispatch({ type: 'error' });
    for (const t of TYPES) es.addEventListener(t, (e) => dispatch({ type: t, data: JSON.parse(e.data) }));
    return () => es.close();
  }, []);
  return state;
}

// A clock that ticks once a second (for elapsed times and ages).
export function useNow(everyMs = 1000) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), everyMs);
    return () => clearInterval(t);
  }, [everyMs]);
  return now;
}
