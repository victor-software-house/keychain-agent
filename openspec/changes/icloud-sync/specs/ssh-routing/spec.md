# ssh-routing

## MODIFIED Requirements

### Requirement: signd writes a host block per key

For every key with hosts, local or shared, signd SHALL write the key's public half to `~/.ssh/signd/<name>.pub` and a `Host` block in `~/.ssh/signd/config` that names signd's socket, that file, and `IdentitiesOnly yes`.

#### Scenario: A synced key with a host

- **WHEN** another Mac shares a key created with `--host git.example.com`
- **THEN** `ssh -G git.example.com` on this Mac shows `identityagent` as signd's socket and `identityfile` as that key's public file

### Requirement: Host patterns are checked

signd SHALL write only host patterns made of letters, digits, `.`, `-`, `_`, `*` and `?`, and SHALL skip and report a shared key whose record holds any other character in its hosts.

#### Scenario: A pattern with a space

- **WHEN** a `Key` record's hosts hold `example.com ProxyCommand x`
- **THEN** `~/.ssh/signd/config` has no block for that key, and `signd status` names the key and the rejected value
