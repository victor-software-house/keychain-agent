# Tasks

## 1. Code

- [x] 1.1 Add the `updater` subcommand, its settings and its schedule by design decisions 1 and 2.
  Verify unit tests of the schedule, of the version comparison, and that a user's preference is not read.
  Verify a test that a second request during a run gets that run's result.
  - 2026-11-19 UTC: `UpdateSettings`, `UpdateSchedule`, `Release.isNewer`, `Updater` and `signd updater` are written, with tests in `UpdateTests.swift`.
    CI has not run yet.
- [x] 1.2 Verify a download by design decision 4.
  Verify tests that reject an app of another team, an unnotarized app, another identifier, and an app whose version is not the tag.
  Verify a test that refuses a staging path with a symlink or a component not owned by root.
  - 2026-11-19 UTC: `Staging` and `AppBundle.verify` are written, with tests in `UpdateTests.swift`.
    CI has not run yet.
    A runner has no Developer ID, so the tests reject a copy of an Apple app and an ad-hoc signed copy.
    The version check has its own test.
  - 2026-11-19 UTC: before the signature check, the updater sets the staged app to the expected owner and group.
    It also clears the group and other write bits.
    It checks the app again before the swap.
    Tests cover both steps, and CI has not run yet.
- [x] 1.3 Swap the bundle and restart the agents by design decision 5.
  Verify a test that swaps a temporary bundle and leaves the old one whole when the swap fails.
  - 2026-11-19 UTC: `AppBundle.swapContents` and `AgentRestart` are written, with tests in `UpdateTests.swift`; CI has not run yet.
- [x] 1.4 Add the cross-process (XPC) request, `update.json`, `signd update` and the status lines by decision 6.
  Verify a test of the JSON report.
  - 2026-11-19 UTC: `Updater.listen`, `Updater.requestCheck`, `UpdateState`, `signd update` and the status lines are written, with a test of the JSON report in `CommandTests.swift`; CI has not run yet.
    No test sends a request over XPC, since that needs the launch daemon.
    Task 1.5 installs the daemon.
- [ ] 1.5 Install the daemon in the package, publish `Signd.app.zip`, and update the cask by decisions 1 and 7.
  Verify `package:check` finds the daemon plist as `root:wheel 0644`, and the release workflow assesses the zip's app with `spctl`.

## 2. Integration

- [ ] 2.1 On a test Mac, update from one release to the next.
  Verify that Login Items still lists signd as allowed, the app stays `root:wheel`, and each user's agent answers from the new version.
- [ ] 2.2 Repeat 2.1 with a standard account logged in beside an admin.
