# vcry-key-custodian — LDAP group vcry-key-custodians. Changes the two demo
# keys' algorithm and uses them. Cannot export or delete them.
path "transit/keys/orders-signing/algorithm" { capabilities = ["update"] }
path "transit/keys/ledger-data/algorithm" { capabilities = ["update"] }
path "transit/sign/orders-signing" { capabilities = ["update"] }
path "transit/encrypt/ledger-data" { capabilities = ["update"] }
path "transit/decrypt/ledger-data" { capabilities = ["update"] }
path "transit/rewrap/ledger-data" { capabilities = ["update"] }
