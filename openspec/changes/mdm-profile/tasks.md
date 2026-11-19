# Tasks

## 1. Login hook

- [ ] 1.1 Add `--at-login` to `signd service enable`.
  It registers and starts the agent when it is not set up, exits with no output when it is, and never opens System Settings.
  It exits 0 while approval is pending.
  Test the three paths with the existing service test doubles.
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
