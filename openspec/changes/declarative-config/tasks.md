# Tasks

## 1. Reading

- [ ] 1.1 Parse `~/.config/signd/config.toml` with an exact-version TOML library, rejecting unknown names and bad values with their line; verify unit tests for a good file, a typo, a bad duration and a bad key entry.
- [ ] 1.2 Read forced managed preferences of the domain and resolve each setting in the order of design decision 1; verify unit tests with injected sources, and `signd status` naming each value's source.
- [ ] 1.3 Move a value found in the old user domain into the file once; verify a test that starts with a value in the domain and ends with it in the file and the domain empty.

## 2. Applying

- [ ] 2.1 Plan and apply declared keys by design decision 3; verify unit tests against an in-memory store for create, update, delete, a changed type and a conflict, and that `signd plan` makes no change.
- [ ] 2.2 Rewrite the file for `signd config set` in one rename, keeping other lines, and refuse managed settings; verify unit tests.

## 3. Watching

- [ ] 3.1 Watch the file, the managed preferences file and their directories with kqueue by design decision 4.
  Verify a test that replaces the file by rename and sees one reload within one second.
  Verify on a Mac that the idle agent shows no wake-ups from the watch.
- [ ] 3.2 Watch `~/.ssh/signd/` by design decision 4, and replace any file there that differs from what the agent writes.
  Verify a test that edits the config by hand and sees it replaced within one second, with the header comment and a `signd status` report.

## 4. Documentation and integration

- [ ] 4.1 Document the file, the profile keys and `signd plan` in README.md; verify each command runs as written.
- [ ] 4.2 Write the file from the dotfiles on both Macs and push a profile from the MDM server to one; verify `signd plan` shows no step and `signd status` names the profile for the managed value.
