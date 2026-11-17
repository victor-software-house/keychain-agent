# keychain-agent

An SSH agent for macOS that signs with keys the keychain will not export.  
Each key lives in the login keychain as a non-extractable key (`security import -x`).  
The agent signs through `SecKeyCreateSignature`, so the key is decrypted only inside `securityd`, never in the agent's memory.

It serves RSA keys, for services that accept no other kind.  
Keys the Secure Enclave can hold (P-256) belong there instead.

## Operation

1. launchd starts it on the first connection to its socket, and it exits after two minutes with no connection.
2. Its arguments are the keychain labels of the keys it serves.
3. It answers the SSH agent requests "list identities" and "sign", and refuses every other request.
4. Each key trusts only the agent's code signature, and its partition list names the team that signs the releases, so a new release keeps access with no change on the Mac.

## Install

Each release attaches `keychain-agent.pkg`, signed with a Developer ID and notarized, which installs `/usr/local/bin/keychain-agent`.  
A LaunchAgent with a `Sockets` entry named `Listeners` starts it; each key is imported with `security import -x -T /usr/local/bin/keychain-agent`.
