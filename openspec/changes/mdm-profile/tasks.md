# Tasks

## 1. Login hook

- [x] 1.1 Add `--at-login` to `signd service enable`.
  It registers and starts the agent when it is not set up, exits with no output when it is, and never opens System Settings.
  It exits 0 while approval is pending.
  Verify a unit test of the flag, and the first two paths in `mise run e2e:hardware`.
  Verify the third in 3.1.
  - 2026-11-19 UTC: written in `Service.Enable`; the test and e2e steps have not run.
- [x] 1.2 Add `Bundle/com.victor-software-house.signd.login.plist` and install it into `/Library/LaunchAgents` from the package task.
  Verify `pkgutil --payload-files build/signd.pkg` lists it.
  Verify the expanded package's bill of materials gives it root:wheel and mode 0644.
  - 2026-11-19 UTC: `package.sh` copies the hook into the package root and passes `--ownership recommended` to `pkgbuild`.
    `package:check` reads the payload list and the bill of materials.
    `plutil -lint` accepts the plist, and the owner filter ran on a system receipt.
    The package is not built yet: the Release workflow builds it.
- [ ] 1.3 Delete the hook in the cask's `uninstall` in the Homebrew tap.
  Verify the spec scenario on a Mac.

## 2. Example profile

- [x] 2.1 Add `Bundle/signd.mobileconfig` with the `TEAM_IDENTIFIER` placeholder and fixed payload UUIDs.
  - 2026-11-19 UTC: `plutil -lint` accepts the file, which has one `com.apple.servicemanagement` rule.
- [x] 2.2 Render it in the `package:mobileconfig` task from `codesign -dv` of the built app.
  Fail unless the team matches `^[A-Z0-9]{10}$`.
  Check it with `plutil -lint` and for a left placeholder, and upload it in the release.
  Verify the attached file's team matches the app's.
  - 2026-11-19 UTC: with a stub `codesign`, the task wrote the team into the profile and refused `not set` and a short value.
    The Release workflow runs and uploads it; that has not run yet.
- [ ] 2.3 Add a README section for Mobile Device Management (MDM) admins, titled "Deploy with MDM".
  It covers the package, the profile, the rule's values, what it grants and why not a label rule.
  It also covers removal: the hook's commands, and what other users keep after an uninstall.

## 3. On a Mac

- [ ] 3.1 Push the profile and the package through an MDM to a test Mac with no user logged in, then log in.
  Verify the spec scenario with `signd status` and Login Items, and record whether macOS showed any prompt.
