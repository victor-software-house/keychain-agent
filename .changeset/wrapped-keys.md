---
signd: patch
---

`signd key import NAME FILE` brings an existing Ed25519, ECDSA or RSA private key into signd, from a file or from stdin, and asks for the passphrase of a protected file through `ssh-add`.
`signd key create NAME --type ed25519|rsa-3072|rsa-4096` makes such a key, and both seal it to its own Secure Enclave key so that only signd can use it.
