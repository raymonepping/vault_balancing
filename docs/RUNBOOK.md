# Runbook: a site dies

The drill as an operator would run it. Each step is one make target; each
target refuses a wrong state with Vault's own answer and writes one line to
the drill journal (`.build/drill/<id>/journal.jsonl`). The situation room
follows along; it never changes anything.

## From the console

Sign in at `https://localhost:19190/` as an operator (`oscar`) or admin
(`ada`). The situation room shows the next step with its make target; press
it (killing a site asks for the site's id). The step runs on the host
exactly as the make target below does, its output appears under the button,
and the journal records who pressed it. A viewer (`vera`) sees the same
panel and why she cannot press it. Steps run in order and one at a time:
the runner refuses anything else. `make runner-status` says whether the
buttons can work; the terminal always can.

## Before: every day

| Check | Command | Vault's answer you want |
| --- | --- | --- |
| A DR operations token exists, from the current primary, more than 2 h left | `make doctor` | `DR operations token: 7h left, from ams` |
| Both secondaries stream | `make vault-status` | fra `perf:secondary`, dub `dr:secondary`, every dub node 472 |
| The front door sends writes to one node | `make frontdoor-status` | `primary`: one server UP (200); `regional`: three UP |
| Clocks agree | `make clock-sync` | skew under 5 s |

The DR operations token is a batch token: it cannot be renewed. `make up` and
`make show-ready` mint a fresh one when less than 4 h is left. Once the
primary is gone, no new one can be minted, so the daily check keeps one ready.

## During: the primary site is gone

1. **Confirm it.** `make vault-status`: the site's nodes are unreachable, not
   sealed. `make frontdoor-status`: its servers are DOWN. Writes fail;
   Frankfurt still serves reads (`make ticker-status`).
2. **Promote the DR secondary.** `make promote SITE=dub`. The DR operations
   token goes in the `X-Vault-Token` header. Vault answers 200; within about
   3 s the front door routes writes to Dublin on its own, because Dublin's
   active node now answers 200. The playbook then measures the first
   acknowledged write (RTO) and re-reads every write of the minute before the
   outage (RPO), and mints a fresh DR token on Dublin.
   - Vault answers "DR operation token was not provided": the token file is
     empty or missing. Without a token minted before the outage there is no
     promotion; this is the failure the daily check prevents.
   - "invalid dr operation token": a service token was used, or it expired.
3. **Point Frankfurt at Dublin.** `make repoint SITE=fra TO=dub` waits 20 s
   for Frankfurt to follow on its own, then runs `update-primary` with a
   fresh activation id and a batch token minted on Dublin. In ten drill runs
   Frankfurt never followed on its own here, so expect the `update-primary`.
   Never run `update-primary` on a secondary that already follows: Vault
   answers "error authing for bootstrap" and the activation token is spent.
   A performance paths filter is keyed by the secondary's activation id, and
   `update-primary` uses a new one: a filter must exist for the new id before
   Frankfurt attaches, or `payments-eu` replicates to Frankfurt. Vault keeps
   a filter for an id it has not issued yet only until the next restart or
   promotion, so `make repoint` first applies Terraform on the active primary
   (filters for the current id and the next two), then attaches, and
   `update-primary` refuses an id without a filter. The first rehearsal
   caught the leak; the guard caught the second gap.

## After: the old primary comes back

1. **Fence it first.** `make fence SITE=ams`. A returned Amsterdam believes it
   is still primary and answers 200; without the fence the front door would
   send writes to two primaries. The fence is written into the HAProxy
   config (it survives a restart) and applied to the running HAProxy at once.
   `make site-up SITE=ams` refuses to start an unfenced ex-primary.
2. **Start it.** `make site-up SITE=ams`: its seal Vault starts and is
   unsealed first, then its nodes. The journal records what each node says
   it is: `dr=primary performance=primary`.
3. **Demote it and attach it to Dublin.** `make demote SITE=ams TO=dub`.
   Performance first, then DR: after the DR demotion the cluster refuses every
   token. It then streams from Dublin and every node answers 472.
4. **Unfence it.** `make unfence SITE=ams`. It answers 472, so the front door
   keeps it out of the writes anyway. Unfencing a site that still says
   primary while another site is primary is refused.

## Back home: the planned failback

1. `make failback`: waits until Amsterdam's WAL index reaches Dublin's,
   demotes Dublin, promotes Amsterdam with the DR token, waits until clients
   write again, re-attaches Dublin as DR secondary, applies Terraform on
   Amsterdam (the paths filters), points Frankfurt home (on its own in most
   runs, `update-primary` otherwise), and re-reads every write acknowledged
   during the failback: zero may be missing.
2. `make report`: the epilogue in `.build/drill/<id>/report.md`, with the
   sentence for the room, the RTO split, the RPO, the ticker's journal of the
   window and Vault's audit record of every replication call. It closes the
   drill.

## When something else goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| A site's nodes exit at start | its seal Vault is sealed (Shamir, after any restart) | `make unseal SITE=<site>`, then `make up` |
| Front door shows `L4TOUT` for a site that is running | HAProxy could not reach a new container address | it resolves through Podman's DNS every 2 s; `make frontdoor-up` re-renders and reloads |
| The ticker keeps failing after the primary changed | a kept-alive connection to a demoted node | the front door cuts sessions of nodes marked down; `podman restart vbal-haproxy` cuts all |
| `make up` does not start a site | the open drill killed it | it prints the targets that finish the drill |
| Two primaries in the situation room | an ex-primary returned unfenced | `make fence SITE=<site>` now, then demote it |
| A person cannot sign in ("Invalid username or password") with the right password | Keycloak's LDAP account cannot read the people | `make identity-up` (it re-applies the access rules) |
| The console's button answers "the drill runner does not answer" | the runner is not running | `make runner-up` |
