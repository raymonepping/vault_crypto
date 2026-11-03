# web-tls — tls-agent on vault-1. One capability: issue the web server's own
# certificate from the classic chain. Nothing else.
path "pki-classic-int/issue/web" {
  capabilities = ["update"]
}
