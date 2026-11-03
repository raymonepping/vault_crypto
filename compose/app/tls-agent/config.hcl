# TLS agent: identity web-tls on vault-1. Renders the web server's own
# certificate from pki-classic-int/issue/web and re-issues it before it expires.
# nginx watches the file and reloads.
#
# One file holds leaf, issuing CA and key, written atomically: nginx can never
# load a certificate with the previous key. CN and TTL come from
# config/defaults.conf (VCRY_WEB_CN, VCRY_WEB_TTL) through the environment.
#
# `secret`, not `pkiCert`: measured on Vault Agent 2.0.4, pkiCert re-issued a
# 2-minute certificate only after ~9 minutes (and let the 15-minute web
# certificate expire). `secret` on pki-int/issue re-renders at
# lease_renewal_threshold of the certificate's lifetime — 2/3 here. The cost:
# every agent restart issues a new certificate instead of reusing the file.
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
      role_id_file_path                   = "/run/approle/web-tls/role-id"
      secret_id_file_path                 = "/run/approle/web-tls/secret-id"
      remove_secret_id_file_after_reading = false
    }
  }

  # The token stays inside this container (tmpfs); only the certificate leaves.
  sink "file" {
    config = {
      path = "/vault/secrets/token"
      mode = 0600
    }
  }
}

template_config {
  exit_on_retry_failure   = false
  lease_renewal_threshold = 0.66
}

template {
  destination = "/vault/web-tls/web.pem"
  # gid 1000 is the web container's group.
  perms       = "0640"
  contents    = <<-EOT
  {{- with secret "pki-classic-int/issue/web" (printf "common_name=%s" (env "VCRY_WEB_CN")) "alt_names=localhost,vcry-web" "ip_sans=127.0.0.1" (printf "ttl=%s" (env "VCRY_WEB_TTL")) -}}
  {{ .Data.certificate }}
  {{ .Data.issuing_ca }}
  {{ .Data.private_key }}
  {{- end -}}
  EOT
}
