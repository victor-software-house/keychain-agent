# Tasks

## 1. Project and code

- [x] 1.1 Turn on the template's `xcode_settings` piece with `mise run template:on`, and pin `aqua:yonaskolb/XcodeGen` 2.47.0 in `mise.toml` and the locks.
  Verify `xcodegen/settings.yml` matches the template's render, and `mise install --locked` passes in CI.
  - 2026-11-19 UTC, in [pull request 68][signd#68]: the Template check passed, and `mise run check` ran `xcodegen` in the [CI run][ci-44503793231].
    XcodeGen has no Linux build, so the lock lists `macos-arm64` only.
- [x] 1.2 Move the command code into a `SigndCLI` library target by design decision 2, with one-line entry points in `Sources/signd` and `App`.
  Verify `swift build` and `swift test` pass in CI with every existing test.
  - 2026-11-19 UTC: `swift build` and `swift test` passed in the [CI run][ci-44503793231], with 136 tests in 14 suites.
    The generated `Version.swift` moved to `Sources/SigndCLI` with the rest, and the `generated_paths` answer, the verctl template and two lint configs follow.
- [ ] 1.3 Write `project.yml` and `App/Signd.entitlements` by design decisions 3 to 5, add `generate` and `app` tasks, ignore `Signd.xcodeproj`, and delete `Bundle/Info.plist`.
  Verify the unsigned `mise run app` passes in CI, and its bundle has `Contents/MacOS/signd`, the agent plist and the icon.
  - 2026-11-19 UTC: `mise run app` passed in the [CI run][ci-44503793231].
    Its log shows the link of `Contents/MacOS/signd`, the copy of the agent plist into `Contents/Library/LaunchAgents`, and `actool` writing `Assets.car` from `Bundle/AppIcon.icon`.
    `Bundle/Info.plist` stays until task 2.1, because `mise-tasks/package.sh` still reads it.
- [x] 1.4 Add `mise run app` to `mise run check` by design decision 7.
  Verify a CI run of a pull request lists the Xcode build, with its time.
  - 2026-11-19 UTC: `app` is a dependency of `check:local`, and the [CI run][ci-44503793231] ran it in 247.93 s, beside the other checks.
    That run had no compilation cache to restore.

## 2. Release

- [ ] 2.1 Replace the bundle steps of `mise-tasks/package.sh` with `archive` and `export` tasks by design decision 6, and keep its package steps.
  Verify a Release run on `main` with publishing off builds `signd.pkg`.
- [ ] 2.2 Check that package against the packaging spec.
  Verify `codesign -d --entitlements -` lists the keychain group, the container, `CloudKit`, `Production` and the push environment.
  Verify `spctl` accepts the bundle and the package, and the icon scenario holds.
- [ ] 2.3 Change AGENTS.md rule 2.7 and the README's build notes to the derived container and the Xcode build.
  Verify `mise run lint:prose` passes.

## 3. On a Mac

- [ ] 3.1 Install the first published package over the previous release on a test Mac.
  Verify the agent restarts on the new version and signs with a key stored before the upgrade.
  Verify Finder and Login Items show the icon in light and dark.

## Workflow follow-up

- Archive the change and close [SGD-007][sgd-007] after task 3.1.

[sgd-007]: ../../../tasks.yaml
[signd#68]: https://github.com/victor-software-house/signd/pull/68
[ci-44503793231]: https://github.com/victor-software-house/signd/actions/runs/44503793231
