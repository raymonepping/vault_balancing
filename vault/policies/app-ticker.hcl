# vbal-app-ticker (namespace payments): the ticker writes and reads its ring
# of keys (D10), nothing else. Terraform writes it (prompt 04).
path "kv/data/ticker/*" {
  capabilities = ["create", "update", "read"]
}
