# STATE

What was built, deferred and learned, per prompt. When the brief
(`prompts/00_brief.md`) and the code disagree, the code wins and this file
says so.

## Decisions changed during the build

- **Audit fixes (2026-11-10), before any code:** a ponytail audit and a
  backend audit of the prompt set changed the brief: D7 denies only
  `vbal-tf-*` and `vbal-ansible-*` (Terraform must write `vbal-app-*`); D9
  re-mints the DR token (batch tokens cannot be renewed) and mints one on
  every new primary; D10 ticker uses a batch token (a performance secondary
  has its own token store) and a ring of 7200 keys (bounded storage); D11
  fence is durable (`.build/frontdoor/fenced.json` rendered into
  `haproxy.cfg`); D12 the API holds no Vault token (status endpoints are
  unauthenticated; a DR secondary refuses logins). Prompt 07 carries the
  approved API design. Open questions 8 and 9 and probe cases P18 to P21
  were added.
- **Ports live in `config/defaults.conf`, not `config/sites.json`
  (prompt 01):** prompt 01 put "seal port, node ports" in `sites.json`, but
  D4 makes ports overridable in `.env`, and two sources of one number would
  drift. `sites.json` holds the topology (id, name, bootstrap role, node
  count); the port names derive from it (`VBAL_PORT_SEAL_<SITE>`,
  `VBAL_PORT_VAULT_<SITE>_<n>`), and `node scripts/sites.js check` proves
  every name is set and unique.
- **One compose file for the three sites (prompt 01):** `compose/site/`,
  parametrised by `SITE` and its ports from `scripts/compose.sh`; stacks are
  `ams fra dub frontdoor app probe`. Three copies would have to change
  together.

## Root token uses

| When (UTC) | Cluster | Why | Revoked |
| --- | --- | --- | --- |

## Prompt 01: Foundation (2026-11-10)

Done:

- Layout; scaffold `main.tf`, `sanity_check.md`, `FOLDER_TREE.md` and
  `scan_on_pr.yml` removed (`ci.yml` and `gitleaks.yml` replace the last).
  The scaffold's `CHANGELOG.md`, `CONTRIBUTING.md`, `.github/` templates and
  `docs/release-checklist.md` are kept.
- `config/sites.json` (topology) and `scripts/sites.js` (`check`, `sites`,
  `nodes <site>`, `primary`), 5 unit tests in `scripts/sites.test.js`.
- `config/defaults.conf`: image pins (D1), ports (D4), `VBAL_WEB_CN`,
  `VBAL_TICK_MS`, `VBAL_DR_TOKEN_TTL`, app image names.
- From vault_codex, renamed `vcdx`→`vbal`: `env-init.sh`, `license.sh`,
  `gen-certs.sh` (SANs: every seal and node hostname, `frontdoor`, `web`,
  `api`, `ticker`, `balancing.localhost`), `network.sh`, `ports-check.sh`,
  `podman-check.sh` (minimum 16 GiB, to be measured in 02),
  `clock-sync.sh`, `license-features.sh` (Performance and DR Replication,
  Namespaces, Performance Standby), `secret-scan.sh` (every `*-init.json`
  including a surviving secondary root token, the DR token, AppRole files),
  `lint.sh`, `lab.sh` (`tf seal` loops over the sites), `idempotency.sh`,
  `layers.sh` (sums the three seal roots), `automation-digest.sh`,
  `trust-root.sh`, `vault-cli.hcl`, `ansible.cfg`, the `vbal_stats` callback,
  `.gitleaks.toml`, `.editorconfig`, `.markdownlint.json`, `.containerignore`,
  `.gitignore`, `.github/workflows/`.
- `scripts/common.sh`: `vbal_conf`, `site_nodes`, `site_of`,
  `site_bootstrap_role`, `vault_container` (`vault-ams-1` →
  `vbal-vault_ams_1`), `vault_port_of`, `vault_node`, `vault_site`,
  `vault_active`, `replication_status` (unauthenticated), `fenced`,
  `vault_primary` (Vault decides; fails on two unfenced primaries),
  `vault_wait`, `vault_token`, `fingerprint`, `phases`.
- `scripts/compose.sh`, `scripts/tf.sh` (roots `seal-<site>`, `platform`
  against `vault_primary`, `probe`), `scripts/ansible.sh` (the parsed sites
  with every address and container name in `.build/ansible-vars.json`,
  `VBAL_ROOT_FILE`).
- `scripts/phases.txt` (11 phases, all `# pending`), the Makefile with every
  target of prompts 02 to 11 (`run` says "not built yet"; drill targets take
  `SITE=` and `TO=`).
- `.claude/CLAUDE.md` adapted from vault_codex's (so the prompts need not
  repeat shared rules), `AGENTS.md` pointing at it.

## Prompt 02: Three sites (2026-11-10)

Done:

