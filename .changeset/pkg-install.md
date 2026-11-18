---
signd: patch
---

The package links `signd` into `/usr/local/bin`, and `signd service enable` adds `Include ~/.ssh/signd/config` to the top of `~/.ssh/config`.
`signd status` shows the login item and that line, and `signd service` gains `status`, `restart` and `log`.
The package opens with its own welcome, license and conclusion pages, and only on an Apple silicon Mac with macOS 26 or later.
