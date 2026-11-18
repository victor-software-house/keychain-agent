# Design

## Context

`signd.pkg` installs `/Applications/Signd.app`, and its postinstall runs `signd service enable` as the console user ([pkg-postinstall]).  
The command reaches the PATH only through the Homebrew cask's `binary` link, and SSH reaches signd only after the user edits `~/.ssh/config`.

## Decisions

### 1. The package links the command into /usr/local/bin

The postinstall runs as root and makes `/usr/local/bin/signd` a symbolic link to `/Applications/Signd.app/Contents/MacOS/signd`.  
It replaces a link already there and leaves a regular file alone, since that file belongs to someone else.

`/usr/local/bin` is on the default PATH through `/etc/paths`, so every shell finds it.  
A symbolic link keeps the bundle's entitlements, as the cask's link does.

### 2. service enable adds the Include line

`signd service enable` adds `Include ~/.ssh/signd/config` and a blank line at the top of `~/.ssh/config`, when no line there includes signd's file.  
The top matters: an `Include` below a `Host` line applies only to that host.  
A line counts when its keyword is `Include`, in any case, with whitespace or `=` after it, and one of its arguments is `~/.ssh/signd/config`, the same path under the home directory, or `signd/config`, which SSH reads from `~/.ssh`.

- A missing `~/.ssh` is created with mode 700, and a missing config with mode 600.
- When `~/.ssh/config` is a symbolic link, signd writes its target, so the link stays.
- The file is replaced whole, by the same atomic write as the routing files, and keeps its mode.

`service enable` adds the line, rather than the agent at each start, so a user who removes it on purpose keeps it removed until they run the command again.

### 3. status reports both

`signd status` prints a `login item` line with the login item's state, and an `ssh config` line that says whether the Include line is there.  
Each line that is not in order names the command that fixes it, `signd service enable`.  
`--json` carries both as `loginItem` and `sshInclude`.

### 4. Login Items on a pending approval

When the login item needs approval, `signd service enable` calls `SMAppService.openSystemSettingsLoginItems()`, then fails with the same message as today.

## Risks

- A user's own `/usr/local/bin/signd` that is a link, such as one to a build of their own, is replaced. A regular file is never touched.

[pkg-postinstall]: https://github.com/victor-software-house/signd/commit/5276a55
