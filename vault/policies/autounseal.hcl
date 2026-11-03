# autounseal — on vault-s. The only thing vault-1's seal token may do.
path "transit/encrypt/autounseal" {
  capabilities = ["update"]
}

path "transit/decrypt/autounseal" {
  capabilities = ["update"]
}
