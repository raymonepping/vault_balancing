# Architecture

> **Terraform builds the house. Ansible decorates it. Vault keeps the keys.
> Make is the front door.**

## Topology

```text
network vbal-internal (TLS 1.3 everywhere, lab CA)
 ├─ site ams (primary):              seal-ams ── vault-ams-1..3  (Raft, seal "transit")
 ├─ site fra (performance secondary): seal-fra ── vault-fra-1..3
 ├─ site dub (DR secondary):          seal-dub ── vault-dub-1..3
 ├─ frontdoor: HAProxy, TLS passthrough
 │     writes  :8443 (published 19180) → backend primary  = ams + dub nodes, health 200 only
 │     reads   :8444 (internal)        → backend regional = fra nodes, health 200 or 473
 │     stats   :8404 (published 19181)
 ├─ app: ticker + its Vault Agent, api (19191), web (19190)
 ├─ identity: OpenLDAP → Keycloak (19192), outside the three sites
 └─ host: Terraform, Ansible, and the drill runner (127.0.0.1:19193) the console's buttons use
```

Each site is independent: its own seal Vault, Transit key and volumes. A dead
site takes its seal Vault with it. `config/sites.json` holds the topology;
ports live in `config/defaults.conf` (overridable in `.env`).

## Who owns what

| Tool | Owns | Never |
| --- | --- | --- |
| Make | the command surface; `make lab` walks `scripts/phases.txt` | logic |
| Compose (`scripts/compose.sh`) | containers, network, volumes; one file for the three sites | Vault configuration |
| Terraform (`scripts/tf.sh`) | seal Transit keys and token roles; namespaces, KV, AppRole, policies, token roles, audit, the paths filter on the current primary | replication state, promotions, tokens |
| Ansible (`scripts/ansible.sh`) | init, scoped and seal tokens, root revocation, replication, the DR token, every act of the drill, validation | declared structure |
| HAProxy | which node gets client traffic, from each node's own health code | deciding who is primary |
| Vault | every replication decision | being simulated |
| Keycloak (from OpenLDAP) | who may press a drill button: the signed `groups` claim, verified by the API and again by the runner | living inside a site: the decision to promote must survive the site that dies |
| The runner (`scripts/runner.js`) | starting the next step's make target for a verified operator, one at a time | choosing the arguments (they come from `config/sites.json`) or skipping a step |

## The phases

`seals-up`, `seal-init`, `tf seal` (one root per site), `seal-tokens`,
`sites-up`, `bootstrap`, `tf platform`, `replicate`, `paths-filter`,
`frontdoor-up`, `app-up`, `validate`; then the gates: idempotency (every
Ansible phase changed=0), drift (every plan empty), secret scan, boundary.

## Tokens and policies

| Token | Where | May | May not |
| --- | --- | --- | --- |
| `tf-seal-<site>` | each seal Vault | Transit mount and key, `autounseal` policy and token role, audit | mint a seal token, touch its own policy |
| `ansible-seal-<site>` | each seal Vault | mint seal tokens from the role, snapshots, `sys/generate-root/*` | change the role, the policy or the mount |
| `tf-platform` | the replicated cluster | namespaces, mounts, AppRole, `vbal-app-*` and `vbal-dr-operations` policies, token roles, audit, paths filter | promote, demote, issue activation tokens, mint from the token roles, read the ticker's data |
| `ansible-platform` | the replicated cluster | replication (enable, activation tokens, demote, update-primary), mint the DR token and its own batch token from the roles, the ticker's secret-id, Raft reads, `sys/generate-root/*` | mounts, ACL writes, the ticker's data |
| DR operations token | batch, 8 h, from role `vbal-dr-operations` | promote and update-primary on a DR secondary | anything else |
| ticker | batch, 15 min, AppRole in `payments` | its ring of keys | anything else |

No root token survives bootstrap. A secondary's own root token is used once,
to activate it, and dies with its token store. `make boundary` proves every
row (55 checks).

## Why Terraform plans clean after a failover

The platform root targets whichever site Vault reports as primary
(`vault_primary` in `scripts/common.sh` reads each site's unauthenticated
`sys/replication/status`). DR replication carries the structure, the token
store and the Terraform token, so a plan against Dublin after a promotion
finds exactly what it declared on Amsterdam.

## The front door's health logic

`GET /v1/sys/health` codes carry the role: 200 active primary or active
performance secondary, 473 performance standby, 472 DR secondary (active or
standby), 503 sealed. The `primary` backend accepts only 200, so exactly one
server is up: the active node of whichever site is primary. HAProxy never
decides; when Dublin is promoted, its active node starts answering 200 and
HAProxy follows within two checks. Settings that matter: `init-state down`
(no node takes traffic before two good checks), `on-marked-down
shutdown-sessions` (kept-alive client connections to a demoted node are cut),
`hard-stop-after 5s` (a reload cannot keep old sessions), `resolvers` through
Podman's DNS (a restarted node may have a new address). A fence is a server
rendered `disabled`, so it survives a restart.

## Persistence

| Class | Storage | What |
| --- | --- | --- |
| Persistent | named volumes, `io.vbal.data=true` | twelve Raft data and audit volumes, the ticker's journal and seq counter |
| Host | bind mounts of tracked or `.secrets/` paths | HCL templates, TLS, licence, seal tokens, init files, Terraform state |
| Ephemeral | tmpfs | the ticker agent's token sink, nginx and API temp |

`make down` never removes a volume. A drill never deletes one: a dead site is
killed, not destroyed (`make site-destroy` is the hard variant, with a typed
confirmation).
