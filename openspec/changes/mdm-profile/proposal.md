## Why

An organization should be able to deploy signd to its Macs through its own Mobile Device Management (MDM) server.
It should need no prompt and no step on any Mac (operator, 2026-11-19).
Today the package registers the agent only for the user logged in at install.
macOS then asks that user to approve the login item.

## What Changes

- The package installs a login hook in `/Library/LaunchAgents`.
  The hook runs `signd service enable --at-login` at each user's login, so every user of the Mac gets the agent (operator, 2026-11-19).
  The command exits at once when the agent is already set up, and never opens System Settings.
- Each release attaches `signd.mobileconfig`: an unsigned example profile with a managed login items payload (`com.apple.servicemanagement`).
  Its one rule approves signd's bundle identifier, limited to the signing team's identifier.
- The release job reads the team identifier from the signed app and writes it into the profile, so the repository contains no team identifier.
- The README gains a "Deploy with MDM" section.
  It covers the package, the profile, the values for an admin who writes their own, and what the profile grants.
- The cask's `uninstall` deletes the login hook with the app.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `packaging`: the login hook, the example profile as a release asset, and the cask removing the hook.

## Impact

- `Bundle/`: the login hook's property list, and the profile with a placeholder for the team identifier.
- `Sources/signd/Signd.swift`: `service enable --at-login`, and `postinstall` loading the hook for a user already logged in.
- `mise-tasks/package` and `.github/workflows/release.yml`: build the hook into the package, render and check the profile, and upload it.
- `README.md`, the Homebrew tap's cask.
