---
signd: patch
---

`signd update` checks for a newer release now, installs it, restarts the agents on it, and prints the result.

`signd status` shows whether updates are on, the interval and its source, and the last update check.

`signd updater` is the launch daemon's own command, hidden from `--help`: it checks on a schedule as root and answers `signd update`.
