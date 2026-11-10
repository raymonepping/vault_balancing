output "transit_path" {
  value = vault_mount.transit.path
}

output "key_name" {
  value = vault_transit_secret_backend_key.autounseal.name
}

output "token_role" {
  value = vault_token_auth_backend_role.autounseal.role_name
}
