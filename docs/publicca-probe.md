# PKI External CA against a local Pebble

Written by `make publicca-probe` on 2026-11-03T08:49Z: vault-1
**2.2.1+ent**, Pebble `2.10.1`, scratch mount `probe-public` (removed).

| Step | Result |
| --- | --- |
| `secrets enable pki-external-ca` | built into 2.2.1+ent; licence feature PKI External CA Secrets Engine |
| `POST config/acme-account/pebble (directory_url, trusted_ca)` | HTTP 200, account key ec-256 |
| `POST role/shop (vcry.test subdomains, http-01)` | HTTP 200 |
| `POST role/shop/new-order identifiers=shop.vcry.test` | HTTP 200, order 01a1a099-94da-7add-890f-f43e4d60d7ea |
| `GET role/shop/order/:id/challenge?identifier=&challenge_type=http-01` | HTTP 200, token 8pIoLF_vxDp0… |
| `challtestsrv add-http01 (serves the key authorization)` | done |
| `POST role/shop/order/:id/fulfilled-challenge` | HTTP 204 |
| `GET role/shop/order/:id/status` | order_status=error, last_error: failed to fetch certificate for order 01a1a099-94da-7add-890f-f43e4d60d7ea: failed to fetch certificate from ACME for order 01a1a099-94da-7add-890f-f43e4d60d7ea: 1 error occurred: * failed to create order certificate at finalize URI https://pebble:14000/finalize-order/EmYo37hiR2z_EbgmIgdflTjTn2pRc2DN7dhzk7NyA0Y: Post "": unsupported protocol scheme ""  |
| `Pebble log` | Issued certificate serial 0bbb948d0cd0897c |
| `GET role/shop/order/:id/fetch-cert` | HTTP 400, no certificate: order has status error, must be completed to fetch cert |

Outcome: **no certificate reached Vault.** The console has no Public CA panel until it does.
