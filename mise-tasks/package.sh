#!/bin/sh
#MISE description="Build build/signd.pkg: Signd.app signed with the Developer ID and its provisioning profile, in a signed package, notarized and stapled"
# The Release workflow runs this on the xcode-27 runner after macos-signing has imported both
# Developer ID identities and the notary key into a keychain that holds only them, so each
# --sign names the identity by its certificate type. SIGND_PROVISIONING_PROFILE holds the
# Developer ID profile, base64; the entitlements come from it, so the repository names no team.
set -eu

rm -rf build
swift build -c release
app=build/root/Applications/Signd.app
version=$(cat VERSION)
mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchAgents"
cp Bundle/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"
cp Bundle/com.victor-software-house.signd.plist "$app/Contents/Library/LaunchAgents/"
ditto "$(swift build -c release --show-bin-path)/signd" "$app/Contents/MacOS/signd"
printf '%s' "$SIGND_PROVISIONING_PROFILE" | base64 -d > "$app/Contents/embedded.provisionprofile"

# The profile allows TEAM.*; signd claims one group, TEAM.com.victor-software-house.signd.
# It also grants iCloud with wildcards; signd claims CloudKit in production on the one
# container the App ID names, which the agent reads back from its signature, and push for the
# container's subscription, and none of the key-value or document stores.
security cms -D -i "$app/Contents/embedded.provisionprofile" > build/profile.plist
plutil -extract Entitlements xml1 -o build/signd.entitlements build/profile.plist
team=$(plutil -extract TeamIdentifier.0 raw build/profile.plist)
plutil -replace keychain-access-groups -json "[\"$team.com.victor-software-house.signd\"]" build/signd.entitlements
plutil -replace com.apple.developer.icloud-services -json '["CloudKit"]' build/signd.entitlements
containers=$(plutil -extract com.apple.developer.icloud-container-identifiers json -o - build/signd.entitlements)
case "$containers" in
  \[\"*\"\]) ;;
  *) echo "✘ the profile must name exactly one iCloud container, not $containers" >&2; exit 1 ;;
esac
plutil -replace com.apple.developer.icloud-container-environment -string Production build/signd.entitlements
plutil -replace com.apple.developer.aps-environment -string production build/signd.entitlements
plutil -remove com.apple.developer.ubiquity-container-identifiers build/signd.entitlements 2> /dev/null || true
plutil -remove com.apple.developer.ubiquity-kvstore-identifier build/signd.entitlements 2> /dev/null || true

codesign --force --options runtime --timestamp --entitlements build/signd.entitlements --sign 'Developer ID Application' "$app"
codesign --verify --strict --deep --verbose=2 "$app"

# pkgbuild marks bundles relocatable by default; signd must stay in /Applications.
pkgbuild --analyze --root build/root build/components.plist
plutil -replace 0.BundleIsRelocatable -bool NO build/components.plist
pkgbuild --root build/root --component-plist build/components.plist --scripts Bundle/scripts --install-location / \
  --identifier com.victor-software-house.signd.pkg --version "$version" build/signd-component.pkg
productbuild --package build/signd-component.pkg --sign 'Developer ID Installer' build/signd.pkg
xcrun notarytool submit build/signd.pkg --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
xcrun stapler staple build/signd.pkg
