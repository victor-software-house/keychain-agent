# Spec Delta

## ADDED Requirements

### Requirement: The bundle carries the app icon

`Signd.app` SHALL carry signd's app icon, compiled from its Icon Composer document, with a light and a dark appearance.
Its Info.plist SHALL name the icon, so Finder, Login Items and System Settings show it.

#### Scenario: The icon is in the bundle

- **WHEN** the release package is installed
- **THEN** `Signd.app/Contents/Resources` contains `Assets.car` and `AppIcon.icns`
- **AND** `CFBundleIconName` in its Info.plist is `AppIcon`
- **AND** `assetutil --info` on `Assets.car` lists `AppIcon` renditions for the light and the dark appearance

### Requirement: The bundle is built from a committed project spec

The release SHALL build `Signd.app` from a project spec committed in the repository.
No step SHALL edit the bundle's plists or entitlements after the build.

#### Scenario: A pull request builds the app

- **WHEN** a pull request changes the project spec or the code
- **THEN** CI builds the app target from the spec, unsigned, and fails when the build fails

#### Scenario: The release signs once

- **WHEN** the release job builds the package
- **THEN** the bundle it packages was signed by the export, and no later step runs `codesign` on it
