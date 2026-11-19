---
"signd": patch
---

`signd backup restore` reads the private key, hosts and comment of an item again.
A backup run writes only the key items that changed.
1Password gives a field outside every named section an empty section ID, and signd took that field for a field of another section.