- `vault/seal/config.hcl.tmpl` and `vault/cluster/config.hcl.tmpl`, rendered
  at container start by `scripts/vault-server.sh` from `VBAL_HOST`,
  `VBAL_SITE`, `VBAL_PEERS` (one `retry_join` per peer). Chosen over 12
  committed files: one template cannot drift between nodes.
- `compose/site/compose.yaml`: seal Vault plus three nodes per site, names
  `vbal-seal_<site>`, `vbal-vault_<site>_<n>`, audit volumes with
  `driver_opts`, uid 100, `cap_drop: ALL`, the seal token as a single-file
  mount.
- Ansible: `vault_init` (vault_codex's four cases plus
  `vault_init_keep_root` for a secondary-to-be; accepts 472 and skips the
  token check on a DR secondary), `seal_tokens` and `cluster_bootstrap`
  parametrised by site; `seal-init.yml`, `seal-tokens.yml`, `bootstrap.yml`
  (ams fully; fra and dub node 1, root kept).
- Bootstrap policies complete: `vbal-tf-seal`, `vbal-ansible-seal`,
  `vbal-tf-platform`, `vbal-ansible-platform`; `vault/policies/dr-operations.hcl`.
  The DR token and Ansible's batch token for performance secondaries come
  from token roles Terraform declares (`vbal-dr-operations`,
  `vbal-ansible-batch`): a non-root token can only mint other policies
  through a role's `allowed_policies`.
- `terraform/seal` (one state per site), scripts `seals-up.sh`,
  `sites-up.sh` (bootstrap primary starts all nodes; a secondary node 1
  until Vault reports it as one; `--followers <site>`), `vault-unseal.sh
  <site>` (key on stdin), `vault-status.sh` (12 rows with health code and
  replication modes, no token), `seal-token-status.sh`,
  `seal-token-rotate.sh`, `root-regen.sh` (`seal-<site>` or `primary`, key
  on stdin), `vault-cli.sh`, `boundary-check.sh` (55 rows),
  `verify.sh` (podman, seals, sites, boundary).

Validated: from empty volumes `seals-up`, `seal-init`, `tf-seal-all`,
`seal-tokens`, `sites-up`, `bootstrap`; re-runs changed=0 (seal-init,
seal-tokens, bootstrap); `make tf-plan-all` empty for the three seal roots;
`make boundary` 55/0; `make license-features` all yes (licence expires
2035-12-31); `make verify` 23/0.

Measured (`podman stats`, 8 containers, nothing else running): seal Vaults
113 MB each, an active node 110 to 122 MB, a perf standby 45 MB, CPU under
2%. Twelve Vaults will stay well under 2 GB; the 16 GiB minimum in
`podman-check.sh` is generous and stays (HAProxy, ticker, api, web, probe).

Learned:

- The primary's standbys answer **473** (performance standby, licensed), not
  429: the `primary` backend has exactly one server up (audit finding 5).
- The first `sites-up` must start the bootstrap primary's followers before
  bootstrap: `cluster_bootstrap` waits for them to join.
- A `perl -0pi` replacement with `|` delimiters garbled `lab.sh`; multi-line
  edits go through the editor.
- Deleting `.secrets/tls/ca.*` was refused by the permission layer: the lab
  CA keeps the subject "Vault Codex Lab CA" (from the copied script). The
  leaf says "Vault Balancing Lab". `trust-root.sh` matches by SHA-1 and reads
  the name from the CA itself, so this is cosmetic. Fix: the user deletes
  `.secrets/tls/` and runs `make gen-certs` before the next clean slate.

## Prompt 03: The probe (2026-11-10)

Done:

