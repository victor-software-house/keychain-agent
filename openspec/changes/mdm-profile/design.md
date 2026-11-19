# Design

## Context

See proposal.md, Why.
The package's `postinstall` links `/usr/local/bin/signd` and runs `signd service enable` as the console user, which registers the agent with `SMAppService` from the app's `Contents/Library/LaunchAgents`.
A registration is per user, and a Mobile Device Management (MDM) server often installs the package before anyone logs in.
research.md has the sources for each claim about MDM.

## Goals / Non-Goals

**Goals:**

- Every user of a Mac that got the package runs the agent from their first login, with no step.
- An organization's MDM approves signd's login items with one rule, and macOS shows no approval prompt.
- The repository contains no signing team identifier.

**Non-Goals:**

- Running an MDM server, signing profiles, or hosting packages for an organization.
- Settings delivered by profile, which the declarative configuration change covers (`openspec/changes/declarative-config`).
- Updates under MDM: the organization's MDM ships each release.

## Decisions

### 1. A login hook runs `service enable` at each login

The package installs `/Library/LaunchAgents/com.victor-software-house.signd.login.plist`.
launchd runs it in each user's GUI session (`LimitLoadToSessionType` `Aqua`) at login, with `RunAtLoad`.
It runs `/Applications/Signd.app/Contents/MacOS/signd service enable --at-login`, and `AssociatedBundleIdentifiers` lists signd's bundle.
Login Items then shows the hook under signd, and the same rule approves it.

`--at-login` registers and starts the agent when it is not set up, and exits with no output when it is.
It never opens System Settings: a Mac with no profile shows macOS's own notice once, and `signd status` shows what is missing.

Alternatives:

- A global LaunchAgent that is the agent itself.
  It would replace the per-user `SMAppService` registration that the cask, `service disable` and the status checks rely on.
- A hook only when no user is logged in at install.
  A user added later would still need a step.

### 2. One rule: bundle identifier, limited to the team

The profile's rule is `RuleType` `BundleIdentifier`, `RuleValue` `com.victor-software-house.signd`, with the `TeamIdentifier` key set to the signing team.
A bare team rule would approve every login item the team ever ships.
A bundle rule alone matches any app that copies the identifier.
With a label rule, macOS 26 still shows its prompt for tasks that outlive their app.

### 3. The release writes the team into the profile

`Bundle/signd.mobileconfig` has the placeholder `TEAM_IDENTIFIER`.
After signing, the package task reads `TeamIdentifier` from `codesign -dv` on the built app.
It fails unless the value matches `^[A-Z0-9]{10}$`.
An unsigned build shows `not set` there.

Then `plutil -replace` swaps in the team.
The task then checks the result with `plutil -lint` and checks that no placeholder is left.
The release uploads `signd.mobileconfig` beside `signd.pkg`.

The profile ships unsigned: an MDM wraps or edits profiles, and an admin signs one when their MDM needs that.
Its payload UUIDs are fixed in the file, so a newer release replaces the same profile.

## Risks / Trade-offs

- [Login Items shows two signd rows on a Mac with no profile] → Both name signd, and the hook exits at once; `signd status` reports both.
- [A user turns off the hook in Login Items] → The agent the user registered keeps running; only a new user would miss it.
- [An admin writes a rule by label] → The README gives the bundle rule and explains why a label rule does not cover macOS 26.
- [The cask's `uninstall` runs as one user] → It unregisters that user's login item, then deletes the hook and the app.
  Other users keep a registration that points at the deleted app: launchd cannot start it, and nothing registers it again, since the hook is gone.
  The README's uninstall section covers this.

## Migration Plan

A Mac that installed an earlier package gets the hook with the next package or cask upgrade.
The hook then finds the agent set up and exits.
Under MDM, the MDM ships each release as a package.

A Mac that updates itself never runs a package again.

The hook runs the app's binary in every user's session, so the bundle stays owned by root wherever the hook is installed.
A bundle one user can write would let that user run code as every other user at their next login.

So the [self-update change](../self-update/design.md) updates such a Mac through a step that runs as root, and that step installs the hook after its swap.

Rollback is the previous package, which does not know the hook.
With that older binary, the hook's command fails with a usage error at each login, shows nothing and changes nothing.
The README's MDM section gives the commands that remove the hook: `launchctl bootout` in each user's session, then deleting the file.
