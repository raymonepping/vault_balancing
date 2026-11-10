# The ticker's Vault Agent: AppRole ticker in namespace payments (D10). Logs
# in THROUGH THE FRONT DOOR, so it reaches whichever site is primary. The
# token is a batch token (Terraform role): it cannot be renewed, so the agent
# logs in again before it expires. The ticker reads the sink on every request.
pid_file = "/tmp/pidfile"

vault {
  address = "https://frontdoor:8443"
  ca_cert = "/vault/tls/ca-chain.pem"
}

auto_auth {
  method "approle" {
    namespace   = "payments"
    mount_path  = "auth/approle"
    min_backoff = "2s"
    max_backoff = "10s"
    config = {
      role_id_file_path                   = "/run/approle/role-id"
      secret_id_file_path                 = "/run/approle/secret-id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/sink/token"
      # gid 1000 is the ticker container's group.
      mode = 0640
    }
  }
}
