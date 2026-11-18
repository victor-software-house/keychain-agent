---
signd: patch
---

The release edits Signd.app's entitlements with PlistBuddy, which reads the dots in an entitlement name as part of the name, so no key path needs escaping.
