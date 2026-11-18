# Design

## Context

The `signd-agent` and `wrapped-keys` changes give signd a store of Secure Enclave and wrapped keys in its access group.
[research.md](research.md) holds 1Password's limits, the ways to read it, and the budget arithmetic used below.

## Goals / Non-Goals

**Goals:**

- A Mac needs only `signd login` with a token; keys and SSH hosts follow from 1Password.
- A key change in 1Password reaches every Mac within one interval, five minutes by default, through a best-effort check in the background.
- List and sign requests answer from the keys the Mac already holds, and never wait for a 1Password call or for the client to start.
- No 1Password CLI.

**Non-Goals:**

- Writing to 1Password. The token is read-only, and keys created on a Mac stay on that Mac.
- Messages between Macs to push a change faster.
- Rotating the token through 1Password; a new token is given with `signd login`.

## Decisions

### 1. `swift-onepassword` binds the Go SDK

The new public repository holds a Go file of about 50 lines that calls the SDK's public API and exports three C functions.

| C function | Does |
|:--|:--|
| `op_client_open(token, name, version)` | creates a client and returns a handle or an error, as JSON |
| `op_call(handle, request)` | runs one of `vaults.list`, `items.list`, `items.get`, taking and returning JSON |
| `op_client_close(handle)` | frees the client |

Its release job builds the file with `go build -buildmode=c-archive` for arm64 and x86_64, joins them into an XCFramework with a module map, and attaches it to the GitHub release with its checksum.
`Package.swift` points a `binaryTarget` at that asset.
The Swift module `OnePassword` wraps the calls in `async` functions that return typed values.
signd links it statically, so the release stays one signed binary.

Alternatives: the 1Password CLI, rejected because it is an outside dependency and has hung under launchd; a bundled helper process, rejected because a static library needs no second binary to sign and update.

### 2. The token

`signd login` reads the token from stdin only, never from arguments or the environment, checks it with one vault list, and stores it as an item in signd's access group.
A new `signd login` replaces the token.
`signd logout` deletes the token and every key whose source is 1Password.

### 3. What a Mac syncs

signd syncs every item of category SSH Key in every vault the token reads, except items whose `macs` field exists and does not name this Mac's `LocalHostName`.
A synced key's name is its item title in lowercase, with characters other than letters, digits, `-` and `_` turned into `-`.
A synced key that would take a local key's name is skipped and reported by `signd status`.

The deployment uses a vault that holds only SSH keys and the `signd` note, with a read-only service account scoped to it.
Unrelated edits then never change the vault's content version, and a leaked token reads only SSH keys.

### 4. The `signd` note

A Secure Note titled `signd` in a synced vault may set `interval` and `key-lifetime` for every Mac.
A local `signd config` value wins over it.
Fleets past 1,000 Macs raise `interval` here, as research.md section 5 shows.

### 5. The check

1. List vaults: 1 read. Stop if no synced vault's content version moved.
2. For each vault that moved, list its items: 1 read each.
3. Get each new item, and each item whose `updatedAt` moved: 2 reads each.
4. Wrap each fetched key and replace its keychain item in one write; delete keys whose items are gone.
5. Rewrite the SSH routing files if any key or host changed.

A failed step leaves the stored keys as they were; signd serves them until the next check succeeds.

### 6. When signd checks

- The agent opens the 1Password client in the background as soon as it starts with a stored token, and keeps it for its whole run.  
  The client takes about 1.2 s to start, nearly all of it compiling the WebAssembly core, so that time never falls on a check or a request.
- At start, each Mac draws a random phase within the interval; each later wait is the interval times a random factor from 0.8 to 1.2.
- A list or sign request on a Mac whose last success is older than the interval starts a check in the background, which covers a Mac that slept.
- `signd sync` starts one now and waits for it.
- One check runs at a time; a request during a check joins it.
- Each timer allows 1 s of leeway, so macOS can group the wake-up with others.

### 7. Failures

| Failure | Next try |
|:--|:--|
| Network or server error | full jitter: a random wait up to min(interval, 60 s × 2^attempt) |
| Rate limited | 60 min plus up to 10 min of jitter, doubling on each repeat, up to 24 h |
| Token refused | no retry; `signd status` reports it until `signd login` |

### 8. SSH routing

After each change, signd writes `~/.ssh/signd/<name>.pub` for every key with hosts, and `~/.ssh/signd/config`:

```text
Host git.example.com
  IdentityAgent ~/.ssh/signd.sock
  IdentityFile ~/.ssh/signd/deploy.pub
  IdentitiesOnly yes
```

Each key gives one `Host` block, in key-name order; a host that two keys name gets both `IdentityFile` lines.
Files are written to a temporary name and renamed, so SSH never reads a half-written file.
The user adds `Include ~/.ssh/signd/config` once, before any `Host` block in `~/.ssh/config`.
Local keys created with `--host` take part the same way.

## Risks / Trade-offs

- [The WebAssembly core adds size and start-up time] → Measure the binary size and the first client's start-up in the binding's CI; the client is created once per agent run and kept.
- [The Go SDK changes its public API] → The shim pins an exact SDK version; a new version is a binding release with its own tests.
- [Go's runtime in the agent process] → It starts threads when the client opens at agent start, and the process then holds about 165 MiB of resident memory. That is the cost of a check taking one request instead of a 1.2 s start.
- [One token on many Macs] → 1Password documents no per-device limit for a service account; the rollout watches for 429s.
- [A `hosts` value is a host pattern written into the SSH configuration] → signd accepts only letters, digits, `.`, `-`, `*`, `?` and `_`, and skips an item with any other character.

## Migration Plan

1. Create the vault and the service account; move the SSH Key items signd will serve into it and add their `hosts` fields.
2. On each Mac: `signd login`, then add the `Include` line and remove the per-host blocks the dotfiles wrote; check a login to each host.
3. Delete the keys imported by hand in the `wrapped-keys` migration once their synced copies serve.
4. Rollback: `signd logout`, and restore the dotfiles host blocks.
