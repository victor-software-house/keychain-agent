# Tasks

## 1. Project and code

- [ ] 1.1 Turn on the template's `xcode_settings` piece with `mise run template:on`, and pin `aqua:yonaskolb/XcodeGen` 2.47.0 in `mise.toml` and the locks.
  Verify `xcodegen/settings.yml` matches the template's render, and `mise install --locked` passes in CI.
- [ ] 1.2 Move the command code into a `SigndCLI` library target by design decision 2, with one-line entry points in `Sources/signd` and `App`.
  Verify `swift build` and `swift test` pass in CI with every existing test.
- [ ] 1.3 Write `project.yml` and `App/Signd.entitlements` by design decisions 3 to 5, add `generate` and `app` tasks, ignore `Signd.xcodeproj`, and delete `Bundle/Info.plist`.
  Verify the unsigned `mise run app` passes in CI, and its bundle has `Contents/MacOS/signd`, the agent plist and the icon.
- [ ] 1.4 Add `mise run app` to `mise run check` by design decision 7.
  Verify a CI run of a pull request lists the Xcode build, with its time.

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
