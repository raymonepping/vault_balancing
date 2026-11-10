terraform {
  required_version = ">= 1.14"
  # State lives in .secrets/terraform/probe/ (scripts/tf.sh); make probe removes it.
  backend "local" {}
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "5.13.0"
    }
  }
}

provider "vault" {
  address      = var.vault_addr
  ca_cert_file = var.vault_cacert
}

# The namespaced provider prompt 04 uses (P16).
provider "vault" {
  alias        = "tfprobe"
  address      = var.vault_addr
  ca_cert_file = var.vault_cacert
  namespace    = vault_namespace.tfprobe.path
}
