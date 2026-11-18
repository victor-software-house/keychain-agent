---
signd: patch
---

signd shares keys between the Macs of one Apple account through iCloud, in place of 1Password. A key created or imported on one Mac is sealed to every Mac's Secure Enclave key and reaches the others within a few seconds; `--local` keeps a key on its Mac. New commands: `signd key share`, `signd device list` and `signd device remove`. `signd login` and `signd logout` are gone, and the `interval` setting now defaults to 2 seconds.
