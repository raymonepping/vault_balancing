// components/ActionPanel.jsx: the drill's next step as a button (D16). It runs
// the same make target as the terminal, through the API and the host runner;
// Ansible runs the step and Vault still decides. Operators and admins press
// it; viewers and strangers see why they cannot. Killing a site needs the
// site's id typed. The running step's output follows below.
import { useState } from 'react';
import { Play, LogIn } from 'lucide-react';
import { useResource } from '../hooks.js';
import { call } from '../api.js';
import { signInHref } from './Person.jsx';

export default function ActionPanel({ me }) {
  const actions = useResource('/api/actions', { intervalMs: 2000 });
  const [typed, setTyped] = useState('');
  const [sending, setSending] = useState(false);
  const [refused, setRefused] = useState(null);
  const a = actions.data;
  if (!a?.runner) return null;
  const next = a.next;
  const cur = a.current;
  const needConfirm = next.confirm && next.enabled;

  async function press() {
    setSending(true);
    setRefused(null);
    try {
      await call(`/api/actions/${next.id}`, { method: 'POST', body: next.confirm ? { confirm: typed.trim() } : {} });
      setTyped('');
      await actions.reload();
    } catch (e) {
      setRefused(e.body?.error?.message ?? e.message);
    } finally {
      setSending(false);
    }
  }

  return (
    <section className="vg-card stack action-panel" aria-labelledby="next-h">
      <div className="card-head">
        <h3 id="next-h">
          Next step, Act {next.act}: {next.label}
        </h3>
        <code className="mono">{next.command}</code>
      </div>
      <div className="action-row">
        {needConfirm && (
          <div className="form-field action-confirm">
            <label htmlFor="confirm-site">Type {next.confirm} to confirm</label>
            <input id="confirm-site" value={typed} onChange={(e) => setTyped(e.target.value)} autoComplete="off" spellCheck={false} />
          </div>
        )}
        <button type="button" className={next.confirm ? 'destructive-button' : 'primary-button'} disabled={!next.enabled || sending || (needConfirm && typed.trim() !== next.confirm)} onClick={press}>
          <Play size={14} aria-hidden="true" /> {next.label}
        </button>
        {!me?.signedIn && (
          <a className="secondary-button" href={signInHref()}>
            <LogIn size={14} aria-hidden="true" /> Sign in as an operator
          </a>
        )}
      </div>
      {next.reason && <p className="action-reason" data-testid="action-reason">{next.reason}</p>}
      {refused && (
        <p className="inline-notice error" role="alert">
          Refused: {refused}
        </p>
      )}
      {cur && (
        <div className="action-run" aria-live="polite">
          <p className="action-run__head">
            {cur.running ? <span className="vg-live-dot" aria-hidden="true" /> : null}
            <strong>{cur.command}</strong> {cur.running ? 'running' : cur.exit_code === 0 ? 'finished' : `failed (exit ${cur.exit_code})`}, started by {cur.by}
          </p>
          <pre className="action-run__tail">{cur.tail.slice(-12).join('\n')}</pre>
        </div>
      )}
    </section>
  );
}
