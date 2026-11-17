# onepassword-sync

## Purpose

How signd keeps SSH keys from 1Password on each Mac: the service account token it needs, which items it takes, when it checks, and how it behaves when 1Password fails.

## ADDED Requirements

### Requirement: The token comes from stdin and stays in signd's access group

`signd login` SHALL read a service account token from stdin, SHALL refuse a token 1Password rejects, and SHALL store an accepted token only in signd's access group.

#### Scenario: Log in

- **WHEN** a valid token is piped into `signd login`
- **THEN** the command exits 0, `signd status` shows the account as signed in, and no file under the home directory holds the token

#### Scenario: A bad token

- **WHEN** a revoked token is piped into `signd login`
- **THEN** the command fails, says 1Password refused the token, and keeps any token stored before

### Requirement: Log out removes synced keys

`signd logout` SHALL delete the stored token and every key whose source is 1Password, and SHALL keep local keys.

#### Scenario: Log out

- **WHEN** signd holds one synced and one local key and `signd logout` runs
- **THEN** `signd key list` shows only the local key

### Requirement: signd serves the SSH Key items its token reads

signd SHALL sync every SSH Key item in every vault the token reads, except an item whose `macs` field does not name this Mac's local host name.

#### Scenario: A key limited to other Macs

- **WHEN** an item's `macs` field names only another Mac
- **THEN** this Mac's `signd key list` does not show it

### Requirement: Changes reach every Mac within one interval

signd SHALL check 1Password at a random point within each interval and SHALL add, replace and remove synced keys to match their items.

#### Scenario: A key is replaced

- **WHEN** an item's private key is replaced in 1Password and one interval passes
- **THEN** `ssh-add -L` on each Mac lists the new public key and not the old one

#### Scenario: An item is deleted

- **WHEN** a synced item is deleted in 1Password and one interval passes
- **THEN** each Mac no longer lists or signs with that key

### Requirement: An unchanged vault costs one read

signd SHALL NOT list a vault's items or get an item when the vault's content version has not changed since the last successful check.

#### Scenario: Nothing changed

- **WHEN** `signd sync` runs twice with no change in 1Password
- **THEN** the second run reports one request and no fetched item

### Requirement: Signing never waits on 1Password

signd SHALL answer list and sign requests from its store while a check runs, fails or is rate limited.

#### Scenario: 1Password unreachable

- **WHEN** the network to 1Password is down and a client requests a signature with a synced key
- **THEN** the signature verifies, and `signd status` shows the failed check and the next attempt

### Requirement: Failed checks back off

signd SHALL retry a failed check after a random wait that grows with each failure, and after a rate-limit answer SHALL wait at least one hour.

#### Scenario: Rate limited

- **WHEN** 1Password answers a check with a rate-limit error
- **THEN** `signd status` shows the next attempt at least 60 minutes later

### Requirement: The signd note sets fleet settings

signd SHALL read `interval` and `key-lifetime` from a Secure Note titled `signd` in a synced vault, and a value set with `signd config` SHALL win over it.

#### Scenario: A fleet interval

- **WHEN** the note sets `interval` to `60m` and no local value is set
- **THEN** `signd status` shows an interval of 60 minutes
