# Design

## Context

signd keeps settings in the user defaults domain `com.victor-software-house.signd` through CFPreferences, and keys in its keychain access group.  
The `onepassword-sync` change adds fleet values from a `signd` note in 1Password.  
flowgate already follows its TOML file with a kqueue watch on the file and its directory, two descriptors and a 50 ms debounce, and nothing runs between changes; signd takes the same pattern.

## Goals / Non-Goals

**Goals:**

- A Mac's signd settings and local keys follow from one file and an optional MDM profile, with no command run by hand.
- A change to either reaches the running agent within a second, at no cost between changes.
- `signd plan` shows what an apply would do before it does it.

**Non-Goals:**

- The 1Password token in a file or profile. It stays in signd's access group, given through `signd login`.
- Registering keys with services such as GitHub; a later change adds that to the key entries.
- Configuration for other users of the Mac.

## Decisions

### 1. Sources and precedence

| Order | Source | Written by |
|:--|:--|:--|
| 1 | Managed preferences of the domain, from an MDM profile | the MDM server |
| 2 | `~/.config/signd/config.toml` | a dotfiles tool, or `signd config set` |
| 3 | The `signd` note in a synced vault | the 1Password vault's owner |
| 4 | The built-in default | signd |

A value from a higher source wins over every lower one.  
`signd status` names the source of each value.  
CFPreferences reports a value an MDM profile sets as forced (`CFPreferencesAppValueIsForced`).  
signd reads only forced values from the domain.  
A value an older release left in the user's own domain is therefore not read as configuration.

### 2. The file

```toml
[settings]
interval = "5m"
key-lifetime = "1h"

[[keys]]
name = "deploy"
type = "secure-enclave"     # or ed25519, rsa-3072, rsa-4096
hosts = ["git.example.com"]
comment = "deploy key"
```

The file holds no secret.  
A file that does not parse, or holds an unknown key or a bad value, is rejected whole: the agent keeps the last configuration that loaded and `signd status` shows the error with its line.  
The profile carries the same names as preference keys: `interval`, `key-lifetime`, and `keys` as an array of dictionaries.

### 3. Applying keys

- An entry whose name has no key is created, and the key's source is recorded as `config`.
- An entry whose key has source `config` and other hosts or comment is updated in place; a changed `type` is reported and not applied, because it would replace the private key.
- A key with source `config` and no entry is deleted.
- A key made by command (`local`) or synced (`1password`) is never changed by an apply. An entry that names one is reported as a conflict.

`signd plan` prints these steps without making them, and exits non-zero when any step would run, so a dotfiles tool can show the plan before an apply.

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
A change there that the agent did not make is replaced within a second by the text the agent would write, so a hand edit never lasts.

The file starts with a comment that names signd as its writer, and the config file and 1Password as the places to change hosts.  
`signd status` reports the last edit the agent replaced.

### 5. `signd config set`

It rewrites the file in one rename, and only when the new text loads; comments and order of the other lines stay as they were.  
It refuses a key the profile manages, and names the profile as the reason.

### 6. The token

The token is never configuration.  
A dotfiles tool can keep it current by running `signd login` when the token's 1Password item changes, keyed on the item's update time rather than its value.

## Risks / Trade-offs

- [A file written by hand with a typo] → It is rejected whole and the agent keeps the last good configuration; `signd status` shows the error.
- [An apply deleting a key someone still uses] → Only keys created from the file can be deleted by it, and `signd plan` shows each deletion first.
- [Managed preferences written by a tool other than MDM] → signd reads only forced values from the domain, which only a profile sets.

## Migration Plan

1. A release that reads the file and the profile, and moves a value found in the old domain into the file once.
2. On each Mac, the dotfiles write the file from their data; `signd plan` shows no step.
3. Rollback: the previous release reads the old domain again.  
   The move left that domain empty, so the defaults apply until `signd config set` runs.
