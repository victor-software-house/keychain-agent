# agent-protocol Specification

## Purpose

How signd serves SSH clients: the socket it listens on, who may connect, and the SSH agent messages it answers, following RFC 9987.

## Requirements

### Requirement: signd listens on a private socket

`signd serve` SHALL listen on `~/.ssh/signd.sock` with mode 0600, replacing a stale socket at that path, and SHALL close a connection whose peer runs as another user.

#### Scenario: The socket is private

- **WHEN** `signd serve` starts
- **THEN** `stat -f %Lp ~/.ssh/signd.sock` prints `600`

#### Scenario: A stale socket does not block a restart

- **WHEN** a socket file is left at the path by a killed agent and `signd serve` starts again
- **THEN** `ssh-add -L` with `SSH_AUTH_SOCK=~/.ssh/signd.sock` answers

### Requirement: signd lists its identities

signd SHALL answer "request identities" with the public key blob and comment of every stored key and every memory-only key, without reading any private key.

#### Scenario: ssh-add lists the keys

- **WHEN** the store holds two keys and `ssh-add -L` runs against the socket
- **THEN** it prints both public keys, each with its comment

### Requirement: signd signs with the requested hash

signd SHALL answer "sign" for a key it serves, and for an RSA key SHALL use SHA-512 when the flags carry 4, SHA-256 when they carry 2, and SHA-1 only when they carry neither.

#### Scenario: A signature verifies

- **WHEN** `ssh-keygen -Y sign` signs a file through the socket with a served key
- **THEN** `ssh-keygen -Y verify` accepts the signature

#### Scenario: The RSA flags choose the algorithm

- **WHEN** a sign request for an RSA key carries flag 2
- **THEN** the signature's algorithm name is `rsa-sha2-256`

### Requirement: signd accepts memory-only keys

signd SHALL accept "add identity" and "add identity constrained" as keys held in memory only, SHALL drop a key when its lifetime constraint ends, and SHALL refuse a confirm constraint.

#### Scenario: ssh-add adds a key for a while

- **WHEN** `ssh-add -t 2 key` adds a key and three seconds pass
- **THEN** `ssh-add -L` no longer lists it

#### Scenario: A confirm constraint is refused

- **WHEN** `ssh-add -c key` runs against the socket
- **THEN** ssh-add reports failure and the key is not listed

### Requirement: Remove messages leave stored keys

"Remove identity" and "remove all identities" SHALL remove memory-only keys and SHALL leave stored keys in place.

#### Scenario: ssh-add -D keeps stored keys

- **WHEN** the store holds a key, a memory-only key was added, and `ssh-add -D` runs
- **THEN** `ssh-add -L` lists only the stored key

### Requirement: signd answers the extensions it supports

signd SHALL answer the `query` extension with the names of the extensions it supports, SHALL accept `session-bind@openssh.com`, and SHALL answer every other extension with failure.

#### Scenario: OpenSSH binds a session

- **WHEN** OpenSSH 8.9 or later connects through the socket and sends `session-bind@openssh.com`
- **THEN** signd answers success and the login proceeds

### Requirement: signd refuses what it does not support

signd SHALL answer with `SSH_AGENT_FAILURE` every message it does not support, including lock and unlock, and every message it cannot parse, and SHALL close a connection that announces a message over 256 KiB.

#### Scenario: Lock is refused

- **WHEN** `ssh-add -x` runs against the socket
- **THEN** ssh-add reports failure and signing still works

#### Scenario: An oversized message closes the connection

- **WHEN** a client sends a length prefix of 300 KiB
- **THEN** signd closes that connection and keeps serving others

### Requirement: Signing never blocks other clients

A slow signature SHALL NOT delay the replies to other connections.

#### Scenario: Concurrent clients

- **WHEN** 32 clients each request 100 signatures with a Secure Enclave key at the same time
- **THEN** every signature verifies, and a list request sent meanwhile is answered within 10 ms
