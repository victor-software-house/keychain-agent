---
signd: patch
---

Each release attaches `signd.mobileconfig`, an example profile for a Mobile Device Management (MDM) server.
The package also installs a login hook.
An admin who pushes both gets the agent for every user at login, with no approval prompt.

A user on a Mac with no profile sees nothing new.
The hook exits at once when the agent runs, and never opens System Settings.
