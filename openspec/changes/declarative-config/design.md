# Design

## Context

signd keeps settings in the user defaults domain `com.victor-software-house.signd` through CFPreferences, and keys in its keychain access group.
flowgate already follows its TOML file with a kqueue watch on the file and its directory.
The watch uses two descriptors and a 50 ms debounce, and nothing runs between changes.
signd takes the same pattern.

## Goals / Non-Goals

**Goals:**

- A Mac's signd settings and local keys follow from one file and an optional Mobile Device Management (MDM) profile.
  No command runs by hand.
- A change to either reaches the running agent within a second, at no cost between changes.
- `signd plan` shows what an apply would do before it does it.

**Non-Goals:**

- Registering keys with services such as GitHub; a later change adds that to the key entries.
- Configuration for other users of the Mac.

## Decisions

### 1. Sources and precedence

| Order | Source | Written by |
|:--|:--|:--|
| 1 | Managed preferences of the domain, from an MDM profile | the MDM server |
| 2 | `~/.config/signd/config.toml` | a dotfiles tool, or `signd config set` |
| 3 | The built-in default | signd |

A value from a higher source takes precedence over every lower one.
`signd status` shows the source of each value.
CFPreferences reports a value an MDM profile sets as forced (`CFPreferencesAppValueIsForced`), and signd reads only forced values from the domain.
A value an older release left in the user's own domain is therefore not read as configuration.

### 2. The file

```toml
[settings]
interval = "2s"
key-lifetime = "1h"

[[keys]]
name = "deploy"
type = "secure-enclave"     # or ed25519, rsa-3072, rsa-4096
hosts = ["git.example.com"]
comment = "deploy key"
```

The file contains no secret.
The agent rejects a file that does not parse or contains an unknown key or a bad value.
It rejects the file whole, keeps the last configuration that loaded, and shows the error with its line in `signd status`.

The profile carries the same names as preference keys: `interval`, `key-lifetime`, and `keys` as an array of dictionaries.

### 3. Applying keys

- An entry whose name has no key is created, and the key's source is recorded as `config`.
- An entry whose key has source `config` and other hosts or comment is updated in place.
  A changed `type` is reported and not applied, because it would replace the private key.
- A key with source `config` and no entry is deleted.
- A key made by command (`local`) or shared from another Mac (`icloud`) is never changed by an apply.
  An entry for one of them is reported as a conflict.

`signd plan` prints these steps without making them.
It exits non-zero when any step would run, so a dotfiles tool can show the plan before an apply.

### 4. The watch

The agent watches two files with kqueue `DispatchSource`s:

- `~/.config/signd/config.toml` and its directory;
- `/Library/Managed Preferences/<user>/com.victor-software-house.signd.plist` and its directory.

On each file it watches `write`, `extend`, `attrib`, `delete` and `rename`, and on each directory `write`.

An editor or a dotfiles tool replaces the file by rename, so each event reopens the file's descriptor.
Each event also schedules one reload 50 ms later, and a burst of events gives one reload.

A path that does not exist yet is watched through its nearest existing parent until it appears.
Nothing polls.

The agent also watches `~/.ssh/signd/`, which it writes for keys with hosts.
The agent replaces any change there that it did not make, within a second, with the text it would write.
A hand edit therefore never lasts.

The file starts with a comment that shows signd as its writer and lists the config file and `signd key` as the places to change hosts.
`signd status` reports the last edit the agent replaced.

### 5. `signd config set`

It rewrites the file in one rename, and only when the new text loads; comments and order of the other lines stay as they were.
It rejects a key the profile manages, and gives the profile as the reason.

## Risks / Trade-offs

- [A file written by hand with a typo] → It is rejected whole and the agent keeps the last good configuration; `signd status` shows the error.
- [An apply deleting a key someone still uses] → Only keys created from the file can be deleted by it, and `signd plan` shows each deletion first.
- [Managed preferences written by a tool other than MDM] → signd reads only forced values from the domain, which only a profile sets.

## Migration Plan

1. A release that reads the file and the profile, and moves a value found in the old domain into the file once.
2. On each Mac, the dotfiles write the file from their data; `signd plan` shows no step.
3. Rollback: the previous release reads the old domain again.
   The move left that domain empty, so the defaults apply until `signd config set` runs.
