# vbal-ansible-platform: Ansible on the replicated cluster (D7). Order and
# moment: enabling replication, activation tokens for secondaries, demotion,
# update-primary, the DR operations token (D9), the ticker's secret-id, Raft
# health and snapshots, step-down, and the read-only checks of validate and
# verify. It may NOT create a mount, write an ACL policy, or read the
# ticker's data (D8).
# Written complete in prompt 02 on ams; replication carries it to every site.

# ── Replication (Vault requires sudo on sys/replication/*) ───────────────────
path "sys/replication/status" { capabilities = ["read"] }
path "sys/replication/performance/status" { capabilities = ["read"] }
path "sys/replication/dr/status" { capabilities = ["read"] }
path "sys/replication/performance/primary/enable" { capabilities = ["update", "sudo"] }
path "sys/replication/performance/primary/secondary-token" { capabilities = ["update", "sudo"] }
path "sys/replication/performance/primary/revoke-secondary" { capabilities = ["update", "sudo"] }
path "sys/replication/performance/primary/demote" { capabilities = ["update", "sudo"] }
path "sys/replication/performance/primary/disable" { capabilities = ["update", "sudo"] }
path "sys/replication/performance/primary/paths-filter/*" { capabilities = ["read"] }
path "sys/replication/performance/secondary/update-primary" { capabilities = ["update", "sudo"] }
path "sys/replication/performance/secondary/promote" { capabilities = ["update", "sudo"] }
path "sys/replication/dr/primary/enable" { capabilities = ["update", "sudo"] }
path "sys/replication/dr/primary/secondary-token" { capabilities = ["update", "sudo"] }
path "sys/replication/dr/primary/revoke-secondary" { capabilities = ["update", "sudo"] }
path "sys/replication/dr/primary/demote" { capabilities = ["update", "sudo"] }
path "sys/replication/dr/primary/disable" { capabilities = ["update", "sudo"] }

# ── Tokens: the DR operations token and Ansible's own batch token, both from
#    roles Terraform declares (allowed_policies is the boundary) ─────────────
path "auth/token/create/vbal-dr-operations" { capabilities = ["update"] }
path "auth/token/create/vbal-ansible-batch" { capabilities = ["update"] }
path "auth/token/lookup" { capabilities = ["update"] }
path "auth/token/lookup-self" { capabilities = ["read"] }

# ── The ticker's credential (the one hand-over) ──────────────────────────────
path "payments/auth/approle/role/ticker/role-id" { capabilities = ["read"] }
path "payments/auth/approle/role/ticker/secret-id" { capabilities = ["update"] }
path "payments/auth/approle/role/ticker/secret-id/lookup" { capabilities = ["update"] }

# ── Cluster operations ───────────────────────────────────────────────────────
path "sys/storage/raft/configuration" { capabilities = ["read"] }
path "sys/storage/raft/snapshot" { capabilities = ["read"] }
path "sys/storage/raft/autopilot/state" { capabilities = ["read"] }
path "sys/step-down" { capabilities = ["update", "sudo"] }
path "sys/license/status" { capabilities = ["read"] }
path "sys/health" { capabilities = ["read"] }

# ── Read-only checks (validate, verify, doctor) ──────────────────────────────
path "sys/mounts" { capabilities = ["read"] }
path "sys/namespaces" { capabilities = ["list", "read"] }
path "sys/namespaces/*" { capabilities = ["read"] }
path "sys/audit" { capabilities = ["read", "sudo"] }
path "sys/policies/acl/vbal-app-*" { capabilities = ["read"] }
path "sys/policies/acl/vbal-dr-operations" { capabilities = ["read"] }
path "payments/auth/approle/role/ticker" { capabilities = ["read"] }

# Break glass (make root-regen): Vault 2.x requires a token as well as the key
# share for sys/generate-root (HCSEC-2026-08). root-regen.sh sends this token.
path "sys/generate-root/*" { capabilities = ["create", "read", "update", "delete", "sudo"] }

# ── Never ────────────────────────────────────────────────────────────────────
path "sys/mounts/*" { capabilities = ["deny"] }
path "sys/auth/*" { capabilities = ["deny"] }
path "payments/kv/data/*" { capabilities = ["deny"] }
path "payments-eu/kv/data/*" { capabilities = ["deny"] }
path "sys/policies/acl/vbal-tf-*" { capabilities = ["deny"] }
path "sys/policies/acl/vbal-ansible-*" { capabilities = ["deny"] }
