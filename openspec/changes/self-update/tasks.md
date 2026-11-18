# Tasks

## 1. Code

- [ ] 1.1 Add the `updates` and `updateInterval` settings and the check loop by design decisions 1 and 2.
  Verify unit tests of the schedule and of the version comparison.
- [ ] 1.2 Verify a download by design decision 3.
  Verify tests that reject an app of another team, an unnotarized app and another identifier.
- [ ] 1.3 Swap the bundle by design decision 4.
  Verify a test that swaps a temporary bundle and leaves the old one whole when the swap fails.
- [ ] 1.4 Add `signd update` and the status lines.
  Verify a test of the JSON report.
- [ ] 1.5 Hand the bundle to the console user in the postinstall by decision 5.
  Publish `Signd.app.zip` and `auto_updates` by decision 6.
  Verify the release workflow assesses the zip's app with `spctl`.

## 2. Integration

- [ ] 2.1 On portable, update from one release to the next.
  Verify that Login Items still lists signd as allowed and the agent answers from the new version.
- [ ] 2.2 Repeat 2.1 as a standard account.
