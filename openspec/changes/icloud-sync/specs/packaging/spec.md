# packaging

## MODIFIED Requirements

### Requirement: A signed app bundle

The release SHALL be `Signd.app`, identifier `com.victor-software-house.signd`, signed with a Developer ID Application identity and the hardened runtime, with an embedded Developer ID provisioning profile that authorizes its keychain access group, signd's iCloud container with CloudKit in the production environment, and push notifications.

#### Scenario: The bundle passes Gatekeeper

- **WHEN** the release package is installed
- **THEN** `spctl --assess --type execute /Applications/Signd.app` accepts it, and `codesign -d --entitlements -` on its binary lists the keychain access group, the iCloud container, `CloudKit`, the `Production` container environment and the push environment
