---
signd: patch
---

The release builds signd.pkg again: the runner's plutil found no entitlement under an escaped key path, so the entitlements are now edited with PlistBuddy.