- `scripts/probe.sh` (`make probe`), `scripts/probe-lib.sh`,
  `compose/probe/compose.yaml` (probe-a, probe-b, probe-c and a scratch
  HAProxy; reuse the seal HCL template: Shamir 1/1, Raft), `terraform/probe/`
  (namespace, namespaced provider, paths filter as `vault_generic_endpoint`,
  root audit). Scratch root tokens live in a private temp dir; `tf.sh probe`
  reads `VBAL_PROBE_ROOT_FILE`. Probe hostnames added to the listener SANs
  (a secondary verifies its primary's API certificate) and the leaf
  reissued. Ports `VBAL_PORT_PROBE_A..C` 19130 to 19132.
- `docs/capabilities.md` generated: 59 passed, 0 failed, about 150 s; two
  consecutive runs gave the same answers and left no `vbal-probe_*`
  container or volume. The real sites were untouched (verify 23/0,
  boundary 55/0 afterwards).
- Deviation: P14 ran once (0 of 27 acknowledged writes lost); the ten runs
  are prompt 06's `make drill-runs`, on the real lab, where they belong. P2's
  standby code comes from the real ams (473), not a second scratch node.

Answers to the open questions:

1. **Yes.** An orphan, non-renewable batch token from token role
   `vbal-dr-operations` (policy: promote, update-primary, autopilot state)
   promotes the DR secondary on 2.2.1, sent as `X-Vault-Token`. Without a
   token: "DR operation token was not provided" (400). A service token with
   the same policy: "invalid dr operation token: permission denied" (403).
2. Primary active 200; primary standby **473** (licensed performance
   standby, real ams); performance secondary active 200; DR secondary 472;
   demoted primary **472** (`dr: secondary`, state `idle`). Front door:
   `primary` accepts 200 only, `regional` 200 and 473.
3. Primary down, on the performance secondary: read 200; write 500 "request
   error returned from primary: rpc error: code = Unavailable desc =
   connection error"; AppRole login 500 "failed to determine alias name from
   login request".
4. After the **unplanned** promotion the performance secondary followed the
   promoted cluster **on its own** in 5.4 s (`known_primary_cluster_addrs`).
   `update-primary` on an attached secondary fails ("error authing for
   bootstrap") and burns the activation token. After the **planned**
   failback it did not follow within 60 s; `update-primary` with a batch
   token minted on the new primary answered 200. No token: 403; a service
   token from the primary: 403 "invalid token".
5. Split brain is real: the returned, un-fenced old primary answers 200 and
   reports itself performance and DR primary while the promoted cluster
   does too; a 200-only health check would route to both, and Vault itself
   does not prevent it. A runtime `disable server` is lost on an HAProxy
   restart (admin state 1, then 0); a rendered `disabled` survives (5).
6. One run: 0 of 27 acknowledged writes lost; the promoted cluster answered
   200 1.1 s after the promote call. Ten runs: prompt 06.
7. **Yes.** `{"mode":"deny","paths":["payments-eu/"]}` on
   `sys/replication/performance/primary/paths-filter/<secondary id>` keeps
   the namespace out of the performance secondary (immediately); Terraform's
   `vault_generic_endpoint` (`ignore_absent_fields`) applies twice with an
   empty plan. The filter is keyed by the secondary's activation id.
8. **Yes**, a batch AppRole token from the primary reads and forwards writes
   on the performance secondary and stays valid on the promoted DR
   secondary; a service token is refused on the performance secondary.
   `sys/health` and `sys/replication/status` answer without a token on
   every role. AppRole login on a DR secondary: 400 "path disabled in
   replication DR secondary mode".
9. The token minted on the old primary before it died kept working: for the
   promotion, for `update-primary` on the demoted old primary, and for its
   promotion in the failback (the promoted cluster's token store is a copy
   of the old one). Its TTL is the only limit. The drill still mints a fresh
   one on every new primary (D9), so the file always names a token from the
   current primary.

Decisions changed:

- **Act III (brief, prompt 06):** Frankfurt follows on its own;
  `make repoint` waits for Vault to report the new primary and runs
  `update-primary` only when it does not follow within a bound. Failback
  repoints explicitly.
- **D12 confirmed:** the API needs no token.
- **D10 confirmed:** batch AppRole tokens for the ticker.

Learned:

- `update-primary` and `secondary/enable` take `ca_file` (a path inside the
  container): the secondary verifies the primary's API certificate, so every
  hostname must be in the leaf's SANs.
- Batch tokens cannot be looked up as `lookup-self` on a DR secondary; a DR
  secondary refuses every normal path with "path disabled in replication DR
  secondary mode".

## Prompt 04: Terraform platform (2026-11-10)

Done:

- `terraform/platform/`: namespaces `payments` and `payments-eu`, a provider
  per namespace, KV v2 in each, AppRole in `payments` with role `ticker`
  (`token_type = "batch"`, 15 min), policy `vbal-app-ticker`
  (`vault/policies/app-ticker.hcl`), a synthetic seed secret in
  `payments-eu`, policy `vbal-dr-operations`, token roles
  `vbal-dr-operations` and `vbal-ansible-batch` (orphan, batch,
  non-renewable), the replicated file audit device, and Frankfurt's paths
  filter (`count` on `var.fra_secondary_id`, which `tf.sh` reads from
  `.secrets/vault/replication-ids.json`; empty until replicate).
- The situation-room AppRole and policy of the original prompt are gone (D12:
  the API holds no token).
- `scripts/drift.sh`: read-only gate (the lab's) plus `--prove` (`make
  drift`): a comment line added out of band to `autounseal` on each seal
  Vault and to `vbal-app-ticker` on the primary, with each root's own token;
  plan exit 2, apply, plan exit 0.

Validated: `make tf-platform` (12 resources, planned against ams),
`make tf-plan-all` empty for all four roots, `make drift` caught all four,
`make boundary` 55/0, `make vault-cli CMD="namespace list"` shows both
namespaces, `make verify` 23/0.

Learned:

- `vault_primary` called inside `$(...)` lost `VAULT_ADDR` (a subshell): it
  now sets `VBAL_PRIMARY` and `VAULT_ADDR` in the caller and prints nothing.
- A batch-token role keeps no max TTL: `token_max_ttl` and
  `token_explicit_max_ttl` both read back 0, a perpetual diff. The TTL is set
  at mint time (`VBAL_DR_TOKEN_TTL`, D9); the roles declare none.

## Prompt 05: Replicate, front door, ticker, make lab (2026-11-10)

Done:

- `ansible/replicate.yml` with `tasks/activate.yml`: ams enabled as
  performance and DR primary; fra and dub activated once each with their own
  init root token (dropped from the init file right after, gotcha 16), then
  their followers started; waits for `stream-wals` and for every node's
  secondary health code. Activation ids are allocated above both
  `.secrets/vault/replication-ids.json` and the primary's
  `known_secondaries`, and recorded before the token is requested. Refuses
  to run while a drill has moved the primary.
- `tasks/find_primary.yml` (Vault decides; fails on two unfenced primaries),
  `tasks/dr_token.yml` (D9: mint when missing, from another site, or under
  4h; `.meta.json` with site, expiry, accessor fingerprint),
  `tasks/ticker_secret.yml` (role-id; secret-id re-issued under 12h of 24h,
  agent re-reads it), `ansible/dr-token.yml` (`make dr-token`).
- Phase `make paths-filter` (`tf.sh platform apply` after replicate):
  Frankfurt's id exists only then. The phase list has 12 phases.
- Front door: `ansible/roles/frontdoor` renders `haproxy.cfg` from the
  topology and `.build/frontdoor/fenced.json` (fenced servers `disabled`),
  validates and reloads with SIGUSR2; `compose/frontdoor/` mounts the
  rendered directory read-only (a re-render is seen). **TLS passthrough**
  (mode tcp, HTTPS health checks): HAProxy holds no key and clients see
  Vault's own certificate; writes on 8443 (published 19180), reads on 8444
  (internal), stats 8404 (19181). `scripts/frontdoor-up.sh`,
  `frontdoor-status.sh`.
- Ticker: `app/ticker/` (Node 24, no dependencies; pure logic in `lib.js`,
  5 unit tests), Vault Agent `vbal-ticker_agent` (vault_codex's watchdog
  entrypoint, AppRole in `payments`, logs in through the front door), sink on
  a tmpfs volume shared with the ticker only, journal and seq counter on a
  persistent volume. `/metrics` is JSON. `scripts/app-build.sh`,
  `app-up.sh`, `ticker.sh status|tail|reset`.
- `ansible/validate.yml`: roles, streaming, voters (Frankfurt read with a
  5-minute batch token), paths filter, front door (1 up / 3 up), ticker
  (at least 36 of 40 in 10 s, lag at most 4), DR token over 2h.
  `scripts/clean-slate.sh` (`CONFIRM=vbal`), `verify.sh` sections
  replication, frontdoor, ticker.

Validated:

- `make clean-slate CONFIRM=vbal && make lab` from nothing: **257 s**, all
  12 phases, idempotency changed=0, no drift, secret scan clean (25 known
  values), boundary 55/0.
- `make lab` again on the converged lab: 130 s, every phase changed=0.
- `make frontdoor-status`: primary 1 up (ams-1, 200), ams-2/3 down (473),
  dub down (472); regional 3 up (200, 473, 473). `make ticker-status`: 39 to
  40 acknowledged per 10 s, p50 8 to 10 ms, Frankfurt lag 0.
- `make tf-plan-all` empty (4 roots), `make verify` 33/0, no exited `vbal-`
  container, 15 running. Nothing else was running.

Learned:

- An Ansible string concatenation of an int fails (`_AnsibleTaggedInt`):
  use `~`. A failed run after `secondary-token` burns that id: the
  allocation now reads Vault's `known_secondaries` (fra-1 and fra-2 were
  burned this way; the rebuild started at fra-1 again on fresh clusters).
- `data.keys` in Jinja is the dict method: LIST answers need `data['keys']`.
- `node --test <dir>` no longer works on Node 25: pass a glob.
- A task name with ": " breaks the YAML parser.
- Shell writes and reads under `.secrets/` are refused by the permission
  layer; scripts and playbooks do that work.
- `clean-slate` moved `.secrets/terraform` and `.build/terraform` into the
  same legacy folder: `.build` items go to `legacy/build/`.

## Prompt 06: The drill (2026-11-10)

Done:

- Playbooks, one per act, each a make target, each refusing a wrong state
  with Vault's own answer and journaling it: `site-down.yml` (`podman kill`
  of the whole site: a site that loses power does not shut down cleanly),
  `promote.yml` (DR token in `X-Vault-Token`; waits for the front door to
  route; the client-observed gap from the ticker; RPO by re-reading every
  write acknowledged in the minute before; a fresh DR token from the new
  primary), `repoint.yml` and `tasks/follow.yml` (20 s for Frankfurt to
  follow on its own, then `update-primary`), `fence.yml` (fence list,
  rendered `disabled` without a reload, runtime socket for the running
  HAProxy; unfencing a site that still says primary is refused),
  `site-up.yml` (refuses an unfenced ex-primary; journals what each node
  believes, verbatim), `demote.yml` (performance then DR, attach with a fresh
  id and the DR token), `failback.yml` (catch-up by WAL index, demote,
  promote, "clients write again", re-attach, Frankfurt, zero lost).
- Shared tasks: `journal.yml`, `drill_open.yml`, `next_id.yml` (also used by
  `activate.yml`), `active_node.yml`, `frontdoor_wait.yml`, `ticker_get.yml`.
- `scripts/journal.sh` (the one journal writer; refuses token-shaped
  values), `scripts/report.js` + `report.sh` (RTO split, RPO, failback, the
  sentence, the ticker's window and Vault's audit records of every
  replication call), 4 unit tests; `scripts/drill.sh` (`make drill`,
  `DRILL_AUTO=1`), `scripts/drill-runs.sh`.
- Ticker endpoints `/gap?after=` (the outage as clients saw it),
  `/first-ok?after=`, `/verify?to=&seconds=` (re-read slots through the front
  door with the ticker's own token: the only token allowed to read its data),
  with unit tests (8 more).

Measured (`make drill-runs N=10`, nothing else running; docs/capabilities.md):

| Measure | Min | Median | Max |
| --- | --- | --- | --- |
| RTO as clients saw it (s) | 8.8 | 11 | 12.3 |
| detection (s) | 5.3 | 6.5 | 6.8 |
| promotion and routing (s) | 3 | 3 | 4.5 |
| RPO lost writes | 0 | 0 | 0 |

Writes lost in the ten planned failbacks: 0. Open question 6 answered: on
one Mac DR replication keeps up with 4 writes a second, so an unplanned site
loss lost nothing in ten runs; this is the lab's number, not a promise.
Detection is most of the RTO (HAProxy `fall 2` at 1 s, plus `podman kill`
of four containers taking about 3 s); the scripted decision adds 3 s of
Ansible start-up.

Decisions changed:

- **RTO** is measured as clients see it: from the first failed write to the
  first acknowledged write after it (the kill takes seconds and writes
  succeed meanwhile; the first report came out negative).
- **Act III**: `update-primary` is the normal path, not a fallback in name
  only: Frankfurt did not follow on its own in 10 of 10 drill runs (gotcha
  22, brief updated).
- **Fence**: rendered into the config without a reload; the runtime socket
  changes the running process (a reload would re-check every server).

Learned (the first drill found five bugs the probe could not):

- `vault operator unseal -` sends "-" as the key: unseal through the API with
  the JSON body on curl's stdin (also in `root-regen.sh`). The seal Vaults
  had never restarted before the drill.
- HAProxy resolved node addresses once: a restarted node had a new IP
  (L4TOUT). `resolvers` with Podman's DNS (gotcha 26).
- TLS passthrough kept the ticker's connection on demoted Dublin after the
  failback, through old workers left by earlier reloads: `on-marked-down
  shutdown-sessions` and `hard-stop-after 5s` (gotcha 25). `failback.yml`
  now waits for the ticker's first acknowledged write after the promotion.
- DR demote first made the performance demote a 403 (gotcha 27).
- zsh does not split an unquoted `$t`: a loop of make targets ran `make`
  with one odd argument and printed help with exit 0.

## Prompt 07: The situation room API (2026-11-10)

Done (the approved design, see `prompts/07_api.md`):

- `api/`: `server.js` (HTTPS with the lab leaf, routes, 405 with `Allow: GET`,
  one error shape with the request id, a JSON log line per request, the SSE
  hub: snapshot on connect, `x-accel-buffering: no`, 15 s ping, at most 20
  streams), `lib/fetch.js` (hard deadline), `lib/poll.js` (one loop for every
  source: no overlap, whole-snapshot swap, stale after 3 s, a log line per
  change only), `lib/vault.js` (health of every node, replication status of
  the first that answers, the role table, lag in WAL entries, clock skew from
  `server_time_utc`, `split_brain`), `lib/frontdoor.js` (stats CSV by
  header names), `lib/journal.js` (drill ids `^[A-Za-z0-9_-]{1,64}$` before
  any file access). 16 tests, including a dead site that accepts and never
  answers (reported within the deadline) and no token-shaped string in any
  response.
- `compose/app/compose.yaml` `vbal-api` (no Vault token, no agent, read-only
  root, `.build` and `config/sites.json` read-only), `verify.sh` section api.

Deviations: no `lag_seconds` (replication status has no time stamp per WAL
entry; the skew flag says when node clocks are off); the ticker's metrics
are JSON, so there is no metrics parser; `lib/layers.js` is three lines in
`server.js` (read `.build/layers.json`, cached 5 s).

Validated: `/api/sites` reported primary, performance secondary (lag 0), DR
secondary (lag 0); POST answered 405; `/healthz` ok; during a drill the
stream delivered a `site` event with Amsterdam `down` and its last known role.

## Prompt 08: The situation room console (2026-11-10)

Done:

- `web/` (React 19, Vite 8, Vault daylight glass; `vault-glass.css`,
  `shell.css`, `app.css`, `hooks.js`, `api.js` from vault_codex;
  `balancing.css` tokens only). One EventSource for the whole console
  (`useSituation.js`, pure reducer `situation.js`, 7 unit tests): snapshot on
  connect, then site, frontdoor, ticker, journal and drill events. Pages:
  Situation room (drill clock hero, front door, map west to east, ticker
  strip, two-primaries banner), Replication, Drill timeline (open drill live,
  else the latest closed one), Report (sentence from `report.json`, RTO
  split, RPO, last drills side by side), Layers. "Vault said" drawer with each
  site's raw answers. No button changes anything.
- nginx: TLS 1.3 with the lab leaf mounted read-only (no one-shot copy
  container), `/api` to the API over verified HTTPS, `/api/events` with
  `proxy_buffering off`. `DESIGN.md` with the Situation room section.
- `e2e/`: axe on every page at both sizes, Act 0, the drawer and the keys,
  the two-primaries fixture, the report against `report.json`, `@drill`
  (`make test-ui-drill`), `@shots` (`make screenshots`).

Validated: `make test-ui` 14 passed, axe 0 violations; `make test-ui-drill`
1 passed (2.6 min, a whole drill followed live through nginx);
`make screenshots` 10 images, reviewed and fixed in one pass.

Fixed after the screenshot review:

- RTO split: the "first write" part came out negative (the routed line is
  only as precise as a 1 s poll). It is now three parts: detection, decision,
  promotion and first write; every report regenerated.
- vault_codex's `.timeline li` (0,1,1) beat this page's `.tl` (0,1,0): the
  list class is now `.journal-list`.
- All-caps table headers, "1 writes", the empty timeline with ten closed
  drills, the pill showing "connecting" while the stream reconnects.
- `make lint`: 84 ansible-lint findings, 58 fixed by renaming tasks; a
  `.ansible-lint` skips only `name[template]` (task names keep sites in the
  middle, as the drill log reads) and `.yamllint` allows 280-character
  lines (one journal sentence per line). Four shellcheck warnings fixed.

## Prompt 09: Rehearsal, doctor, the daily cycle, show-ready (2026-11-10)

Done:

- `scripts/up.sh` (`make up`): clock, every site with its seal Vault unsealed
  first, the front door with its fence list, ticker, API and console, a DR
  token when under 4 h. A site the open drill killed is not started; the
  targets that finish the drill are printed.
- `scripts/show-ready.sh`, `scripts/doctor.sh` (host, 17 containers, leftovers,
  seals, quorum, replication, front door, DR token, seal tokens, the ticker's
  secret-id, licence, an open drill, audit log size),
  `scripts/rehearsal.sh` (17 counted checks, RTO bound 30 s),
  `scripts/backup.sh`, `scripts/site-destroy.sh` (typed site id).
- `make license-features` is now phase 7 (right after bootstrap, the first
  moment a cluster answers): a licence without replication stops the build
  before replication is attempted. `make app-up` starts ticker, API and
  console.

Validated: `make rehearsal` PASS 17 / FAIL 0 in 571 s (RTO 10.8 s);
`make doctor` nothing failing; `make down && make show-ready` green in
100 s (the prompt hoped for under a minute: twelve Vaults start seal first,
then Act 0 is validated and `verify` runs; this is the honest number);
`make backup` 161 MB (three seal Vaults, ams, fra; dub refused: "path
disabled in replication DR secondary mode", recorded).

Found by the first rehearsal (PASS 10 / FAIL 7), both fixed:

- **payments-eu reached Frankfurt after every failover.** The paths filter is
  keyed by the activation id, and `update-primary` uses a new one with no
  filter. The ten measured drill runs had the same leak; nothing checked
  for it then. Terraform now declares filters for the current id and the
  next two (Vault accepts a filter for an id with no token yet, tested),
  and `make repoint` and `make failback` move the window. Gotcha 28,
  RUNBOOK step 3.
- **`make up` after `make down` failed on Frankfurt:** an activated secondary
  started node 1 alone, which has no quorum and cannot report its mode.
  `sites-up.sh` now starts an activated secondary (no root token left in its
  init file) whole. Gotcha 29.
- `doctor` printed twelve container names as one (`vault_container` prints
  without a newline).

## Prompt 10: Docs and final validation (2026-11-10)

Done:

- `README.md` (what it proves and only illustrates, the measured numbers,
  prerequisites, quick start, daily use, where things are),
  `docs/RUNBOOK.md` (before, during, after, back home, with Vault's answers
  and what to do when they differ), `docs/ARCHITECTURE.md` (topology, who
  owns what, phases, tokens and policies, why Terraform plans clean after a
  failover, the front door's health logic, persistence), `docs/STORY.md`
  with a real report sentence, `CONTRIBUTING.md`, `CHANGELOG.md`.
- The no-ai-slop detect pass found five patterns (two colon reveals with a
  kicker, a binary contrast twice, a dramatic fragment, an invented example
  number); all fixed. No em dashes in any published file.
- `docs/capabilities.md` regenerated (`make probe` 59/0): Vault's "* "
  error bullets are escaped, prose wraps at 80, and the measured section
  survives a probe run.

### Correction after the final validation (2026-11-10)

The window of filters declared ahead was not enough: Vault keeps a filter
for an id it has not issued yet only until a restart **or a promotion**.
After a clean slate, the Act V failback needed `update-primary` (Frankfurt
did not follow home on its own, the first time in this phase) and the filter
for the new id was gone. The guard added to `tasks/follow.yml` refused the
attach, so nothing leaked. Final mechanism: `make up`, `make repoint` and
`make failback` apply the platform root on the primary that is active at
that moment, right before Frankfurt may attach (`failback.yml` split into
`failback.yml` and `failback-finish.yml` with Terraform between), and
`update-primary` refuses an id without a deny filter. Recovery of that
drill: `update-primary` with `fra-4`, 0 of 150 failback writes lost;
`validate` changed=0, plans empty, `verify` 43/0.

### A second rehearsal finding: contrast (2026-11-10)

axe failed the room at phone width only while a drill was open: the grey
(indigo) role pill measured 4.23:1 (`#4f5bd5` on `#dde0f4`). Reproduced on
demand with a throwaway drill journal, fixed in `balancing.css` (80% indigo,
20% ink: 5.4:1 there, 4.9:1 on a darker background, computed), verified with
the drill open (axe 20 of 20), throwaway journal removed. Also my own
mistake: `make report | head -1` cut `report.sh` before it closed the
journal, and the next drill correctly refused to start.

## Prompt 11: Ready for a public clone (2026-11-10)

Checked:

- Nothing private is visible to git (`prompts/`, `input/`, `article/`,
  `.claude/`, `.agents/`, `.codex/`, `AGENTS.md`, `.env`, `.secrets/`,
  `.build/`, `backups/`, keys). The lab CA certificate is generated
  (`make gen-certs`), not tracked.
- gitleaks: history clean; the tree's 39 findings are all in ignored files
  (`.secrets/`, `vault-tls/vault.key`); none in a file git would commit.
- Personal paths: none in any file git would commit. History: one, the
  scaffold's `sanity_check.md` in the first (pushed) commit. Not rewritten:
  the user decides. The remote's scaffold branch `initial-pr-scan` is still
  there: the user decides.
- Licence features fail early: `make license-features` is phase 7, right
  after the first cluster can answer (a licence is a signed blob that cannot
  be read offline).
- CI (`ci.yml`, `gitleaks.yml` from vault_codex) runs the linters, unit
  tests and gitleaks; no step needs a licence.

Not done, needs the user: the fresh-clone run (`git clone` of the local repo
into `$TMPDIR`, `make check`, `make env-init`) needs a commit first, and a
second `make lab` in a clone would collide with this lab's `vbal-` names and
ports, so it can only run after `make clean-slate`. Commit only when asked,
with `commit_gh --no-hook`.

Final rehearsal (2026-11-10, after every fix): PASS 17 / FAIL 0 in 592 s,
RTO 11.3 s. It exercised the risky path: in Act V Frankfurt did not follow
home on its own, `update-primary` attached it with `fra-5` after Terraform
had put that id's filter on Amsterdam, 0 of 225 failback writes were lost,
and `validate` then confirmed `payments-eu` absent on Frankfurt.

## Ponytail review and audit (2026-11-10)

Eight findings, all fixed:

1. Unfencing the only primary was impossible (`fence.yml` used
   `find_primary`, which skips fenced sites): the check now reads the other
   sites directly. Proven: fence then unfence of ams on a normal day.
2. `make doctor` used macOS-only `df -g` and `date -j`: now `df -Pk` and
   jq's `fromdateiso8601`.
3. CI did not run the ticker's tests (the RPO and RTO logic): added.
4. The API hid every lag during a drill (a dead site keeps its last role,
   primary): only sites that answer count; one more test.
5. The console's answer log was dead code (every call quiet, no reader):
   removed, with the unused `label` and `quiet` parameters.
6. Audit logs grew without limit (16 to 25 MB per active node in 1.3 h,
   measured): `scripts/audit-rotate.sh` moves a log past 64 MB to
   `audit.log.1` and sends Vault SIGHUP (it reopens the file; verified);
   `make up` runs it, `make audit-rotate` on demand, not during a drill.
   `doctor` warns past 128 MB.
7. KV v2 kept 10 versions of every ring slot: `max_versions = 1`.
8. `vbal_tick_ms` was passed to Ansible and read by nothing: removed.

Checked after the fixes: `make lint` clean, unit tests 9 + 9 + 17 + 7,
`make test-ui` 14 passed, `make verify` 43/0, `make tf-plan-all` empty.

## Prompt 12: The operator console (2026-11-10)

The user asked for the drill to be run from the console, with sign-in and
roles as in vault_dance and vault_codex, and agreed that the authority for
the decision must live outside the failure domain.

Done (D15, D16):

- `compose/identity/`: OpenLDAP (`dc=balancing,dc=lab`: vera viewer, oscar
  operator, ada admin; groups `drill-viewers`, `drill-operators`,
  `drill-admins`) federated read-only into Keycloak (realm `balancing`,
  port 19192), from vault_dance's scripts. Secrets are generated files in
  `.secrets/identity/` (`scripts/identity-secrets.sh`), not Vault KV: identity
  must work while a site is dead. `scripts/identity-up.sh` runs the two
  one-shots and removes them; `scripts/ldap-acl.sh` sets the access rules.
- API: Authorization Code + PKCE sign-in (vault_codex's BFF without the
  Vault login), `lib/oidc.js` verifies every token itself (RS256 via JWKS,
  issuer, audience, expiry), `lib/actions.js` is the drill as a step sequence
  (pure, shared with the runner), `/api/me`, `GET /api/actions`,
  `POST /api/actions/:id` (operators and admins, same origin, the site typed
  for a kill).
- `scripts/runner.js` on the host (127.0.0.1:19193, `make runner-up`): the
  API's shared secret, the person's token verified again, only the next
  step, arguments from `config/sites.json`, one at a time; the journal
  records the person (`VBAL_OPERATOR`). Phases `make identity-up` and
  `make runner-up` (15 phases).
- Console: sign-in and the person in the top bar, the "Next step" panel with
  the command, the reason when it is off, the run's output and who started it.

Validated: 37 script and API unit tests (the verifier refuses a forged,
re-signed, expired, wrong-issuer and wrong-audience token; the runner refuses
no secret, a forged token, a viewer, a step out of order, a second run);
`make test-ui` 17 passed (signed out, viewer, operator, axe signed in);
`make test-ui-drill-clicks`: oscar pressed all nine steps, 3.1 min, the
journal names him; `make lab` 169 s, every gate green (secret scan: 33
known values); `make verify` 49/0; lint clean.

Learned:

- osixia/openldap's default access rules hide `ou=people` from the
  federation's bind account: every sign-in failed with "Invalid username or
  password" (the user hit it first). vault_dance applies its rules with a
  separate script; `identity-up` now always runs `scripts/ldap-acl.sh`.
- Playwright's `page.request` uses Node's TLS and does not trust the lab CA:
  writes in the tests run inside the page (`fetch`), which also sends the
  real cookie and `Sec-Fetch-Site`.
- A container on `vbal-internal` reaches a host service bound to the Mac's
  127.0.0.1 at `host.containers.internal` (tested before choosing the
  runner's address).

## Review round after the article (2026-11-10)

A ponytail review and audit and a backend audit of prompt 12 found six
issues; all fixed:

- `runner.sh` trusted any live process with the runner's old pid: after a
  reboot `make down` could kill an unrelated program. `alive()` now checks the
  command line is `scripts/runner.js` (proved with a planted `sleep` pid).
- `identity-up` could not retry after a failed one-shot: the kept container
  blocked its own name. `one_shot` removes it first; its output stays in
  `.build/logs/identity-<service>.log` (proved with a planted container).
- The real `crossSiteWrite` and `safeReturn` had no test (the server test
  fakes them): `api/test/session.test.js`. It found a bug at once:
  `safeReturn(null)` returned the string "null", so `/auth/login` without
  `return=` sent the browser to `/auth/null` after sign-in.
- "Admin or operator may act" was written three times: `ACTING_ROLES` in
  `lib/oidc.js`, used by the runner, the API and the panel's text.
- The report's RTO parts did not add up to the total: detection started at
  the kill, the total at the first failed write (the user's run: 6 + 13.8 +
  2.6 under 20.6). All parts now start at the first failed write; the test
  checks they add up. All 22 drill reports regenerated from their journals
  (`node scripts/report.js <drill dir>`), the ten-run table in
  `docs/capabilities.md` recomputed from the same ten reports, with a
  decision row (also added to `drill-runs.sh`).
- The decision row said "scripted here: near zero" (scripted: 3.3 s; the
  user's own: 13.8 s): removed from `report.md` and the Report page.

Validated: unit tests 55 passed; lint clean; `make test-ui` 17 passed;
`make verify` 49/0; `make tf-plan-all` empty; screenshots refreshed.

Verification round (ponytail review and audit, backend audit, security
discipline) found one more: `scripts/runner.js` had no error handler on the
step's log stream or the `make` child, so a full disk or a `make` that cannot
start would crash the runner and kill the running step through a broken pipe.
Fixed: a failed log is reported once in the step's output and the step goes
on; a failed start is exit 127. Two runner tests (both fail on the old
runner). Unit tests 57 passed, `make verify` 49/0. Then sign-out: it was a
GET, so a page on another localhost port could sign the presenter out with an
image tag. `/auth/logout` is now POST only (GET 405, another site 403, 303
to Keycloak), from a form in the person menu; an API test and a browser test
(`make test-ui` 18 passed). Accepted by the user as they are: the CA subject
"Vault Codex Lab CA", the home path in the first commit, the remote branch
`initial-pr-scan`.
