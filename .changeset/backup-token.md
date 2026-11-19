---
signd: patch
---

`signd backup login` reads a 1Password service account token from stdin.
It checks that the account lists the vault named by the `backup-vault` setting.
Then it stores the token on every Mac, sealed to each Mac's Secure Enclave key.
`signd backup logout` deletes it on every Mac.
