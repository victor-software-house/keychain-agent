# Tasks

## 1. Code

- [ ] 1.1 Add the `updater` subcommand, its settings and its schedule by design decisions 1 and 2.
  Verify unit tests of the schedule, of the version comparison, and that a user's preference is not read.
  Verify a test that a second request during a run gets that run's result.
- [ ] 1.2 Verify a download by design decision 4.
  Verify tests that reject an app of another team, an unnotarized app, another identifier, and an app whose version is not the tag.
  Verify a test that refuses a staging path with a symlink or a component not owned by root.
- [ ] 1.3 Swap the bundle and restart the agents by design decision 5.
  Verify a test that swaps a temporary bundle and leaves the old one whole when the swap fails.
- [ ] 1.4 Add the cross-process (XPC) request, `update.json`, `signd update` and the status lines by decision 6.
  Verify a test of the JSON report.
- [ ] 1.5 Install the daemon in the package, publish `Signd.app.zip`, and update the cask by decisions 1 and 7.
  Verify `package:check` finds the daemon plist as `root:wheel 0644`, and the release workflow assesses the zip's app with `spctl`.

## 2. Integration

- [ ] 2.1 On a test Mac, update from one release to the next.
  Verify that Login Items still lists signd as allowed, the app stays `root:wheel`, and each user's agent answers from the new version.
- [ ] 2.2 Repeat 2.1 with a standard account logged in beside an admin.
