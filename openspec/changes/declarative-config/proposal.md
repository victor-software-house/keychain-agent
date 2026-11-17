# Proposal

## Why

signd's state on a Mac comes from commands today: `signd config set`, `signd login`, `signd key create`.  
A Mac set up by a dotfiles tool, or a fleet set up by MDM, needs that state to follow from a file.  
The tool can then write and compare it, with no command run by hand.

The operator asked for signd to be as declarative as it can be (operator, 2026-11-17).  
A file and an MDM profile configure it together, and the agent watches both at the lowest overhead.

## What Changes

- signd reads its settings and local keys from `~/.config/signd/config.toml`, a file a dotfiles tool writes.
- An MDM configuration profile for the domain `com.victor-software-house.signd` can set the same values; a value the profile sets wins over the file and cannot be changed on the Mac.
- The agent watches the file and the profile's managed preferences with kqueue, applies a change within a second, and runs nothing between changes.
- `signd plan` prints what applying the configuration would change; the agent applies it at start and on every change.
- `signd config set` rewrites the file instead of the user defaults domain, and refuses a value the profile manages.
- The 1Password token stays out of both: `signd login` still reads it from stdin, which a dotfiles tool can feed when the token's 1Password item changes.

## Capabilities

### New Capabilities

- `configuration`: where signd's settings and declared keys come from, in what order, and how a change reaches the agent.

### Modified Capabilities

- `cli`: `signd plan`, and `signd config set` writing the file.

## Impact

- Settings move from the user defaults domain to the file. signd reads a value it finds in the old domain once, writes it into the file, and removes it.
- Keys declared in the file that do not exist are created at apply; a key signd created from the file is deleted when its entry is removed. Keys made by command or synced from 1Password are never touched by an apply.
- Depends on the `onepassword-sync` change for the note's fleet values, which keep their place below the file.
