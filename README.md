# signd

An SSH agent for macOS that holds its keys in the Secure Enclave.  
It makes new keys, imports the Ed25519, ECDSA and RSA keys you already have, and loads the SSH keys of a 1Password vault with a service account token.

The Secure Enclave holds only P-256 keys, so signd stores every other key encrypted to a Secure Enclave key, and no command writes a private key out.  
Listing keys takes under a millisecond, and a Secure Enclave signature about 5 ms.

## Use

```sh
signd service enable                         # run the agent at login, on ~/.ssh/signd.sock
signd key create work --host github.com      # a Secure Enclave P-256 key; prints its public key
signd key create ci --type ed25519           # an Ed25519 key, sealed to the Secure Enclave; also rsa-3072 and rsa-4096
signd key import old ~/.ssh/id_rsa           # an existing OpenSSH, PKCS#1, PKCS#8 or SEC1 private key file
signd key import ci - < ci_ed25519           # the same from stdin, for a key that has no passphrase
signd key list
signd status
export SSH_AUTH_SOCK=~/.ssh/signd.sock       # or IdentityAgent ~/.ssh/signd.sock in ~/.ssh/config
```

Keys added with `ssh-add` stay in memory only, honour `ssh-add -t`, and leave with `ssh-add -D`.  
Stored keys leave only with `signd key delete`.  
Every command that prints data takes `--json`.

## Keys beyond the Secure Enclave

The Secure Enclave holds only P-256 keys, so signd keeps Ed25519, ECDSA and RSA keys as wrapped keys.  
`signd key create NAME --type ed25519|rsa-3072|rsa-4096` generates one.  
`signd key import NAME FILE` brings in an existing one: Ed25519, ECDSA on P-256, P-384 and P-521, or RSA of 2048 to 8192 bits.

A key that signd cannot serve, such as RSA under 2048 bits or a DSA key, is refused with a message naming the type.

A wrapped key is sealed with HPKE to its own Secure Enclave key, so the keychain item holds only ciphertext.  
The agent opens it into memory on its first signature and drops it after `key-lifetime`, as it does for every open key.  
No command writes a private key out.

Give a key with a passphrase as a file path.  
`signd key import` then runs the system `ssh-add` for the passphrase prompt and the decryption.  
The key reaches signd over a private socket that only this user can reach, and no decrypted copy touches the disk.

## Keys from 1Password

With a 1Password service account token, a Mac needs no key imports.  
signd finds its keys in a vault, keeps them current, and tells SSH which key each host uses.  
It needs neither the 1Password CLI nor a helper process.

1. **The vault.** Make a vault that holds only SSH Key items and the `signd` note below, so edits to other items never change its content version.
2. **The service account.** Make one that reads only that vault, and keep its token.  
   Business accounts allow each token 10,000 reads an hour, and every service account of the account together 50,000 requests a day.
3. **The items.** Each item of category SSH Key in every vault the token reads becomes a key.  
   - Its name is the title in lowercase, with every character other than ASCII letters, digits, `-` and `_` turned into `-`.
   - Two optional text fields set the rest.
     - `hosts`: SSH host patterns for the key, separated by commas, made of letters, digits, `.`, `-`, `_`, `*` and `?`.
     - `macs`: the `LocalHostName` of each Mac that takes the key, separated by commas or spaces.  
       Without it, every Mac takes the key.
4. **The note.** A Secure Note titled `signd` in a synced vault sets fleet values in text fields named `interval` and `key-lifetime`, as `30s`, `5m`, `1h` or `2d`.  
   A value set on a Mac with `signd config set` wins over the note.

signd skips an item it cannot serve, and `signd status` names it with the reason.  
The reasons are a name already taken by a local key, a `hosts` value with another character, and a key signd cannot read, such as one with a passphrase.

```sh
pbpaste | signd login                # read the token from stdin, check it against 1Password, store it, and tell the agent
signd sync                           # check 1Password now, wait, and print what changed
signd status                         # signed in or not, the interval and where it comes from, the last check and the next, and skipped items
signd config set interval 10m        # this Mac's interval; the default is 5m
signd logout                         # delete the token and every synced key, and stop a check in flight; local keys stay
```

The interval runs from 1 minute to 24 hours, and `key-lifetime` from 1 second to 30 days.  
signd refuses a value outside them, and reports and ignores one in the note.

The agent checks 1Password at a random point in each interval, and costs one request when nothing changed.  
List and sign requests answer from the keys the Mac holds and never wait for 1Password.  
After a failed check it retries with growing, randomized waits, and after a rate limit it waits at least an hour.

For keys with hosts, local or synced, signd writes `~/.ssh/signd/config` and each key's public file beside it.  
Add one line before any `Host` block in `~/.ssh/config`:

```text
Include ~/.ssh/signd/config
```

## Operation

1. `signd service enable` registers the agent's LaunchAgent with `SMAppService`.  
   launchd runs `signd serve` at login and restarts it if it exits.
2. The agent serves the SSH agent protocol (RFC 9987): list, sign, add, remove, and the `query` and `session-bind@openssh.com` extensions.  
   It refuses lock, confirm and every other request.
3. Keys are readable after the first unlock after boot, with no prompt, so a locked or headless Mac signs over SSH.
4. A private key the agent opened leaves memory once it has gone `key-lifetime` without a signature.  
   The default is one hour, and `signd config set key-lifetime 30m` changes it.

## Install

Each release attaches `signd.pkg`, signed with a Developer ID, notarized and stapled, which installs `/Applications/Signd.app`.  
The app carries a Developer ID provisioning profile, which grants its keychain access group.  
The Homebrew cask links `signd` onto the PATH.

## Development

`openspec/` holds the requirements and the planned changes, and `tasks.yaml` holds the queue.  
CI builds and tests on GitHub-hosted runners, which have no Secure Enclave.  
`mise run e2e:hardware` checks Secure Enclave keys on a Mac before each release.

## License

[GNU Affero General Public License v3.0](LICENSE).
