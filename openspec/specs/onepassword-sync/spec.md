# onepassword-sync Specification

## Purpose

How signd keeps SSH keys from 1Password on each Mac.
This covers the service account token it needs and the items it takes.
It also covers when it checks and how it behaves when 1Password fails.

## Requirements

### Requirement: The token comes from stdin and stays in signd's access group

`signd login` SHALL read a service account token from stdin.
It SHALL refuse a token that 1Password rejects.
It SHALL store an accepted token only in signd's access group.

#### Scenario: Log in

- **WHEN** a valid token is piped into `signd login`
- **THEN** the command exits 0, `signd status` shows the account as signed in, and no file under the home directory contains the token

#### Scenario: A bad token

- **WHEN** a revoked token is piped into `signd login`
- **THEN** the command fails, reports that 1Password refused the token, and keeps any token stored before

### Requirement: Log out removes synced keys

`signd logout` SHALL delete the stored token and every key whose source is 1Password, and SHALL keep local keys.

#### Scenario: Log out

- **WHEN** signd has one synced and one local key and `signd logout` runs
- **THEN** `signd key list` shows only the local key

### Requirement: signd serves the SSH Key items its token reads

signd SHALL sync every SSH Key item in every vault the token reads.
It SHALL skip an item whose `macs` field does not list this Mac's local host name.

#### Scenario: A key limited to other Macs

- **WHEN** an item's `macs` field lists only another Mac
- **THEN** this Mac's `signd key list` does not show it

### Requirement: Changes reach every Mac within one interval

signd SHALL check 1Password at a random point within each interval.
The interval is 5 minutes unless a setting changes it.
signd SHALL add, replace and remove synced keys to match their items.

#### Scenario: A key is replaced

- **WHEN** an item's private key is replaced in 1Password and one interval passes
- **THEN** `ssh-add -L` on each Mac lists the new public key and not the old one

#### Scenario: An item is deleted

- **WHEN** a synced item is deleted in 1Password and one interval passes
- **THEN** each Mac no longer lists or signs with that key

#### Scenario: The default interval

- **WHEN** neither `signd config` nor the `signd` note sets `interval`
- **THEN** `signd status` shows an interval of 5 minutes

### Requirement: Requests never wait for 1Password

signd SHALL answer list and sign requests from the keys it already has.
It SHALL NOT wait for a 1Password call or for the 1Password client to start before it answers.

#### Scenario: A request during a check

- **WHEN** a check or the client's start is in progress and `ssh-add -L` runs
- **THEN** it lists the keys from the last successful check, as fast as on a Mac with no token stored

### Requirement: An unchanged vault costs one read

signd SHALL NOT list a vault's items or get an item when the vault's content version is unchanged since the last successful check.

#### Scenario: Nothing changed

- **WHEN** `signd sync` runs twice with no change in 1Password
- **THEN** the second run reports one request and no fetched item

### Requirement: Signing never waits on 1Password

signd SHALL answer list and sign requests from its store while a check runs, fails or is rate limited.

#### Scenario: 1Password unreachable

- **WHEN** the network to 1Password is down and a client requests a signature with a synced key
- **THEN** the signature verifies, and `signd status` shows the failed check and the next attempt

### Requirement: Failed checks back off

signd SHALL retry a failed check after a random wait that grows with each failure.
After a rate-limit answer it SHALL wait at least one hour.

#### Scenario: Rate limited

- **WHEN** 1Password answers a check with a rate-limit error
- **THEN** `signd status` shows the next attempt at least 60 minutes later

### Requirement: The signd note sets fleet settings

signd SHALL read `interval` and `key-lifetime` from a Secure Note titled `signd` in a synced vault.
A value set with `signd config` SHALL take precedence over it.

#### Scenario: A fleet interval

- **WHEN** the note sets `interval` to `60m` and no local value is set
- **THEN** `signd status` shows an interval of 60 minutes
