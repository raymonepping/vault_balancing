# terraform/probe: P16. The resource shapes prompt 04 uses, against the scratch
# primary: a namespace, a mount through a namespaced provider, the performance
# paths filter as vault_generic_endpoint, and a root-namespace audit device.
# Applied twice, then planned: the plan must be empty (no perpetual diff).

resource "vault_namespace" "tfprobe" {
  path = "tfprobe"
}

resource "vault_mount" "kv" {
  provider = vault.tfprobe
  path     = "kv"
  type     = "kv"
  options  = { version = "2" }
}

resource "vault_generic_endpoint" "paths_filter" {
  path                 = "sys/replication/performance/primary/paths-filter/b-3"
  ignore_absent_fields = true
  data_json = jsonencode({
    mode  = "deny"
    paths = ["payments-eu/"]
  })
}

resource "vault_audit" "file" {
  type = "file"
  path = "file"
  options = {
    file_path = "/vault/file/probe-audit.log"
    mode      = "0600"
  }
}
