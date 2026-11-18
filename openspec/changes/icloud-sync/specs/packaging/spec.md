# packaging

## MODIFIED Requirements

### Requirement: A signed app bundle

The release SHALL be `Signd.app`, identifier `com.victor-software-house.signd`.
It SHALL be signed with a Developer ID Application identity and the hardened runtime.
Its embedded Developer ID provisioning profile SHALL authorize three things:

- its keychain access group;
- signd's iCloud container, with CloudKit in the production environment;
- push notifications.

#### Scenario: The bundle passes Gatekeeper

- **WHEN** the release package is installed
- **THEN** `spctl --assess --type execute /Applications/Signd.app` accepts it
- **AND** `codesign -d --entitlements -` on its binary lists these values:
  - the keychain access group
  - the iCloud container
  - `CloudKit`
  - the `Production` container environment
  - the push environment
