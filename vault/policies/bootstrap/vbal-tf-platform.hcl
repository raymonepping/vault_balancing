# vbal-tf-platform: Terraform root terraform/platform on the primary (D7, D8).
# Declared, plannable structure: the namespaces payments and payments-eu, their
# KV and AppRole mounts, the ticker's role and policy, the DR operations policy
# and token role, the audit device, the performance paths filter. It may NOT
# promote, demote, enable replication or mint a token from those roles:
# replication state and tokens have a moment, and that is Ansible's job.
# Written complete in prompt 02 on ams; replication carries it to every site,
# so the same token plans against whichever site is primary (D8).

# ── Namespaces ───────────────────────────────────────────────────────────────
path "sys/namespaces" { capabilities = ["list"] }
path "sys/namespaces/payments" { capabilities = ["create", "read", "update", "delete"] }
path "sys/namespaces/payments-eu" { capabilities = ["create", "read", "update", "delete"] }

# ── Mounts inside the namespaces ─────────────────────────────────────────────
path "payments/sys/mounts" { capabilities = ["read"] }
path "payments/sys/mounts/kv" { capabilities = ["create", "read", "update", "delete"] }
path "payments/sys/mounts/kv/tune" { capabilities = ["read", "update"] }
path "payments-eu/sys/mounts" { capabilities = ["read"] }
path "payments-eu/sys/mounts/kv" { capabilities = ["create", "read", "update", "delete"] }
path "payments-eu/sys/mounts/kv/tune" { capabilities = ["read", "update"] }
path "payments-eu/kv/data/seed" { capabilities = ["create", "read", "update", "delete"] }
path "payments-eu/kv/metadata/seed" { capabilities = ["read", "delete"] }
path "payments-eu/kv/config" { capabilities = ["read", "update"] }
path "payments/kv/config" { capabilities = ["read", "update"] }

# ── AppRole in payments (enable and tune need sudo; the provider reads sys/mounts/auth) ─
path "payments/sys/auth" { capabilities = ["read"] }
path "payments/sys/auth/approle" { capabilities = ["create", "read", "update", "delete", "sudo"] }
path "payments/sys/auth/approle/tune" { capabilities = ["read", "update", "sudo"] }
path "payments/sys/mounts/auth/approle" { capabilities = ["read"] }
path "payments/sys/mounts/auth/approle/tune" { capabilities = ["read", "update", "sudo"] }
path "payments/auth/approle/role/ticker" { capabilities = ["create", "read", "update", "delete"] }
path "payments/auth/approle/role/ticker/role-id" { capabilities = ["read"] }

# ── Policies: the app's and the DR operations policy, never a tool's own ─────
path "sys/policies/acl" { capabilities = ["list"] }
path "sys/policies/acl/vbal-dr-operations" { capabilities = ["create", "read", "update", "delete"] }
path "sys/policies/acl/vbal-app-*" { capabilities = ["create", "read", "update", "delete"] }
path "payments/sys/policies/acl" { capabilities = ["list"] }
path "payments/sys/policies/acl/vbal-app-*" { capabilities = ["create", "read", "update", "delete"] }

# ── Token roles: the DR operations batch token (D9) and Ansible's batch token
#    for performance secondaries (gotcha 19). Declaring them, not using them. ─
path "auth/token/roles/vbal-dr-operations" { capabilities = ["create", "read", "update", "delete"] }
path "auth/token/roles/vbal-ansible-batch" { capabilities = ["create", "read", "update", "delete"] }

# ── Audit (sudo: Vault requires it on sys/audit/*) ───────────────────────────
path "sys/audit" { capabilities = ["read", "sudo"] }
path "sys/audit/file" { capabilities = ["create", "read", "update", "delete", "sudo"] }

# ── The performance paths filter for Frankfurt (open question 7) ─────────────
path "sys/replication/performance/primary/paths-filter/*" { capabilities = ["create", "read", "update", "delete", "sudo"] }

# ── The provider ─────────────────────────────────────────────────────────────
path "auth/token/create" { capabilities = ["update"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "sys/license/status" { capabilities = ["read"] }

# ── Never ────────────────────────────────────────────────────────────────────
path "sys/replication/dr/secondary/promote" { capabilities = ["deny"] }
path "sys/replication/dr/primary/demote" { capabilities = ["deny"] }
path "sys/replication/performance/primary/demote" { capabilities = ["deny"] }
path "sys/replication/performance/primary/secondary-token" { capabilities = ["deny"] }
path "sys/replication/dr/primary/secondary-token" { capabilities = ["deny"] }
path "auth/token/create/vbal-dr-operations" { capabilities = ["deny"] }
path "auth/token/create/vbal-ansible-batch" { capabilities = ["deny"] }
path "payments/auth/approle/role/ticker/secret-id" { capabilities = ["deny"] }
path "payments/kv/data/*" { capabilities = ["deny"] }
path "sys/policies/acl/vbal-tf-*" { capabilities = ["deny"] }
path "sys/policies/acl/vbal-ansible-*" { capabilities = ["deny"] }
