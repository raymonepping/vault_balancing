// api.js: every call to the situation room API goes through here.
export class ApiError extends Error {
  constructor(status, body) {
    super(body?.error || `HTTP ${status}`);
    this.status = status;
    this.body = body || {};
  }
}

// A read this page cancelled itself (a newer read replaced it, or the view
// went away). Never shown as a refusal, never recorded.
export class Aborted extends Error {}

// call(path, { method, body, signal }) → parsed JSON, or ApiError.
export async function call(path, { method = "GET", body, signal } = {}) {
  let status = 0;
  let json = null;
  try {
    const r = await fetch(path, {
      method,
      headers: body === undefined ? {} : { "content-type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal,
    });
    status = r.status;
    try {
      json = await r.json();
    } catch {
      json = null;
    }
    if (!r.ok) throw new ApiError(status, json);
    return json;
  } catch (e) {
    if (e instanceof ApiError) throw e;
    if (signal?.aborted) throw new Aborted("cancelled");
    throw new ApiError(status, {
      error: `The API did not answer: ${e.message || e}`,
    });
  }
}
