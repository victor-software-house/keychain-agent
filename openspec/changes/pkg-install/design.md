# Design

## Context

`signd.pkg` installs `/Applications/Signd.app`, and its postinstall runs `signd service enable` as the console user ([pkg-postinstall]).
The command reaches the program search path (PATH) only through the Homebrew cask's `binary` link, and SSH reaches signd only after the user edits `~/.ssh/config`.

## Decisions

### 1. The package links the command into /usr/local/bin

The postinstall runs as root and makes `/usr/local/bin/signd` a symbolic link to `/Applications/Signd.app/Contents/MacOS/signd`.
When `/usr/local/bin` is missing, as on a Mac without Homebrew, it creates the folder as `root:wheel` with mode 755.

A link already there is replaced with `ln -sfn`, which does not follow a link to a folder.
A regular file is left alone, since that file belongs to someone else.

`/usr/local/bin` is on the default PATH through `/etc/paths`, so every shell finds it.
A symbolic link keeps the bundle's entitlements, as the cask's link does.

### 2. service enable adds the Include line

`signd service enable` adds `Include ~/.ssh/signd/config` and a blank line at the top of `~/.ssh/config`, when no line there includes signd's file.
The top matters: an `Include` below a `Host` line applies only to that host.

A line counts when it comes before the first `Host` or `Match` line, and its keyword is `Include`, in any case, with whitespace or `=` after it.

One of its arguments must be `~/.ssh/signd/config`, the same path under the home directory, or `signd/config`, which SSH reads from `~/.ssh`.
A matching line inside a `Host` or `Match` block does not count, so `service enable` adds the line at the top.

- A missing `~/.ssh` is created with mode 700, and a missing config with mode 600.
- When `~/.ssh/config` is a symbolic link, signd writes its target, so the link stays.
- The file is replaced whole, by the same atomic write as the routing files, and keeps its mode.

`service enable` adds the line.
The agent never adds it at each start, so a user who removes it on purpose keeps it removed until they run the command again.

### 3. status reports both

`signd status` prints a `login item` line with the login item's state, and an `ssh config` line that shows whether the Include line is there.
Each line that is not in order shows the command that fixes it, `signd service enable`.
`--json` carries both as `loginItem` and `sshInclude`.

### 4. Login Items on a pending approval

When the login item needs approval, `signd service enable` calls `SMAppService.openSystemSettingsLoginItems()`, then fails with the same message as today.

### 5. The package shows signd's own Installer pages

`productbuild` builds the package from a distribution file, `Bundle/Installer/distribution.xml`, with its pages in `Bundle/Installer/` ([distribution definition]).

| Page | What it shows |
|:--|:--|
| Background | The signd logo, one image for light mode and one for dark mode (`background` and `background-darkAqua`) |
| Welcome | What signd is, in two lines |
| License | The AGPL-3.0 text from `LICENSE`, which the user must accept in Installer before it continues |
| Conclusion | What is ready now: the agent running and `signd` on the PATH, and a first command, `signd key create` |

The file also sets the title, `hostArchitectures="arm64"` and `allowed-os-versions` from the package's deployment target.
Installer checks both when the package opens, so an Intel Mac or an older macOS gets a message before any password.
`customize="never"` hides the custom install pane, since the package has one component.

### 6. service status, restart and log

`signd service` gains three commands beside `enable` and `disable`, as `brew services` gives a formula:

| Command | What it does |
|:--|:--|
| `status` | Prints the login item's state, from `SMAppService.agent`, and whether the agent answers on its socket, with its version |
| `restart` | Runs `launchctl kickstart -k` on the agent's label in the user's GUI domain, then waits until the agent answers |
| `log` | Runs `/usr/bin/log` with the predicate `subsystem == "com.victor-software-house.signd"`: `show --last 1h --info --debug` by default, `stream --level debug` with `--follow` |

`restart` waits at most 5 seconds and exits non-zero when the agent does not answer.
A kickstart replaces only the launchd job.
When the process that answered before still answers, `restart` names its pid and says that launchd does not run it.

### 7. The cask uninstalls what the package installed

The cask's `uninstall` runs `signd service disable` as the user before it deletes the app, so the login item goes with it.
It then forgets the package receipt, and deletes the app and `/usr/local/bin/signd` when that is a link into the app.
Its `zap` deletes `~/Library/Application Support/signd` and `~/.ssh/signd`.

Neither touches the keys: they stay in the keychain and in iCloud, and `signd key delete` removes them.
The `Include` line stays in `~/.ssh/config`; SSH skips an `Include` whose file is missing.

### 8. service enable restarts an agent of another version

A package installed over a running agent replaces the app, and the agent keeps serving the old version.
The postinstall's `signd service enable` found the login item enabled and an agent answering, and changed nothing.

It compares the answering agent's version with its own, and restarts the agent by decision 6 when they differ.
Keys in memory go with the old process, and the agent reads each key again at its next use.

## Risks

- A user's own `/usr/local/bin/signd` that is a link, such as one to a build of their own, is replaced.
  A regular file is never touched.

[pkg-postinstall]: https://github.com/victor-software-house/signd/commit/5276a55
[distribution definition]: https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/DistributionDefinitionRef/Chapters/Distribution_XML_Ref.html
