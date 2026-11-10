# DESIGN.md: the situation room

The console follows **Vault daylight glass**, the house system for every Vault
project (canonical implementation: Arcanium; contract: the `vault-ui-design`
skill). Light frosted panes, black ink, one dark ink hero per page, strong
status colours that hold WCAG AA. This file states only what vault_balancing
adds or decides on top of it.

## Stack

- React 19 + Vite 8 + Tailwind v4 (`web/`), served by nginx over TLS 1.3 with
  the lab certificate (`make gen-certs`), mounted read-only.
- `web/src/styles/vault-glass.css` and `shell.css` come from vault_codex
  unchanged; shared layout is `app.css`; the situation room's own pieces (the
  drill clock, the front door, the map, the ticker strip, the timeline,
  layers) are `balancing.css`, tokens only.
- Fonts: Hanken Grotesk Variable and JetBrains Mono Variable via
  `@fontsource-variable`, bundled, no external requests. Mono only for node
  names and paths; times and numbers use tabular figures.
- Icons: `lucide-react`. No emoji.
- CSP `style-src 'self'`: no inline style attributes (bar heights are set
  through the CSSOM, which CSP allows).

## Situation room

- **One button, the next step.** A signed-in operator or admin presses the
  drill's next step (prompt 12, D16); viewers and signed-out visitors see the
  same panel with the reason they cannot. The button runs the step's make
  target on the host, so the terminal and the console do exactly the same
  thing; the panel shows the command, then the run's output and who started
  it. Killing a site needs the site's id typed. Sign-in is Keycloak's own
  page; the top bar shows the person and their role. The console follows the
  API's server-sent events; nginx does not buffer `/api/events`.
- **One ink hero per page** carries the drill clock: "A normal day", or the
  act and step, the RTO as clients see it (live while writes fail), and the
  time since the site went dark. Presenter scale: the clock and the report's
  sentence are at least 26 px at 1440x900.
- **The map runs west to east:** Dublin, Amsterdam, Frankfurt. Each site
  card says its role in the room's words ("Primary: takes the writes",
  "Amsterdam is down"), its nodes with their health codes, and its lag.
- **Colour only for state**, each pill AA on its own tint: primary (blue),
  performance secondary (green), DR secondary and not replicating (grey),
  demoted and fenced (amber), down (red). **Two primaries** is a red banner
  with both names: the state the fence prevents, shown from a fixture in the
  tests because the real drill never reaches it.
- **Every value says its age when stale**, and the event stream says when it
  is reconnecting. A source that does not answer keeps its last answer, with
  that answer's age; nothing is guessed.
- **"Vault said"** is a drawer with each site's raw replication status and
  health answers: what every word on the pages was built from.
- **Motion:** the live dot and the ticker strip only; off under
  `prefers-reduced-motion`. No eyebrow labels, no all-caps labels.

## Pages

| Page | Hero | Body |
| --- | --- | --- |
| Situation room | the drill clock | the next step (a button for operators), the front door, three sites, the ticker's last 60 s |
| Replication | which site is primary, its cluster id | per site: mode and state per kind, WAL indexes, who it streams from, lag, clock skew |
| Drill timeline | the open drill's act and step, or a closed drill's sentence | every journal step: time, act, step, Vault's answer, HTTP status |
| Report | the sentence for the room, built from `report.json` | RTO split, RPO, failback, the last drills side by side |
| Layers | the split quote | every phase of `make lab` with its evidence, and the gates |

## Verification

- `make test-ui`: axe WCAG 2.1 AA on every page at 1440x900 and 390x844,
  Act 0, the drawer and the keyboard, the two-primaries fixture, the report
  against `report.json`, sign-in as each person (signed out, viewer,
  operator). `make test-ui-drill`: a whole drill followed live.
  `make test-ui-drill-clicks`: an operator presses every step.
- `make screenshots` writes `docs/screenshots/` (desktop and phone).
