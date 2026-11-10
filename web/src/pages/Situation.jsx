// pages/Situation.jsx: what the room looks at while a site dies. The hero is
// the drill clock; below it the front door, the three sites west to east, and
// the ticker's last 60 seconds. Every value is Vault's, HAProxy's or the
// ticker's own answer; a stale one says how old it is.
import { MAP_ORDER, NAMES, roleView, clock, fencedSites } from '../situation.js';
import { Hero, StatePill, ago } from '../components/ui.jsx';
import { useNow } from '../useSituation.js';
import ActionPanel from '../components/ActionPanel.jsx';

function DrillClock({ drill, now }) {
  const c = clock(drill, now);
  if (!drill) {
    return (
      <Hero kicker="No drill open" title="A normal day">
        <p className="hero-lede">Amsterdam takes the writes, Frankfurt serves reads near its users, Dublin waits. An operator starts the drill below, or from the terminal: make drill.</p>
      </Hero>
    );
  }
  return (
    <Hero kicker={`Drill ${drill.id}`} title={drill.act ? `Act ${drill.act}: ${drill.step}` : 'The drill is open'}>
      <div className="room-hero__clock">
        <div className="clock">
          <span className="clock__value" data-testid="rto">{c.rto_s === null ? '-' : `${c.rto_s} s`}</span>
          <span className="clock__label">{c.running ? 'clients cannot write: the RTO clock runs' : c.rto_s === null ? 'no outage yet' : 'until clients wrote again (RTO)'}</span>
        </div>
        {c.since_s !== null && (
          <div className="clock">
            <span className="clock__value">{c.since_s} s</span>
            <span className="clock__label">since the site went dark</span>
          </div>
        )}
      </div>
    </Hero>
  );
}

function FrontDoor({ fd, now }) {
  const backends = fd?.data?.backends ?? [];
  const label = { primary: ['Writes', 'the one node that answers 200'], regional: ['Reads at Frankfurt', 'nodes that answer 200 or 473'] };
  return (
    <section className="vg-card stack" aria-labelledby="fd-h">
      <div className="card-head">
        <h3 id="fd-h">The front door</h3>
        <span className="card-sub">HAProxy follows each node's own health code; it never decides who is primary</span>
        {fd?.stale && <span className="stale-note">{fd.state === 'down' ? 'HAProxy does not answer' : `as of ${ago(fd.read_at, now)}`}</span>}
      </div>
      <div className="frontdoor">
        {backends.map((b) => (
          <div key={b.name} className="backend" data-testid={`backend-${b.name}`}>
            <div className="backend__head">
              <h3>{label[b.name]?.[0] ?? b.name}</h3>
              <span className="card-sub">{label[b.name]?.[1]}</span>
            </div>
            <ul className="servers">
              {b.servers.map((s) => (
                <li key={s.name} className={`server${s.state.startsWith('UP') ? ' server--up' : s.state.startsWith('MAINT') ? ' server--maint' : ''}`} data-state={s.state}>
                  <span>{s.name}</span>
                  <span className="server__code">{s.state.startsWith('MAINT') ? 'fenced' : s.check_code ?? s.state.toLowerCase()}</span>
                </li>
              ))}
            </ul>
          </div>
        ))}
      </div>
    </section>
  );
}

function Site({ site, fenced, now }) {
  const v = roleView(site, fenced);
  const d = site?.data;
  const primary = d?.role === 'primary' && site.state === 'up';
  return (
    <article className={`vg-card site${primary ? ' site--primary' : ''}${v.down ? ' site--down' : ''}`} data-testid={`site-${site?.site}`} aria-labelledby={`site-${site?.site}-h`}>
      <div className="site__head">
        <h3 id={`site-${site?.site}-h`} className="site__name">
          {NAMES[site?.site] ?? site?.site}
        </h3>
        <StatePill state={v.pill}>{v.word}</StatePill>
      </div>
      {site?.stale && site.read_at && <p className="stale-note">Last answer {ago(site.read_at, now)}</p>}
      {d?.lag_wal != null && <p className="site__line">{d.lag_wal === 0 ? 'Up to date with the primary' : `${d.lag_wal} WAL entries behind the primary`}</p>}
      <ul className="nodes">
        {(d?.nodes ?? []).map((n) => (
          <li key={n.node} className="node">
            <span className="node__name">{n.node}</span>
            <span className="node__state">{n.ha_state}</span>
            <span className="node__code">{n.health_code ?? '-'}</span>
          </li>
        ))}
      </ul>
    </article>
  );
}

function Ticker({ t }) {
  const d = t?.data;
  const spark = d?.spark ?? [];
  const max = Math.max(4, ...spark.map((b) => b.ack + b.fail));
  return (
    <section className="vg-card stack" aria-labelledby="ticker-h">
      <div className="card-head">
        <h3 id="ticker-h">The ticker: four writes a second through the front door</h3>
        {t?.stale && <span className="stale-note">the ticker does not answer</span>}
      </div>
      <div className="strip" role="img" aria-label={`Last 60 seconds: ${spark.reduce((n, b) => n + b.ack, 0)} acknowledged, ${spark.reduce((n, b) => n + b.fail, 0)} failed writes`}>
        {spark.map((b) => (
          <span
            key={b.t}
            className={`strip__bar${b.fail > 0 && b.ack === 0 ? ' strip__bar--fail' : b.ack + b.fail === 0 ? ' strip__bar--none' : ''}`}
            style={{ height: `${Math.max(8, ((b.ack + b.fail) / max) * 100)}%` }}
          />
        ))}
      </div>
      <div className="ticker-facts">
        <span>
          Last 10 s: <strong data-testid="acked">{d?.acked_10s ?? '-'}</strong> acknowledged, <strong data-testid="failed">{d?.fail_10s ?? '-'}</strong> failed
        </span>
        <span>
          Write latency p50 <strong>{d?.p50_ms != null ? `${Math.round(d.p50_ms)} ms` : '-'}</strong>
        </span>
        <span>
          Frankfurt behind by <strong>{d?.regional_lag == null ? 'unknown' : `${d.regional_lag} ${d.regional_lag === 1 ? 'write' : 'writes'}`}</strong>
        </span>
      </div>
    </section>
  );
}

export default function Situation({ s, me }) {
  const now = useNow();
  const fenced = fencedSites(s.frontdoor);
  const byId = Object.fromEntries(s.sites.map((x) => [x.site, x]));
  const primaries = s.sites.filter((x) => x.state === 'up' && x.data?.role === 'primary');
  return (
    <>
      <DrillClock drill={s.drill} now={now} />
      <ActionPanel me={me} />
      {s.split_brain && (
        <div className="split-brain" role="alert" data-testid="split-brain">
          <strong>Two primaries: {primaries.map((p) => NAMES[p.site] ?? p.site).join(' and ')} both say they are primary.</strong>
          <span>This is the split brain Act IV prevents. Fence one now: make fence SITE=&lt;site&gt;. Open "Vault said" for both clusters' answers.</span>
        </div>
      )}
      {!s.connected && <p className="inline-notice warn">The event stream is reconnecting; the values below may be old.</p>}
      <FrontDoor fd={s.frontdoor} now={now} />
      <div className="sites">
        {MAP_ORDER.map((id) => (
          <Site key={id} site={byId[id] ?? { site: id, state: 'unknown' }} fenced={fenced.has(id)} now={now} />
        ))}
      </div>
      <Ticker t={s.ticker} />
    </>
  );
}
