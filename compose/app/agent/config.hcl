# App agent: identity cryptolab-api on vault-1. Keeps a token file fresh for
# the API, which reads the file on every Vault call, never an env var.
pid_file = "/tmp/pidfile"

vault {
  address = "https://vault-1:8200"
  ca_cert = "/vault/tls/ca-chain.pem"
}

auto_auth {
  method "approle" {
    mount_path  = "auth/approle"
    min_backoff = "2s"
    max_backoff = "30s"
    config = {
      role_id_file_path                   = "/run/approle/cryptolab-api/role-id"
      secret_id_file_path                 = "/run/approle/cryptolab-api/secret-id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/vault/secrets/token"
      # gid 1000 is the api container's group.
      mode = 0640
    }
  }
}
