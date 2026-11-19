---
signd: patch
---

A changed backup setting now applies at once: `signd config set` and `unset` notify the running agent, which computes the wait for the next backup again.
`signd backup status` shows the time the agent waits for.
