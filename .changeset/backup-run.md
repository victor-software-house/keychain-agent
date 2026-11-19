---
signd: patch
---

The agent now copies shared keys, this Mac's own keys and a list of its Secure Enclave keys to the 1Password vault.
It starts once a backup token is stored.

A run starts 5 minutes after the last key change, at most once an hour, and once a day with no change.
Only one Mac runs the backup at a time.

The new `backup-delay`, `backup-min-interval` and `backup-max-interval` settings change the three times.
