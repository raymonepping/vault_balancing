variable "vault_addr" {
  description = "The site's seal Vault on its published loopback port (scripts/tf.sh)."
  type        = string
}

variable "vault_cacert" {
  description = "The lab CA chain (vault-tls/ca-chain.pem)."
  type        = string
}

variable "site" {
  description = "The site this seal Vault belongs to (ams, fra, dub); set by scripts/tf.sh."
  type        = string
}
