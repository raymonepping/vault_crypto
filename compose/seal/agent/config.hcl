# Seal agent: identity seal-autounseal on vault-s. Keeps the Transit seal
# token fresh in the `seal-token` volume; vault-1 reads it at process start.
pid_file = "/tmp/pidfile"

vault {
  address = "https://vault-s:8200"
  ca_cert = "/vault/tls/ca-chain.pem"
}

auto_auth {
  method "approle" {
    mount_path  = "auth/approle"
    min_backoff = "2s"
    max_backoff = "30s"
    config = {
      role_id_file_path                   = "/run/approle/seal-autounseal/role-id"
      secret_id_file_path                 = "/run/approle/seal-autounseal/secret-id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/vault/secrets/transit-token"
      mode = 0640
    }
  }
}
