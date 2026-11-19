# Tasks

## 1. Login hook

- [x] 1.1 Add `--at-login` to `signd service enable`.
  It registers and starts the agent when it is not set up, exits with no output when it is, and never opens System Settings.
  It exits 0 while approval is pending.
  Verify a unit test that the flag parses, and the set-up and not-registered paths in `mise run e2e:hardware`.
  Verify the pending path in 3.1, since the e2e cannot revoke an approval.
  - 2026-11-19 UTC: the flag, the early return for a set-up agent and the silent return while approval is pending are in `Service.Enable`.
    `serviceEnableTakesAtLoginFromTheHook` and the two e2e steps are written; neither has run yet. CI runs the test, and the e2e needs a Mac.
- [ ] 1.2 Add `Bundle/com.victor-software-house.signd.login.plist` and install it into `/Library/LaunchAgents` from the package task.
  Verify `pkgutil --payload-files build/signd.pkg` lists it.
- [ ] 1.3 Delete the hook in the cask's `uninstall` in the Homebrew tap.
  Verify the spec scenario on a Mac.

## 2. Example profile

- [ ] 2.1 Add `Bundle/signd.mobileconfig` with the `TEAM_IDENTIFIER` placeholder and fixed payload UUIDs.
- [ ] 2.2 Render it in the package task from `codesign -dv` of the built app.
  Fail unless the team matches `^[A-Z0-9]{10}$`.
  Check it with `plutil -lint` and for a left placeholder, and upload it in the release.
  Verify the attached file's team matches the app's.
- [ ] 2.3 Add a README section for Mobile Device Management (MDM) admins, titled "Deploy with MDM".
  It covers the package, the profile, the rule's values, what it grants and why not a label rule.
  It also covers removal: the hook's commands, and what other users keep after an uninstall.

## 3. On a Mac

- [ ] 3.1 Push the profile and the package through an MDM to a test Mac with no user logged in, then log in.
  Verify the spec scenario with `signd status` and Login Items, and record whether macOS showed any prompt.
