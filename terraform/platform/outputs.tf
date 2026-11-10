# Identifiers only: a role-id is not a credential (the secret-id is, and
# Terraform never sees one).
output "ticker_role_id" {
  value = vault_approle_auth_backend_role.ticker.role_id
}

output "namespaces" {
  value = [vault_namespace.payments.path, vault_namespace.payments_eu.path]
}

output "fra_paths_filter" {
  value = length(var.fra_secondary_ids) == 0 ? "not set (Frankfurt not activated yet)" : "deny payments-eu/ for ${join(", ", var.fra_secondary_ids)}"
}
