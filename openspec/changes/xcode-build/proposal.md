# Proposal

## Why

`mise-tasks/package.sh` assembles `Signd.app` by hand around `swift build`, edits its plists and entitlements, and signs it with `codesign`.
[SGD-007][sgd-007] records the outcome the operator asked for: the standard declarative build, with the Icon Composer app icon (operator, 2026-11-19).

## What Changes

- An XcodeGen `project.yml` declares the `Signd` app target and includes the template's `xcodegen/settings.yml`.
- The command code moves from the `signd` executable target into a `SigndCLI` library, which the SwiftPM executable and the app target both call.
- The app icon, `Bundle/AppIcon.icon`, is a resource of the app target, and Xcode compiles it.
- XcodeGen generates the Info.plist, and `Bundle/Info.plist` goes away.
- A committed entitlements file claims the keychain group and the iCloud container through build settings.
  It names no team and no literal container (operator, 2026-11-19).
- The release archives and exports the app with `xcodebuild`, then builds the package as before.
- CI builds the app target unsigned on every pull request.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `packaging`: the bundle carries signd's app icon, in light and dark.

## Impact

- `mise-tasks/package.sh` keeps only the package, notarization and stapling steps.
- AGENTS.md rule 2.7 changes: the entitlements file derives the container from the bundle identifier.
- mise pins XcodeGen, and the template's `xcode_settings` piece is turned on.
- The generated `Signd.xcodeproj` is not committed.

[sgd-007]: ../../../tasks.yaml
