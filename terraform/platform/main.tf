# terraform/platform: the declared structure the drill protects (phase 7),
# written on the current primary and carried to the other sites by
# replication. Never replication state, promotions or tokens (D8): those have
# a moment, and that is Ansible's job.

# ── Namespaces ───────────────────────────────────────────────────────────────
resource "vault_namespace" "payments" {
  path = "payments"
}

# Frankfurt must not see this one (open question 7, the paths filter below).
resource "vault_namespace" "payments_eu" {
  path = "payments-eu"
}

# ── payments: the ticker's data and its AppRole (D10) ────────────────────────
resource "vault_mount" "payments_kv" {
  provider    = vault.payments
  path        = "kv"
  type        = "kv"
  options     = { version = "2" }
  description = "The ticker's ring of 7200 keys (D10)"
}

# The RPO check reads only a slot's newest value: keep one version per slot,
# so the ring of 7200 keys really is bounded (KV v2 keeps 10 by default).
resource "vault_kv_secret_backend_v2" "payments_kv" {
  provider     = vault.payments
  mount        = vault_mount.payments_kv.path
  max_versions = 1
}

resource "vault_policy" "ticker" {
  provider = vault.payments
  name     = "vbal-app-ticker"
  policy   = file("${path.module}/../../vault/policies/app-ticker.hcl")
}

resource "vault_auth_backend" "payments_approle" {
  provider = vault.payments
  type     = "approle"
  path     = "approle"
}

# A batch token: a performance secondary does not know the primary's service
# tokens, but accepts a parentless batch token from it (probe P18, gotcha 19).
resource "vault_approle_auth_backend_role" "ticker" {
  provider           = vault.payments
  backend            = vault_auth_backend.payments_approle.path
  role_name          = "ticker"
  token_type         = "batch"
  token_policies     = [vault_policy.ticker.name]
  token_ttl          = 900
  token_max_ttl      = 900
  secret_id_ttl      = 86400
  secret_id_num_uses = 0
}

# ── payments-eu: one synthetic secret, absent on Frankfurt ───────────────────
resource "vault_mount" "payments_eu_kv" {
  provider    = vault.payments_eu
  path        = "kv"
  type        = "kv"
  options     = { version = "2" }
  description = "EU-only data: the paths filter keeps it out of Frankfurt"
}

resource "vault_kv_secret_v2" "payments_eu_seed" {
  provider = vault.payments_eu
  mount    = vault_mount.payments_eu_kv.path
  name     = "seed"
  data_json = jsonencode({
    note = "synthetic: this namespace must not replicate to Frankfurt"
  })
}

# ── DR operations (D9): the policy and the batch-token role ──────────────────
# Vault keeps no max TTL on a batch-token role (it reads back 0, a perpetual
# diff): Ansible sets the TTL when it mints the token (VBAL_DR_TOKEN_TTL).
resource "vault_policy" "dr_operations" {
  name   = "vbal-dr-operations"
  policy = file("${path.module}/../../vault/policies/dr-operations.hcl")
}

resource "vault_token_auth_backend_role" "dr_operations" {
  role_name        = "vbal-dr-operations"
  allowed_policies = [vault_policy.dr_operations.name]
  orphan           = true
  renewable        = false
  token_type       = "batch"
}

# Ansible's own batch token for a performance secondary (update-primary after
# a planned failback, probe P13): the same policy it already holds, nothing more.
resource "vault_token_auth_backend_role" "ansible_batch" {
  role_name        = "vbal-ansible-batch"
  allowed_policies = ["vbal-ansible-platform"]
  orphan           = true
  renewable        = false
  token_type       = "batch"
}

# ── Audit: every node of every site writes its own log (replicated device) ───
resource "vault_audit" "file" {
  type = "file"
  path = "file"
  options = {
    file_path     = "/vault/audit/audit.log"
    mode          = "0600"
    hmac_accessor = "true"
    log_raw       = "false"
  }
}

# ── The performance paths filter for Frankfurt (probe P15, P16) ──────────────
# One filter per activation id: the current one and the next two, so the id a
# drill allocates for update-primary is filtered before Frankfurt attaches
# with it (found by the first rehearsal: payments-eu reached Frankfurt after a
# failover). make repoint and make failback re-apply this root afterwards.
resource "vault_generic_endpoint" "fra_paths_filter" {
  for_each             = toset(var.fra_secondary_ids)
  path                 = "sys/replication/performance/primary/paths-filter/${each.value}"
  ignore_absent_fields = true
  data_json = jsonencode({
    mode  = "deny"
    paths = ["${vault_namespace.payments_eu.path}/"]
  })
}
