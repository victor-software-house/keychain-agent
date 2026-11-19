# Proposal

## Why

The operator decided that signd updates itself after the first install, with no prompt (operator, 2026-11-18).
It uses its own updater rather than Sparkle.

Sparkle finds the running app through `NSRunningApplication`, and that API does not list a launch agent.
It would therefore install under the agent and never restart it.
Sparkle also prompts a standard user, since `/Applications` is `root:admin 775`, and its framework links AppKit and WebKit into the agent.

A user-owned app would let that user change code that every other user on the Mac runs.
Those users run it through their login items and the login hook.
So updates come from a daemon that runs as root, and the app stays root-owned (operator, 2026-11-19).

## What Changes

- The package installs a launch daemon, the updater, which checks the latest GitHub release every 6 hours.
- When a newer version is out, the updater downloads `Signd.app.zip`.
  It checks that the app is notarized and signed by signd's own team with signd's bundle identifier.
  It swaps the app in and restarts each user's agent on the new version.
- Machine-wide settings turn updates off and change the interval.
  A Mobile Device Management (MDM) profile can set both, through the declarative configuration change (`openspec/changes/declarative-config`).
- `signd update` makes the updater check now and reports the result, and `signd status` shows the last check and any error.
- Each release publishes the notarized `Signd.app.zip` beside `signd.pkg`, and the cask sets `auto_updates true`.

## Capabilities

### New Capabilities

- `updates`: the updater's check, download, verification, swap and agent restart.

### Modified Capabilities

- `packaging`: the release zip, the updater daemon in the package, and the cask's `auto_updates`.
- `cli`: `signd update` and the update lines of `signd status`.

## Impact

- The updater makes one HTTPS request to the GitHub API every 6 hours, and downloads only when a release is newer.
- The app stays `root:wheel`, so no user process can change it.
- macOS shows one notice that a background item was added; the package's admin password stays the only prompt.
- A Mac under MDM can turn the updater off and ship updates itself.
