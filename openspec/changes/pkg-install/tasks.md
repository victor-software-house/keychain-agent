# Tasks

## 1. Code

- [ ] 1.1 Link `/usr/local/bin/signd` in the postinstall by design decision 1; verify the CI e2e task runs the script's link step against a temporary root for a missing path, a link and a regular file.
- [ ] 1.2 Add the Include line in `signd service enable` by design decision 2; verify unit tests for a missing folder, a config without the line, each counted form, and a symbolic link.
- [ ] 1.3 Report the login item and the Include line in `signd status`, and open Login Items by decisions 3 and 4; verify a test of the JSON report's fields.
- [ ] 1.4 Build the package from `Bundle/Installer/distribution.xml` by design decision 5; verify the built package passes `pkgutil --check-signature`, and the release workflow reads the title, `hostArchitectures` and `allowed-os-versions` back from it with `pkgutil --expand`.
- [ ] 1.5 Add `signd service status`, `restart` and `log` by design decision 6; verify a unit test of the `log` arguments and the e2e task's restart of the agent.
- [ ] 1.6 Change the cask by design decision 7 in the tap; verify `brew uninstall --cask signd` on portable leaves no login item.
- [ ] 1.7 Start the README's Install section from the package, with the cask second; verify each command runs as written.

## 2. Integration

- [ ] 2.1 Install the released package on a Mac that has signd, with `sudo installer`, after moving `~/.ssh/config` aside.  
  Verify that a new shell finds `signd`, and that `signd status` shows the agent answering and the Include line.  
  Verify that `ssh -G` routes a synced key's host to signd.
