---
signd: patch
---

signd syncs SSH keys from 1Password with only a service account token.
`signd login` stores the token, `signd logout` removes it with the synced keys, `signd sync` checks now, and `signd status` shows the last check, the next and the skipped items.
Keys with hosts are routed through `~/.ssh/signd/config`.
