# vcry-pki-operator — LDAP group vcry-pki-operators. Issues and revokes leaf
# certificates on the three issuing mounts. Never touches a CA or its key.
path "pki-classic-int/issue/service" { capabilities = ["update"] }
path "pki-pqc-int/issue/service" { capabilities = ["update"] }
path "pki-pqc-next/issue/service" { capabilities = ["update"] }
path "pki-classic-int/revoke" { capabilities = ["update"] }
path "pki-pqc-int/revoke" { capabilities = ["update"] }
path "pki-pqc-next/revoke" { capabilities = ["update"] }
