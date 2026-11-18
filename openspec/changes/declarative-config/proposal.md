# Proposal

## Why

signd's state on a Mac comes from commands today: `signd config set` and `signd key create`.
A Mac set up by a dotfiles tool needs that state to follow from a file.
So does a fleet set up by Mobile Device Management (MDM).
The tool can then write and compare it, with no command run by hand.

The operator asked for signd to be as declarative as it can be (operator, 2026-11-17).
A file and an MDM profile configure it together, and the agent watches both at the lowest overhead.

## What Changes

- signd reads its settings and local keys from `~/.config/signd/config.toml`, a file a dotfiles tool writes.
- An MDM configuration profile for the domain `com.victor-software-house.signd` can set the same values.
  A value the profile sets takes precedence over the file and cannot be changed on the Mac.
- The agent watches the file and the profile's managed preferences with kqueue, applies a change within a second, and runs nothing between changes.
- `signd plan` prints what applying the configuration would change; the agent applies it at start and on every change.
- `signd config set` rewrites the file instead of the user defaults domain, and rejects a value the profile manages.

## Capabilities

### New Capabilities

- `configuration`: where signd's settings and declared keys come from, in what order, and how a change reaches the agent.

### Modified Capabilities

- `cli`: `signd plan`, and `signd config set` writing the file.

## Impact

- Settings move from the user defaults domain to the file.
  signd reads a value it finds in the old domain once, writes it into the file, and removes it.
- Keys declared in the file that do not exist are created at apply.
  A key signd created from the file is deleted when its entry is removed.
  Keys made by command or shared from another Mac are never touched by an apply.
