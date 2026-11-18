# Research

## 1. The trial

Two Macs on one Apple account ran a trial on 2026-11-18.
The trial agent was signed with signd's Developer ID profile and used the production CloudKit container.

Both clocks were within 2 ms of `time.apple.com`, by `sntp`, so the times below compare across the Macs.
The trial wrote `Key` records with a small JSON payload into a `signd` zone, and the other Mac logged when each one arrived.
The zone, its records and the subscription were deleted afterwards.

| Measure | Result |
|:--|:--|
| A save, to CloudKit's modification time | 0.19 to 0.25 s |
| A check with no change | 1 request, median 0.27 s, 95th percentile 0.66 s, with a change token of about 280 bytes |
| A check that finds a change | 2 requests, about 0.6 s; the record's payload was 82 to 89 bytes |
| A save seen on the other Mac, checking every 2 s | 142 of 142 over 65 minutes; median 1.6 to 2.0 s, 95th percentile 2.8 s, slowest 3.4 s |
| A check that started after the save's time but missed it | none; one that started 0.033 s after it found it |
| Throttle errors | none in 3,943 checks |
| Network errors | 3, all in one outage that lasted about 5 seconds; one request waited 18.7 s before it failed |

The slowest arrival took 2.64 s in one sample.
It had 0.23 s of save, 1.78 s of waiting for the next check, and 0.64 s of check.

The wait for the next check is most of the delay.
So only a shorter interval cuts it.
The request that waited 18.7 s is why each request has its own timeout.

## 2. Pushes

| Push | Saves | Pushes received | Save to push |
|:--|:--|:--|:--|
| Content-available only, sent at priority 5 | 11 | 2 | 15.6 s and 19.9 s |
| With a badge, sent at priority 10, first Mac to second | 10 | 3 | 0.38 s, 9.2 s and 20.5 s; the rest came 31 to 107 s later or not at all |
| With a badge, sent at priority 10, second Mac to first | 11 | 0 | none |

A push is 298 bytes.
It identifies the container, the subscription and the zone.
It carries no record data.

CloudKit documents pushes as merged and throttled ([CKDatabaseSubscription], [background updates]).
The trial measured the same.
So a push can only start a check early.
The `apsd` log on the receiving Mac showed the badge subscription's pushes at priority 10.

## 3. Limits and costs

| Limit | Value |
|:--|:--|
| One record | 1 MB; a key shared with ten Macs is under 30 KB |
| Records per request | 400, a guideline |
| Rate limits | not published; a throttled call returns a retry-after time ([TN3162]) |
| Database subscriptions | custom zones only |
| A push to the Mac that saved | never sent |

The private database counts against the user's own iCloud storage, and Apple lists no fee for requests or pushes ([CKDatabase.Scope.private]).

## 4. Who can sync

- A user of the notarized release who is signed in to iCloud syncs in their own account, with Advanced Data Protection on or off.
- An account restricted by parental controls or a device management profile may have no CloudKit; signd keeps its local keys.
- A build from source cannot open signd's container: CloudKit and push are entitlements that only a profile from the owning team grants ([TN3125]).
  NetNewsWire, an open-source reader that syncs through CloudKit, ships its source builds with a second entitlements file and no iCloud ([NetNewsWire]).

## 5. Who can read a key

| Who | What they can read |
|:--|:--|
| The signd team, in the CloudKit console | counts and which records changed, under anonymous user ids; no payload |
| Apple, for a user without Advanced Data Protection | the keys of CloudKit's encrypted fields, held in Apple's hardware security modules |
| Apple, with Advanced Data Protection | encrypted fields are end-to-end encrypted |
| Anyone, given signd's own sealing | only ciphertext: each copy opens only with one Mac's Secure Enclave key |

Sources: [Encrypting user data], [Advanced Data Protection].

[CKDatabaseSubscription]: https://developer.apple.com/documentation/cloudkit/ckdatabasesubscription
[background updates]: https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app
[TN3162]: https://developer.apple.com/documentation/technotes/tn3162-understanding-cloudkit-throttles
[CKDatabase.Scope.private]: https://developer.apple.com/documentation/cloudkit/ckdatabase/scope/private
[TN3125]: https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
[NetNewsWire]: https://github.com/Ranchero-Software/NetNewsWire
[Encrypting user data]: https://developer.apple.com/documentation/cloudkit/encrypting-user-data
[Advanced Data Protection]: https://support.apple.com/en-us/102651
