# autounseal (each seal Vault): the only thing a cluster node's seal token may do.
path "transit/encrypt/autounseal" {
  capabilities = ["update"]
}

path "transit/decrypt/autounseal" {
  capabilities = ["update"]
}
