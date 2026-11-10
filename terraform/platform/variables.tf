variable "vault_addr" {
  description = "The current primary's node on its published loopback port (scripts/tf.sh)."
  type        = string
}

variable "vault_cacert" {
  description = "The lab CA chain (vault-tls/ca-chain.pem)."
  type        = string
}

variable "fra_secondary_ids" {
  description = "Frankfurt's current activation id and the next two (scripts/tf.sh, from .secrets/vault/replication-ids.json). The paths filter is keyed by id (probe P15), and a drill's update-primary uses a new one: the filter must exist for it before Frankfurt attaches (Vault accepts a filter for an id with no token yet). Empty until replicate."
  type        = list(string)
  default     = []
}
