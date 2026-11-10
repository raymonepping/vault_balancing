terraform {
  required_version = ">= 1.14"
  # State lives in .secrets/terraform/platform/ (scripts/tf.sh sets the path).
  backend "local" {}
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "5.13.0"
    }
  }
}

# Address, CA and the tf-platform token come from scripts/tf.sh, which points
# at whichever site Vault reports as primary now (D8). The provider's child
# token is a subset of vbal-tf-platform.
provider "vault" {
  address      = var.vault_addr
  ca_cert_file = var.vault_cacert
}

# One provider per namespace (probe P16: no perpetual diff).
provider "vault" {
  alias        = "payments"
  address      = var.vault_addr
  ca_cert_file = var.vault_cacert
  namespace    = vault_namespace.payments.path
}

provider "vault" {
  alias        = "payments_eu"
  address      = var.vault_addr
  ca_cert_file = var.vault_cacert
  namespace    = vault_namespace.payments_eu.path
}
