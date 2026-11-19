# Design

## Context

Each user's agent runs from `/Applications/Signd.app/Contents/MacOS/signd serve`, registered by `SMAppService.agent` with `KeepAlive`, so launchd starts it again whenever it exits.
The package installs the app as `root:wheel`, so only root can change it.
signd never reads `Bundle.main` (AGENTS.md, invariant 6); the updater reads its own path and signature from `SecCode`.

## Decisions

### 1. The updater is a root daemon

The package installs `/Library/LaunchDaemons/com.victor-software-house.signd.updater.plist`, owned by `root:wheel` with mode 0644.
It runs `/Applications/Signd.app/Contents/MacOS/signd updater` as root, a subcommand that `--help` does not list.
The updater fetches and checks every release itself, so nothing it installs comes from a user process (operator, 2026-11-19).

### 2. Check schedule

The daemon's `StartInterval` is 6 hours, and each run first waits up to 10 minutes at random, so Macs do not check together.
`updates` (on by default) and `update-interval` are read from the managed and the machine-wide preferences, never a user's.
A Mobile Device Management (MDM) profile sets them, or an admin with `sudo defaults write /Library/Preferences/com.victor-software-house.signd`.

### 3. Release source

The updater requests `api.github.com/repos/victor-software-house/signd/releases/latest` for the tag and the `Signd.app.zip` asset, unauthenticated: 4 requests a day stay far below the 60 an hour GitHub allows.
A tag that is not a newer version than the installed one ends the check.

### 4. Verification

It unpacks the zip with `ditto -x -k` into `/Library/Caches/signd/update/`, a directory only root can read.
It then checks the new `Signd.app` with `SecStaticCodeCheckValidity` against this requirement:

```text
anchor apple generic and notarized
and identifier "com.victor-software-house.signd"
and certificate leaf[subject.OU] = "<team>"
```

`<team>` is the team identifier of the running code, read from its own signature, so the repository contains no team identifier.
A failed check deletes the download and records the error.

### 5. Bundle swap and restart

`renamex_np` with `RENAME_SWAP` exchanges the new bundle's `Contents` with the installed one's in one step, on the Data volume that contains both `/Applications` and `/Library`.
The old `Contents` is then deleted.
A running process keeps its mapped binary, so a signature in flight finishes.

The updater then finds each running `signd serve` by its executable path and runs `launchctl kickstart -k gui/<uid>/com.victor-software-house.signd` for its user.

### 6. Asking and reporting

The daemon also serves the Mach service `com.victor-software-house.signd.updater` over XPC (cross-process communication), with one request: check now and answer the result.
Any user may send it, since a check installs only what decision 4 accepts.

Each run writes `/Library/Application Support/signd/update.json`, mode 0644, with the time, the versions and any error, and contains no secret.
`signd update` sends the request, and `signd status` reads the file.

### 7. The release

The release workflow staples the notarized app, zips it with `ditto -c -k --keepParent`, and attaches `Signd.app.zip` beside `signd.pkg`.
The cask sets `auto_updates true`, so `brew upgrade` leaves the app to the updater, and its `uninstall` unloads the daemon.

## Risks

- A bundle swap may affect the login item approval; Apple documents nothing for this case.
  Task 2.1 checks it on a test Mac before a release ships the updater.
- The updater unpacks a download as root.
  `ditto` runs only on a file fetched from the release asset over HTTPS, and nothing runs from it before the signature check.
