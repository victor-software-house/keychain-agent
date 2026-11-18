# ssh-routing Specification

## Purpose

The SSH configuration signd writes so that each host uses the key meant for it, through one `Include` line in the user's SSH configuration.

## Requirements

### Requirement: signd writes a host block per key

For every key with hosts, local or synced, signd SHALL write the key's public half to `~/.ssh/signd/<name>.pub`.
It SHALL also write a `Host` block in `~/.ssh/signd/config` that points to signd's socket and that file and sets `IdentitiesOnly yes`.

#### Scenario: A synced key with a host

- **WHEN** an item's `hosts` field is `git.example.com` and signd has synced it
- **THEN** `ssh -G git.example.com` shows `identityagent` as signd's socket and `identityfile` as that key's public file

### Requirement: The files follow the keys

signd SHALL rewrite the routing files whenever a key or its hosts change.
It SHALL replace each file whole.
It SHALL delete the public file of a removed key.

#### Scenario: A host is removed

- **WHEN** a key's last host is removed and the change syncs
- **THEN** `~/.ssh/signd/config` has no block for it and its public file is gone

### Requirement: Host patterns are checked

signd SHALL write only host patterns made of letters, digits, `.`, `-`, `_`, `*` and `?`, and SHALL skip and report a key whose hosts contain any other character.

#### Scenario: A pattern with a space

- **WHEN** an item's `hosts` field is `example.com ProxyCommand x`
- **THEN** `~/.ssh/signd/config` has no block for that key, and `signd status` shows the item and the rejected value
