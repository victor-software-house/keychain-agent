# Design

## Context

`mise-tasks/package.sh` copies the binary of `swift build` into a hand-made bundle.
It rewrites the version with `plutil` and builds the entitlements from the profile with PlistBuddy, then signs with `codesign`.
[research.md](research.md) covers Xcode 27.2, XcodeGen 2.47.0 and the release flows of four macOS projects.

## Goals / Non-Goals

**Goals:**

- Xcode builds, signs and exports the bundle from a committed project spec.
- Xcode's asset catalog step compiles the Icon Composer icon.
- The repository still contains no team identifier, profile or certificate.

**Non-Goals:**

- Linux CI and `swift test` stay on SwiftPM.
- The installer package, its scripts and pages, notarization and the cask stay as they are.
- Sparkle belongs to the `self-update` change.

## Decisions

### 1. XcodeGen with the template's settings

`project.yml` at the root includes `xcodegen/settings.yml`.
The template's `xcode_settings` piece renders that file, and `mise run template:on` turns the piece on.
mise pins `aqua:yonaskolb/XcodeGen` 2.47.0, past the `.icon` support of [XcodeGen #1600][xg-1600].
`mise run generate` writes `Signd.xcodeproj`, which git ignores.

Alternatives: a committed `.xcodeproj` is the form Ghostty uses.
Its `project.pbxproj` is hard to review as a diff, and it drifts from the template.
Tuist would add a second Swift manifest and a tool the template does not cover.

### 2. A `SigndCLI` library

An Xcode app target links a local package's library products, never its executable target.
The command code moves from `Sources/signd` into a `SigndCLI` target with a library product.

The `signd` executable target and `App/main.swift` each call `Signd.main()`.
XcodeGen (`xcodegen`, `XcodeGenCLI`) and Mint (`Mint`, `MintCLI`) use this layout.

signd's logic already lives in `SSHWire`, `AgentProtocol`, `KeyStore`, `Sync` and `AgentServer`.
So no `Kit` target is added.

Alternative: the app target compiles `Sources/signd` itself, which builds the same code two ways and breaks `swift test` imports.

### 3. The app target

The target is `Signd`, with `PRODUCT_NAME: Signd` and `EXECUTABLE_NAME: signd`.
It builds `Signd.app/Contents/MacOS/signd`, so the agent plist's `BundleProgram` and the cask's link stay the same.
No second target is named `signd`, since `signd` and `Signd` collide on a case-insensitive volume.

### 4. Resources and the Info.plist

- `Bundle/AppIcon.icon` is a source, and `ASSETCATALOG_COMPILER_APPICON_NAME` is `AppIcon`.
  Xcode runs actool on it and merges `CFBundleIconFile` and `CFBundleIconName` into the Info.plist, with no asset catalog.
- XcodeGen's `info:` writes the Info.plist with `LSUIElement`, and the version keys from `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`.
- The agent plist is a source in a Copy Files phase to `wrapper`, subpath `Contents/Library/LaunchAgents`, where `SMAppService.agent(plistName:)` reads it.

Alternative: an `actool` call in `package.sh`, which passes fewer arguments than Xcode and keeps the hand-made bundle.

### 5. Entitlements

`App/Signd.entitlements` claims:

- `keychain-access-groups`: `$(TeamIdentifierPrefix)com.victor-software-house.signd`;
- `com.apple.developer.icloud-services`: `CloudKit`;
- `com.apple.developer.icloud-container-identifiers`: `iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)` (operator, 2026-11-19);
- `com.apple.developer.aps-environment`: `production`.

Xcode expands the settings when it signs, and fails the build when the profile does not allow an entitlement.
The export sets the container environment to Production.
The agent keeps reading the container from its own signature.

Alternative: a release step copies the container from the profile into the file, as today; the operator chose the derived name.

### 6. Signing and the release

The release job decodes `SIGND_PROVISIONING_PROFILE` into `~/Library/Developer/Xcode/UserData/Provisioning Profiles/<UUID>.provisionprofile`, and reads its `TeamIdentifier` and `UUID`.
Then four mise tasks run, one command each:

1. `generate`: `xcodegen generate`.
2. `archive`: `xcodebuild archive`, with manual Developer ID signing; `DEVELOPMENT_TEAM`, `PROVISIONING_PROFILE_SPECIFIER`, `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` come from the environment.
3. `export`: `xcodebuild -exportArchive` with `method: developer-id`, `signingStyle: manual` and the profile's UUID.
4. `package`: the existing `pkgbuild`, `productbuild`, `notarytool` and `stapler` steps on the exported app.

Alternative: `xcodebuild build` and a manual `codesign`, as Ghostty and CodeEdit do.
Neither claims a profile-authorized entitlement, and signd claims three, so the export fits better.

### 7. CI

`mise run check` adds `mise run app`, an unsigned `xcodebuild build` of the app target, so a pull request that breaks `project.yml` fails.
The template's Xcode compilation cache entry covers this build.

## Risks / Trade-offs

- XcodeGen writes the icon's file type as `wrapper.icon`, which no Xcode spec lists → Xcode 27.2 still compiled it.
  The release runner runs Xcode 27.
- `-exportArchive` with a profile named by UUID was not run in the research → the first release dry run on `main` checks it, before publishing.
- Moving the command code is a large diff with no behaviour change → the existing tests run unchanged against `SigndCLI`.
- The unsigned Xcode build adds CI time → the compilation cache covers it, and its time is recorded under task 3.

## Migration Plan

The bundle identifier, the team and the keychain group stay the same, so an upgrade keeps its keys.
The first release after the merge runs with publishing off, and its bundle is checked against the packaging spec before a release goes out.

[xg-1600]: https://github.com/yonaskolb/XcodeGen/pull/1600
