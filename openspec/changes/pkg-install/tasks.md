# Tasks

## 1. Code

- [x] 1.1 Link `/usr/local/bin/signd` in the postinstall by design decision 1.
  Verify that the CI e2e task runs the script's link step against a temporary root.
  Verify each case: a missing `/usr/local/bin`, a missing path, a link to a file, a link to a folder and a regular file.
  - 2026-11-18 UTC: `mise run ci:e2e` ran the link step against a temporary root for all five cases and passed, in [CI run 44423080784][pkg-install-ci].
    It checks the link's target and mode 755 for a new folder.
    A link to a file keeps its file, a link to a folder is not followed, and a regular file stays.
- [x] 1.2 Add the Include line in `signd service enable` by design decision 2.
  Verify unit tests for a missing folder, a config without the line, and each counted form.
  Verify unit tests for a matching line only inside a `Host` block, and a symbolic link.
  - 2026-11-18 UTC: five tests passed in [CI run 44423080784][pkg-install-ci], 115 of 115 in all.
    They cover a missing folder, a config without the line, 11 counted forms, five lines that do not count and a symbolic link.
    One of the five lines sits inside a `Host` block.
- [x] 1.3 Report the login item and the Include line in `signd status`.
  Open Login Items by decisions 3 and 4.
  Verify a test of the JSON report's fields.
  - 2026-11-18 UTC: `theJSONReportCarriesTheLoginItemAndTheSSHInclude` passed in [CI run 44423080784][pkg-install-ci].
- [x] 1.4 Build the package from `Bundle/Installer/distribution.xml` by design decision 5.
  Verify the built package passes `pkgutil --check-signature`.
  Verify the release workflow reads the title, `hostArchitectures` and `allowed-os-versions` back from it with `pkgutil --expand`.
  - 2026-11-19 UTC: the Release workflow, run by dispatch on `main` with publishing off, built, signed and notarized the package in [run 44456387525][pkg-install-package].
    `pkgutil --check-signature` reported a Developer ID Installer signature that the Apple notary service trusts, and `spctl --assess --type install` accepted the package.
  - 2026-11-19 UTC: in the same run, `mise run package:check` read back the title signd, `arm64` as the host architecture and macOS 26.0 as the floor.
- [ ] 1.5 Add `signd service status`, `restart` and `log` by design decision 6.
  Verify a unit test of the `log` arguments and the `service restart` step of `mise run e2e:hardware`.
- [ ] 1.6 Change the cask by design decision 7 in the tap.
  Verify `brew uninstall --cask signd` on portable leaves no login item.
- [ ] 1.7 Start the README's Install section from the package, with the cask second.
  Verify each command runs as written.
- [ ] 1.8 Restart an agent of another version in `signd service enable` by design decision 8.
  Verify on a Mac that runs the previous release: after `sudo installer` of the new package, `signd status` shows the agent with the new version.

## 2. Integration

- [ ] 2.1 Install the released package on a Mac that has signd, with `sudo installer`, after moving `~/.ssh/config` aside.
  Verify that a new shell finds `signd`, and that `signd status` shows the agent answering and the Include line.
  Verify that `ssh -G` routes a synced key's host to signd.

[pkg-install-ci]: https://github.com/victor-software-house/signd/actions/runs/44423080784
[pkg-install-package]: https://github.com/victor-software-house/signd/actions/runs/44456387525
