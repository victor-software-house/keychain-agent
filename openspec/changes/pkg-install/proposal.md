# Proposal

## Why

Installing signd today takes four steps after the package: the Homebrew cask for the command, `signd service enable`, `SSH_AUTH_SOCK`, and an `Include` line in `~/.ssh/config`.  
The operator asked for an install as smooth as flowgate's, where opening the package is the whole install (operator, 2026-11-18).  
signd needs no privacy permission, only its login item, so the package can do the rest.

## What Changes

- The package links `/usr/local/bin/signd` to the app's binary, unless a file that is not a link is there.
- `signd service enable`, which the package's postinstall runs as the console user, adds `Include ~/.ssh/signd/config` at the top of `~/.ssh/config` when no line includes it, creating the file when it is missing.
- `signd status` shows the login item's state and whether `~/.ssh/config` includes signd's file.
- When the login item needs approval, `signd service enable` opens System Settings at Login Items.
- The package shows signd's own Installer pages: a background in light and dark, a welcome, the AGPL license and a conclusion (operator, 2026-11-18).  
  It refuses an Intel Mac or an older macOS before the password prompt.
- `signd service status`, `restart` and `log` report and control the agent, as `brew services` does for a formula; signd ships no formula (operator, 2026-11-18).
- The Homebrew cask unregisters the login item on uninstall, and its `zap` deletes signd's state.
- The README's Install section starts from the package, with the Homebrew cask second.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `packaging`: the package puts the command on the PATH and points SSH at signd.
- `cli`: `signd status` reports the login item and the `Include` line, and `signd service enable` opens Login Items when it needs approval.

## Impact

- `Bundle/scripts/postinstall` gains the link; it runs as root, before it starts the agent as the console user.
- `signd service enable` edits `~/.ssh/config` once. A config that already includes the file, in any of the forms SSH reads, is left as it is.
- The Homebrew cask keeps its own link in Homebrew's `bin`, so both routes work side by side.
