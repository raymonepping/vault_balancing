// pages/Timeline.jsx: the drill journal: every step, its time, the call and
// Vault's answer. The open drill is live (server-sent events); a closed
// drill is read from its report.
import { useState } from 'react';
import { useResource } from '../hooks.js';
import { Hero, ErrorNotice, hms } from '../components/ui.jsx';

function Steps({ lines }) {
  if (!lines?.length) return <p className="dim">No steps yet.</p>;
  return (
    <ol className="journal-list">
      {lines.map((l, i) => (
        <li key={`${l.ts ?? l.at}-${i}`} className={`tl${/refused/.test(l.step) ? ' tl--refused' : ''}`}>
          <span className="tl__time">{(l.ts ?? l.at)?.slice(11, 23)}</span>
          <span className="tl__act">{l.act}</span>
          <span className="tl__step">{l.step}</span>
          <span className="tl__said">{l.vault_said ?? l.said}</span>
          <span className="tl__http">{l.http_code ?? l.http ?? ''}</span>
        </li>
      ))}
    </ol>
  );
}

export default function Timeline({ s }) {
  const drills = useResource('/api/drills', { intervalMs: 10000 });
  const [chosen, setChosen] = useState(null);
  const closed = (drills.data ?? []).filter((d) => d.closed);
  // With no drill open, show the latest closed one rather than an empty page.
  const pick = chosen ?? (s.drill ? null : closed[0]?.id ?? null);
  const setPick = setChosen;
  const report = useResource(pick ? `/api/drills/${pick}` : '/api/drill');
  const showing = pick ? report.data?.steps : s.drill?.lines;
  return (
    <>
      <Hero kicker={pick ? `Drill ${pick} (closed)` : s.drill ? `Drill ${s.drill.id} (open)` : 'No drill open'} title={pick ? report.data?.sentence ?? 'Reading the report…' : s.drill ? `Act ${s.drill.act ?? '-'}: ${s.drill.step ?? 'opened'}` : 'Nothing has happened yet'}>
        <p className="hero-lede">Every step the operator ran, with the call and Vault's own answer, as the drill journal recorded it.</p>
      </Hero>
      {closed.length > 0 && (
        <nav className="drill-picker" aria-label="Drills">
          {s.drill && (
            <button type="button" className="secondary-button" aria-pressed={pick === null} onClick={() => setPick(null)}>
              The open drill
            </button>
          )}
          {closed.slice(0, 8).map((d) => (
            <button key={d.id} type="button" className="secondary-button" aria-pressed={pick === d.id} onClick={() => setPick(d.id)}>
              {d.started_at ? `${new Date(d.started_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', timeZone: 'UTC' })}, ${hms(d.started_at)}` : d.id}
            </button>
          ))}
        </nav>
      )}
      {pick && report.error && <ErrorNotice error={report.error} title="That report" />}
      <section className="vg-card stack" aria-labelledby="tl-h">
        <div className="card-head">
          <h3 id="tl-h">Steps</h3>
          <span className="card-sub">UTC, act, step, what Vault said, HTTP status</span>
        </div>
        <Steps lines={showing} />
      </section>
    </>
  );
}
