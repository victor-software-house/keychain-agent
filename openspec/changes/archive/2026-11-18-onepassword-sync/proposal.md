# Proposal

## Why

After the `wrapped-keys` change, every Mac still needs each key imported by hand and its SSH hosts configured by hand.
A changed key must be imported again on every Mac.

With 1Password as the main store of keys, a Mac should need only a service account token.
signd finds its keys and keeps them current within minutes.
It also sets up SSH to use the right key for each host.

## What Changes

- New: `signd login` reads a 1Password service account token from stdin and stores it in signd's access group; `signd logout` removes the token and every key it synced.
- New: signd syncs SSH Key items from the vaults the token can read.
  It checks each vault's content version on a jittered interval.
  It fetches only items that changed, wraps their private keys, and removes keys whose items are gone.
  Signing never waits on 1Password.
- New: an item's optional `hosts` field lists the SSH hosts that use it, and its optional `macs` field limits which Macs take it.
  A Secure Note titled `signd` in the vault can set the sync interval and the key lifetime for every Mac.
- New: `signd sync` runs a sync now and reports what changed; `signd status` shows the last sync and the next.
- New: signd writes `~/.ssh/signd/config` and each key's public half under `~/.ssh/signd/`, so one `Include` line in the SSH configuration routes every host to its key.
- New dependency: `swift-onepassword`, a new public Swift package that binds 1Password's official Go SDK as a static library.
  signd then needs neither the 1Password CLI nor a helper process.

## Capabilities

### New Capabilities

- `onepassword-sync`: the token, which items signd syncs, when it checks, and how it fails.
- `ssh-routing`: the SSH configuration signd writes for its keys' hosts.

### Modified Capabilities

None.

## Impact

- New repository: `swift-onepassword`, with a Go shim, a release job that builds an XCFramework, and a Swift API.
- signd: a sync service in the agent, two commands, and the `ssh-routing` writer, which also covers local keys created with `--host`.
- 1Password: a vault that contains only SSH keys and the `signd` note, and a read-only service account scoped to it.
- Rate limits: each check costs one read; [research.md](research.md) shows the budget for 10 to 5,000 Macs.
