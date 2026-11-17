# cli

## Purpose

The `signd` command: managing keys, the agent service and settings, with output a person can read and JSON a script can parse.

## ADDED Requirements

### Requirement: Key commands

`signd key create NAME`, `signd key list`, `signd key show NAME` and `signd key delete NAME` SHALL create a Secure Enclave key, list keys, print one key's OpenSSH public key, and delete one key, and no command SHALL print a private key.

#### Scenario: Create, show and delete

- **WHEN** `signd key create build` runs, then `signd key show build`, then `signd key delete build`
- **THEN** `show` prints one `ecdsa-sha2-nistp256` line, and after `delete` the key is gone from `signd key list` and from `ssh-add -L`

#### Scenario: Names are unique

- **WHEN** `signd key create build` runs while a key named `build` exists
- **THEN** the command fails, names the existing key, and changes nothing

### Requirement: Key metadata

`signd key create` SHALL accept `--comment TEXT` and repeated `--host PATTERN`, and `signd key list` SHALL show each key's name, type, fingerprint, comment, hosts and source.

#### Scenario: A key with hosts

- **WHEN** `signd key create gh --host github.com` runs
- **THEN** `signd key list` shows `gh` with host `github.com` and source `local`

### Requirement: Service commands

`signd service enable` SHALL register the agent to run at login and start it now, `signd service disable` SHALL stop and unregister it, and both SHALL succeed when the service is already in the requested state.

#### Scenario: Enable twice

- **WHEN** `signd service enable` runs twice
- **THEN** both runs exit 0 and exactly one signd agent process serves the socket

### Requirement: Status and settings

`signd status` SHALL show the version, the socket, whether the agent answers, and each key with whether it is in memory, and `signd config get|set|unset` SHALL read and change settings.

#### Scenario: Status with the agent stopped

- **WHEN** `signd service disable` has run and `signd status` runs
- **THEN** status reports that the agent does not answer and exits non-zero

### Requirement: Machine-readable output

Every command that prints data SHALL accept `--json` and print one JSON document on stdout, and every failure SHALL exit non-zero with the reason on stderr.

#### Scenario: List as JSON

- **WHEN** `signd key list --json` runs
- **THEN** stdout parses as a JSON array with one object per key
