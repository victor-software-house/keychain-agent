---
signd: patch
---

keychain-agent becomes signd, an SSH agent for keys only its signed app can use.
`signd key create` makes Secure Enclave P-256 keys, held in signd's data-protection keychain access group, and `signd service enable` runs the agent at login on `~/.ssh/signd.sock`.
The agent also accepts memory-only keys from `ssh-add`, with lifetimes, and never lets `ssh-add -D` remove a stored key.
