# Design

## Context

The agent runs from `/Applications/Signd.app/Contents/MacOS/signd serve`, registered by `SMAppService.agent` with `KeepAlive`, so launchd starts it again whenever it exits.
signd never reads `Bundle.main` (AGENTS.md, invariant 6); the updater reads its own path and signature from `SecCode`.

## Decisions

### 1. Check schedule

Only the `serve` process checks, in a task of its own, never on the event loop and never inside the agent actor.
It checks 60 seconds after start, then every `updateInterval`, 6 hours by default, with up to 10 minutes of random delay so Macs do not check together.
`updates` (on by default) and `updateInterval` are settings, which the config file or an MDM profile can set.

### 2. Release source

The agent requests `api.github.com/repos/victor-software-house/signd/releases/latest` for the tag and the `Signd.app.zip` asset, unauthenticated: 4 requests a day stay far below the 60 an hour GitHub allows.
A tag that is not a newer version than the running one ends the check.

### 3. Verification

It unpacks the zip with `ditto -x -k` into `~/Library/Caches/signd/update/`, then checks the new `Signd.app` with `SecStaticCodeCheckValidity` against this requirement:

```text
anchor apple generic and notarized
and identifier "com.victor-software-house.signd"
and certificate leaf[subject.OU] = "<team>"
```

`<team>` is the team identifier of the running code, read from its own signature, so the repository names no team.
A failed check deletes the download and records the error for `signd status`.

### 4. Bundle swap

`renamex_np` with `RENAME_SWAP` exchanges the new bundle's `Contents` with the installed one's in one step, on the Data volume that holds both `/Applications` and the home folder.
The old `Contents` is then deleted, the agent logs the new version and exits, and launchd starts the new binary.
A running process keeps its mapped binary, so a signature in flight finishes.

### 5. Who owns the bundle

The package's postinstall gives `Signd.app` to the console user, unless a managed setting turns updates off.
When the bundle is not writable, the agent skips the check and `signd status` shows `updates  managed`.

### 6. The release

The release workflow staples the notarized app, zips it with `ditto -c -k --keepParent`, and attaches `Signd.app.zip` beside `signd.pkg`.
The cask sets `auto_updates true`, so `brew upgrade` leaves the app to the updater.

## Risks

- A bundle swap may affect the login item approval; Apple documents nothing for this case. Task 2.1 checks it on portable before a release ships the updater.
- A standard account has not been tested; task 2.2 runs the update as one.
