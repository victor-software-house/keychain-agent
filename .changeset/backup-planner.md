---
signd: patch
---

The backup plans each run from the keys that iCloud and this Mac have and the items in the 1Password vault.
It creates the missing items and updates the ones that differ.
It removes the items of removed keys only after a complete read of iCloud.
Items the backup did not create stay as they are.

The `backup-removed` setting chooses whether a removed key's item is deleted, archived or kept.
It defaults to delete.
