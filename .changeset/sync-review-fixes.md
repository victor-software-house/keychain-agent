---
signd: patch
---

signd keeps a synced key when 1Password's reply for its item cannot be read, reads such an item again after an upgrade, and reports a local setting that is out of bounds in `signd status`.
A lasting name conflict costs one request a check, and only the signd command line may use signd's private extensions.
