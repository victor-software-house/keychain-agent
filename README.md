# signd

An SSH agent for macOS whose keys only signd can use.  
Keys live in the Secure Enclave, in signd's own data-protection keychain access group, and no command exports them.  
The agent answers from memory: listing keys reads no keychain, and a Secure Enclave signature takes about 5 ms.

## Use

```sh
signd service enable                         # run the agent at login, on ~/.ssh/signd.sock
signd key create work --host github.com      # a Secure Enclave P-256 key; prints its public key
signd key list
signd status
export SSH_AUTH_SOCK=~/.ssh/signd.sock       # or IdentityAgent ~/.ssh/signd.sock in ~/.ssh/config
```

Keys added with `ssh-add` stay in memory only, honour `ssh-add -t`, and leave with `ssh-add -D`; stored keys leave only with `signd key delete`.  
Every command that prints data takes `--json`.

## Operation

1. `signd service enable` registers the agent's LaunchAgent with `SMAppService`; launchd runs `signd serve` at login and restarts it if it exits.
2. The agent serves the SSH agent protocol (RFC 9987): list, sign, add, remove and the `query` and `session-bind@openssh.com` extensions, and refuses lock, confirm and every other request.
3. Keys are readable after the first unlock after boot, with no prompt, so a locked or headless Mac signs over SSH.
4. A private key the agent opened leaves memory after `key-lifetime` without a signature, one hour by default: `signd config set key-lifetime 30m`.

## Install

Each release attaches `signd.pkg`, signed with a Developer ID, notarized and stapled, which installs `/Applications/Signd.app`.  
The app carries a Developer ID provisioning profile, which grants its keychain access group; the Homebrew cask links `signd` onto the PATH.

## Development

`openspec/` holds the requirements and the planned changes; `tasks.yaml` holds the queue.  
CI builds and tests on GitHub-hosted runners, which have no Secure Enclave, so `mise run e2e:hardware` checks Secure Enclave keys on a Mac before each release.

## License

[GNU Affero General Public License v3.0](LICENSE).
