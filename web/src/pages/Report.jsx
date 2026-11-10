// pages/Report.jsx: the epilogue. The sentence for the room is built from the
// latest report (make report), never typed by hand; then the RTO split, the
// RPO, and the same numbers across the last drills.
import { useEffect, useState } from 'react';
import { useResource } from '../hooks.js';
import { call } from '../api.js';
import { Hero, Loading, hms } from '../components/ui.jsx';

const stat = (xs) => {
  const v = xs.filter((x) => x !== null && x !== undefined).sort((a, b) => a - b);
  return v.length ? { min: v[0], median: v[Math.floor(v.length / 2)], max: v[v.length - 1] } : null;
};

function useReports(ids) {
  const [reports, setReports] = useState([]);
  const key = ids.join(',');
  useEffect(() => {
    let live = true;
    Promise.all(ids.map((id) => call(`/api/drills/${id}`).catch(() => null))).then((r) => live && setReports(r.filter(Boolean)));
    return () => {
      live = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  return reports;
}

export default function Report() {
  const drills = useResource('/api/drills', { intervalMs: 15000 });
  const closed = (drills.data ?? []).filter((d) => d.closed).slice(0, 10);
  const reports = useReports(closed.map((d) => d.id));
  const r = reports[0];
  if (!drills.data) return <Loading label="Reading the reports…" />;
  if (!r)
    return (
      <Hero kicker="The epilogue" title="No report yet">
        <p className="hero-lede">Run a drill (make drill), then make report.</p>
      </Hero>
    );
  const rows = [
    ['Detection', r.rto.detection_s, 'the first failed write, until the front door marked every node down'],
    ['Decision', r.rto.decision_s, 'until the operator ran promote'],
    ['Promotion and first write', r.rto.promotion_s, "the promote call, until the ticker's first acknowledged write on the promoted site"],
  ];
  const agg = { rto: stat(reports.map((x) => x.rto.total_s)), lost: stat(reports.map((x) => x.rpo?.lost_writes)) };
  return (
    <>
      <Hero kicker={`The epilogue: drill ${r.drill}`} title="The report">
        <p className="room-sentence" data-testid="sentence">
          {r.sentence}
        </p>
      </Hero>
      <section className="vg-card stack" aria-labelledby="rto-h">
        <div className="card-head">
          <h3 id="rto-h">RTO: {r.rto.total_s} s, as clients saw it</h3>
          <span className="card-sub">from the first failed write ({hms(r.first_error_at)}) to the first acknowledged one ({hms(r.first_write_at)})</span>
        </div>
        <table className="vg-table">
          <thead>
            <tr>
              <th scope="col">Part</th>
              <th scope="col" className="num">
                Seconds
              </th>
              <th scope="col">From the journal</th>
            </tr>
          </thead>
          <tbody>
            {rows.map(([part, sec, why]) => (
              <tr key={part}>
                <td>{part}</td>
                <td className="num">{sec ?? '-'}</td>
                <td>{why}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>
      <section className="vg-card stack" aria-labelledby="rpo-h">
        <div className="card-head">
          <h3 id="rpo-h">RPO: {r.rpo ? `${r.rpo.lost_writes} of ${r.rpo.checked} writes lost` : 'not measured'}</h3>
          <span className="card-sub">every write acknowledged in the minute before the outage, re-read on the promoted site</span>
        </div>
        {r.failback && <p>Planned failback: {r.failback.lost_writes} of {r.failback.checked} acknowledged writes missing.</p>}
      </section>
      {reports.length > 1 && (
        <section className="vg-card stack" aria-labelledby="runs-h">
          <div className="card-head">
            <h3 id="runs-h">Across the last {reports.length} drills</h3>
            <span className="card-sub">one Mac, not three regions: the numbers are this lab's</span>
          </div>
          <table className="vg-table">
            <thead>
              <tr>
                <th scope="col">Measure</th>
                <th scope="col" className="num">
                  Min
                </th>
                <th scope="col" className="num">
                  Median
                </th>
                <th scope="col" className="num">
                  Max
                </th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>RTO (s)</td>
                <td className="num">{agg.rto?.min}</td>
                <td className="num">{agg.rto?.median}</td>
                <td className="num">{agg.rto?.max}</td>
              </tr>
              <tr>
                <td>RPO (lost writes)</td>
                <td className="num">{agg.lost?.min}</td>
                <td className="num">{agg.lost?.median}</td>
                <td className="num">{agg.lost?.max}</td>
              </tr>
            </tbody>
          </table>
        </section>
      )}
    </>
  );
}
