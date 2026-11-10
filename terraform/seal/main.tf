# terraform/seal: the declared half of one site's seal Vault (phase 3), one state per
# site (scripts/tf.sh seal-<site>).
# Ansible initialised the seal Vault and minted the token this root runs on
# (phase 2); Ansible mints the per-node seal tokens from the role below
# (phase 4). This root only declares.

resource "vault_mount" "transit" {
  path        = "transit"
  type        = "transit"
  description = "Auto-unseal for vault-${var.site}-1..3"
}

resource "vault_transit_secret_backend_key" "autounseal" {
  backend          = vault_mount.transit.path
  name             = "autounseal"
  deletion_allowed = false
}

resource "vault_policy" "autounseal" {
  name   = "autounseal"
  policy = file("${path.module}/../../vault/policies/seal/autounseal.hcl")
}

# D5: one periodic orphan token per node comes from this role (Ansible).
resource "vault_token_auth_backend_role" "autounseal" {
  role_name               = "autounseal"
  allowed_policies        = [vault_policy.autounseal.name]
  orphan                  = true
  renewable               = true
  token_period            = 2592000 # 720h, in seconds (gotcha 10)
  token_type              = "service"
  token_no_default_policy = true
}

resource "vault_audit" "file" {
  type = "file"
  path = "file"
  options = {
    file_path = "/vault/audit/audit.log"
    mode      = "0600"
  }
}
