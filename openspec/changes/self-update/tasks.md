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
- [x] 1.5 Install the daemon in the package, publish `Signd.app.zip`, and update the cask by decisions 1 and 7.
  Verify `package:check` finds the daemon plist as `root:wheel 0644`, and the release workflow assesses the zip's app with `spctl`.
  - 2026-11-19 UTC: `mise-tasks/package.sh` puts the daemon plist in the payload and builds the stapled `build/Signd.app.zip`.
    `mise-tasks/package/check.sh` checks the daemon's owner and the zip's ticket and Gatekeeper assessment.
    `Postinstall` in `Sources/SigndCLI/Signd.swift` loads the daemon, and `.github/workflows/release.yml` uploads the zip; CI has not run yet.
    The cask change is not part of this repository.
  - 2026-11-19 UTC: Release dry run [44583391486][dry-0015] passed `package:check`.
    Its payload has the daemon plist as `root:wheel 0644`, and the unzipped app has a valid ticket that Gatekeeper accepts.
  - 2026-11-19 UTC: [Release 0.0.15][rel-0015] attaches `signd.pkg`, `Signd.app.zip` and `signd.mobileconfig`.
    On both Macs, the package installed the daemon plist as `root:wheel 0644`.
    `signd update` then printed `signd is up to date (0.0.15)` through the daemon.
    `signd status` printed `updates  on, every 6h (default)`, and each agent answered on 0.0.15.
  - 2026-11-19 UTC: [homebrew-tap #8][tap-8] sets `auto_updates true` in the cask, and its uninstall unloads the daemon beside the login hook.

## 2. Integration

- [x] 2.1 On a test Mac, update from one release to the next.
  Verify that Login Items still lists signd as allowed, the app stays `root:wheel`, and each user's agent answers from the new version.
  - 2026-11-19 UTC: on both Macs, `signd update` on 0.0.15 printed `installed 0.0.16; the agents restart on it`, at 19:39:43 and 19:40:09.
    `signd status` then printed `signd 0.0.16`, `agent   answers` on 0.0.16 and `login item  enabled`.
    `Signd.app` and its executable stayed `root:wheel`, and Gatekeeper accepted the swapped app as notarized Developer ID.
- [ ] 2.2 Repeat 2.1 with a standard account logged in beside an admin.

[dry-0015]: https://github.com/victor-software-house/signd/actions/runs/44583391486
[rel-0015]: https://github.com/victor-software-house/signd/releases/tag/v0.0.15
[tap-8]: https://github.com/victor-software-house/homebrew-tap/pull/8
