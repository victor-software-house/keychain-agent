# Proposal

## Why

The operator decided that signd updates itself after the first install, with no prompt (operator, 2026-11-18).
It uses its own updater rather than Sparkle.

Sparkle finds the running app through `NSRunningApplication`, and that API does not list a launchd agent.
It would therefore install under the agent and never restart it.
Sparkle also prompts a standard user, since `/Applications` is `root:admin 775`, and its framework links AppKit and WebKit into the agent.

## What Changes

- The agent checks the latest GitHub release at start and every 6 hours.
- When a newer version is out, the agent downloads `Signd.app.zip`.
  It checks that the app is notarized and signed by signd's own team with signd's bundle identifier.
  It swaps the app in and exits, so launchd starts the new version.
- Settings turn updates off and change the interval.
  A Mobile Device Management (MDM) profile can set both, through the declarative configuration change (`openspec/changes/declarative-config`).
- `signd update` checks now and reports, and `signd status` shows the last check and any error.
- The package hands `Signd.app` to the console user, as a drag install would, unless a managed setting turns updates off.
- Each release publishes the notarized `Signd.app.zip` beside `signd.pkg`, and the cask sets `auto_updates true`.

## Capabilities

### New Capabilities

- `updates`: the agent's own update check, download, verification and swap.

### Modified Capabilities

- `packaging`: the release zip, the bundle's owner after the package, and the cask's `auto_updates`.
- `cli`: `signd update` and the update lines of `signd status`.

## Impact

- The agent makes one HTTPS request to the GitHub API every 6 hours, and downloads only when a release is newer.
- A user-owned bundle lets any process of that user change its files.
  A changed file breaks the code signature.
  The data-protection keychain then withholds the keys from it, so no key is exposed.
- A Mac under MDM keeps a root-owned bundle, and MDM ships the updates.
