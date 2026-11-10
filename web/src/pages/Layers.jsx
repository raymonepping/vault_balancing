// pages/Layers.jsx: shift_gear's Layers page. Every phase of make lab in run
// order with its tool and evidence, then the gates that must be green before
// the lab counts as converged (.build/layers.json, read-only).
import { RefreshCw } from 'lucide-react';
import { useResource } from '../hooks.js';
import { ErrorNotice, Hero, Loading, Mono, StatePill } from '../components/ui.jsx';

const TOOL = { make: 'Make', terraform: 'Terraform', ansible: 'Ansible' };
const GATES = [
  ['idempotency', 'Idempotency', 'scripts/idempotency.sh'],
  ['drift', 'Drift', 'scripts/drift.sh'],
  ['secret-scan', 'Secret scan', 'scripts/secret-scan.sh'],
  ['boundary', 'Boundary', 'scripts/boundary-check.sh'],
  ['validation', 'Validation', 'ansible/validate.yml'],
];

const ago = (iso) => {
  if (!iso) return 'never';
  const s = Math.round((Date.now() - new Date(iso).getTime()) / 1000);
  return s < 90 ? `${s}s ago` : s < 5400 ? `${Math.round(s / 60)} min ago` : `${Math.round(s / 3600)} h ago`;
};

function Evidence({ p }) {
  if (p.tool === 'terraform') return <span>{p.resources ?? '–'} resources · applied {ago(p.last_apply)}</span>;
  if (p.tool === 'ansible') return <span>last run {ago(p.last_run?.at)}</span>;
  return <span>starts what runs</span>;
}

function Verdict({ p }) {
  if (p.tool === 'terraform') return p.last_plan ? <StatePill state={p.last_plan.changes ? 'denied' : 'ok'}>{p.last_plan.changes ? 'changes pending' : 'plan empty'}</StatePill> : <StatePill state="warn">not planned</StatePill>;
  if (p.tool === 'ansible') return p.last_run ? <StatePill state={p.last_run.changed ? 'warn' : 'ok'}>changed={p.last_run.changed}</StatePill> : <StatePill state="warn">not run</StatePill>;
  return null; // the Make badge already says it; Make leaves no plan or recap
}

export default function Layers() {
  const r = useResource('/api/layers');
  const L = r.data;
  const phases = L?.phases || [];
  const count = (t) => phases.filter((p) => p.tool === t).length;
  return (
    <>
      <Hero kicker="One phase list, three tools" title="Terraform builds the house. Ansible decorates it.">
        <p className="hero-lede">Every phase of make lab in order, with the evidence each tool leaves behind, and the gates that must be green before the lab counts as converged.</p>
        {L && (
          <p className="layers-summary">
            {count('terraform')} Terraform · {count('ansible')} Ansible · {count('make')} Make phases · {L.converged === 'success' ? `converged ${ago(L.converged_at)}` : 'not converged yet'}
            {L.automation_digest && (
              <>
                {' '}
                · digest <Mono>{L.automation_digest.slice(0, 12)}</Mono>
              </>
            )}
          </p>
        )}
        <button type="button" className="secondary-button hero-action" onClick={() => r.reload()}>
          <RefreshCw size={14} aria-hidden="true" /> Refresh
        </button>
      </Hero>
      {r.error && <ErrorNotice error={r.error} title="Layers" />}
      {r.loading && <Loading />}
      {!r.loading && !r.error && !L && <p className="inline-notice info">No evidence yet: run make lab.</p>}
      {L && (
        <>
          <section className="vg-card stack" aria-labelledby="gates-h">
            <div className="card-head">
              <h3 id="gates-h">Gates</h3>
              <span className="card-sub">
                what make lab requires before it writes <Mono>.build/convergence.json</Mono>
              </span>
            </div>
            <div className="gates">
              {GATES.map(([id, label, src]) => {
                const g = L.gates?.[id];
                return (
                  <div key={id} className="gate vg-tile">
                    <div className="gate__head">
                      <strong>{label}</strong>
                      {g ? <StatePill state={g.result === 'pass' ? 'ok' : 'denied'}>{g.result}</StatePill> : <StatePill state="warn">not run</StatePill>}
                    </div>
                    <span className="dim">{g?.at ? ago(g.at) : '–'}</span>
                    <Mono>{src}</Mono>
                  </div>
                );
              })}
            </div>
          </section>
          <section className="vg-card stack" aria-labelledby="phases-h">
            <div className="card-head">
              <h3 id="phases-h">Phases</h3>
              <span className="card-sub">in the order make lab runs them</span>
            </div>
            <ol className="phases">
              {phases.map((p, i) => (
                <li key={p.phase} className="phase">
                  <span className="phase__n">{i + 1}</span>
                  <span className={`tool tool--${p.tool}`}>{TOOL[p.tool]}</span>
                  <Mono>{p.phase}</Mono>
                  <span className="phase__evidence dim">
                    <Evidence p={p} />
                  </span>
                  <span className="phase__secs">{p.seconds != null ? `${p.seconds}s` : '–'}</span>
                  <Verdict p={p} />
                </li>
              ))}
            </ol>
          </section>
        </>
      )}
    </>
  );
}
