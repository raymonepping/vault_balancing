// pages/Replication.jsx: per site, what Vault says about its replication:
// mode and state per kind, WAL indexes, who it streams from, lag.
import { MAP_ORDER, NAMES, roleView } from '../situation.js';
import { Hero, StatePill, Mono } from '../components/ui.jsx';

function Kind({ title, k }) {
  if (!k) return null;
  return (
    <>
      <dt>{title}</dt>
      <dd>
        {k.mode}
        {k.state ? `, ${k.state}` : ''}
      </dd>
      {k.last_wal != null && (
        <>
          <dt>last WAL</dt>
          <dd>{k.last_wal}</dd>
        </>
      )}
      {k.last_remote_wal != null && (
        <>
          <dt>last remote WAL</dt>
          <dd>{k.last_remote_wal}</dd>
        </>
      )}
      {k.primaries?.length > 0 && (
        <>
          <dt>streams from</dt>
          <dd>
            <Mono>{k.primaries.join(', ')}</Mono>
          </dd>
        </>
      )}
      {k.known_secondaries?.length > 0 && (
        <>
          <dt>secondaries</dt>
          <dd>
            <Mono>{k.known_secondaries.join(', ')}</Mono>
          </dd>
        </>
      )}
    </>
  );
}

export default function Replication({ s }) {
  const primary = s.sites.find((x) => x.state === 'up' && x.data?.role === 'primary');
  const byId = Object.fromEntries(s.sites.map((x) => [x.site, x]));
  return (
    <>
      <Hero kicker="Performance and DR Replication" title={primary ? `${NAMES[primary.site]} is primary` : 'No site reports primary'}>
        <p className="hero-lede">
          {primary ? `Cluster ${primary.data.cluster_id ?? 'unknown'}. Frankfurt replicates everything except payments-eu (the paths filter); Dublin replicates everything, tokens included.` : 'Every site answers, or none does: the front door takes no writes until Vault reports a primary.'}
        </p>
      </Hero>
      <div className="repl">
        {MAP_ORDER.map((id) => {
          const site = byId[id] ?? { site: id, state: 'unknown' };
          const rep = site.data?.vault_said?.replication;
          const v = roleView(site);
          return (
            <section key={id} className="vg-card stack" aria-labelledby={`repl-${id}`}>
              <div className="card-head">
                <h3 id={`repl-${id}`}>{NAMES[id]}</h3>
                <StatePill state={v.pill}>{v.word}</StatePill>
              </div>
              {rep ? (
                <dl className="facts-grid">
                  <Kind title="performance" k={rep.performance} />
                  <Kind title="DR" k={rep.dr} />
                  {site.data.lag_wal != null && (
                    <>
                      <dt>behind the primary</dt>
                      <dd>{site.data.lag_wal} WAL entries</dd>
                    </>
                  )}
                  {site.data.skew && (
                    <>
                      <dt>clock</dt>
                      <dd>more than 1 s off: seconds are unreliable here (make clock-sync)</dd>
                    </>
                  )}
                </dl>
              ) : (
                <p className="dim">{site.state === 'down' ? 'No node answers.' : 'No replication status read yet.'}</p>
              )}
            </section>
          );
        })}
      </div>
    </>
  );
}
