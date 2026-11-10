// lib/fetch.js: GET with a hard deadline. An AbortController plus a REFERENCED
// setTimeout (AbortSignal.timeout was seen never to fire on a hung
// connection, vault_codex). Resolves {status, json, text}; a connection that
// fails or times out throws an Error with .kind = 'down' | 'timeout'.
export async function getJson(url, { timeoutMs = 800, headers = {}, fetchImpl = fetch } = {}) {
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), timeoutMs);
  try {
    const res = await fetchImpl(url, { headers, signal: ac.signal });
    const text = await res.text();
    let json = null;
    try {
      json = JSON.parse(text);
    } catch {
      /* not JSON (HAProxy CSV, an HTML error page) */
    }
    return { status: res.status, json, text };
  } catch (e) {
    const err = new Error(ac.signal.aborted ? `timed out after ${timeoutMs} ms` : e?.cause?.code || e.message);
    err.kind = ac.signal.aborted ? 'timeout' : 'down';
    throw err;
  } finally {
    clearTimeout(timer);
  }
}
