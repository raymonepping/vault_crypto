# vcry-data-steward — LDAP group vcry-data-stewards. Encodes, decodes and
# rewraps FF1 values with the payments role.
path "transform/encode/payments" { capabilities = ["update"] }
path "transform/decode/payments" { capabilities = ["update"] }
path "transform/rewrap/payments" { capabilities = ["update"] }
