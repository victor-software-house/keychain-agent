---
"signd": patch
---

Command messages read as plain English.
After an update, `signd update` prints `updated signd from 0.0.17 to 0.0.18 and restarted the agent`.
A later run within 5 minutes prints `signd is up to date`, with the versions and the time of the update.
When the updater cannot be reached, the error gives the command that fixes it.
`signd status` shows the agent as `running` or `not running`.
