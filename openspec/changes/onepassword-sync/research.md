# Research

Retrieved 2026-11-17, with `op` 2.42.0 against a Business account and onepassword-sdk-go 0.4.1.

## 1. Limits for service accounts

| Plan | Reads per hour, per token | Writes per hour, per token | Requests per day, per account |
|:--|:--|:--|:--|
| Business | 10,000 | 1,000 | 50,000 |
| Teams | 1,000 | 100 | 5,000 |

The daily limit is shared by every service account of the account ([rate limits][op-limits]).
Going over returns HTTP 429; the Go SDK's [rate-limit error][sdk-ratelimit] holds only a message, with no retry time.
1Password support can raise the limits.

Measured costs, with the CLI's cache off: listing all vaults cost 1 read, listing one vault's items 1 read, and getting one item by ID 2 reads.

## 2. Ways to read with only a token

| Path | Verdict |
|:--|:--|
| `op` CLI 2.18 or later | ✘ for signd: an outside binary, and an open [report][op-js-216] of it hanging under launchd on macOS 26 while its daemon starts |
| Official Go, JS and Python SDKs | ✔ the Go SDK: MIT, pure Go; it runs 1Password's core, a WebAssembly module, with wazero ([core][sdk-core]) |
| Python SDK's native library | ✘: unsupported interface, ad-hoc signed |
| 1Password Connect | ✘: takes Connect tokens, not service account tokens, and needs a server |

No Swift SDK exists.
The Go SDK's only C code connects to the desktop app, which a service account does not use.

## 3. Change detection

1Password offers no push channel to service accounts: no webhook, long poll or event stream.
The Events API is polled, needs a separate token and a Business plan.

A vault's [`ContentVersion`][sdk-vault] rises whenever its contents change, and one vault list returns it for every readable vault.
An item's overview carries `updatedAt`, and the full item carries `version`.

## 4. Prior art

| Tool | Pattern |
|:--|:--|
| [1Password Kubernetes Operator][k8s-operator] | every 600 s, gets each linked item and [compares its version][k8s-compare] |
| [External Secrets Operator][eso] | `refreshInterval` 1 h by default |
| 1Password SSH agent | `agent.toml` lists items per Mac; with none, serves every SSH Key item in the personal vault |

Retries follow [exponential backoff with full jitter][aws-backoff]; serving the local copy while refreshing follows `stale-while-revalidate` and `stale-if-error` ([RFC 5861][rfc5861]).

## 5. Budget at scale

One check per Mac per interval T costs one read; a changed key then costs about 3 reads per Mac.
Budget: 60% of a Business account's 50,000 daily requests for checks, 20% for changed keys, 20% for other users.
The shortest interval is then 2.88 s times the number of Macs.

| Macs | Shortest T | T | Check reads per day | Reads per changed key |
|:--|:--|:--|:--|:--|
| 10 | 29 s | 5 min | 2,880 | 30 |
| 1,000 | 48 min | 60 min | 24,000 | 3,000 |
| 5,000 | 4 h | 4 h | 30,000 | 15,000 |

Hourly limits hold at every size when each Mac starts at a random point in its interval.
Past about 1,000 Macs, an account needs a raised limit, or a shared service that serves only vault versions, so Macs read 1Password only when something changed.

[op-limits]: https://developer.1password.com/docs/service-accounts/rate-limits/
[sdk-ratelimit]: https://github.com/1password/onepassword-sdk-go/blob/223a222582e69e70a0cb7eea4d85b1942676c413/errors.go#L18-L24
[op-js-216]: https://github.com/1Password/op-js/issues/216
[sdk-core]: https://github.com/1password/onepassword-sdk-go/blob/223a222582e69e70a0cb7eea4d85b1942676c413/internal/extism_core.go#L12-L18
[sdk-vault]: https://github.com/1password/onepassword-sdk-go/blob/223a222582e69e70a0cb7eea4d85b1942676c413/types.go#L1071-L1090
[k8s-operator]: https://github.com/1Password/onepassword-operator/blob/252031374ca9b862506bd66ef66840b9b4c44a19/cmd/main.go#L73-L76
[k8s-compare]: https://github.com/1Password/onepassword-operator/blob/252031374ca9b862506bd66ef66840b9b4c44a19/pkg/onepassword/secret_update_handler.go#L178-L196
[eso]: https://github.com/external-secrets/external-secrets/blob/4fbe79064a5e6bd31582c76219233584dafe82f2/apis/externalsecrets/v1/externalsecret_types.go#L594-L598
[aws-backoff]: https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
[rfc5861]: https://www.rfc-editor.org/rfc/rfc5861
