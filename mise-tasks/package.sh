#!/bin/sh
#MISE description="Build build/signd.pkg: Signd.app signed with the Developer ID and its provisioning profile, in a signed package, notarized and stapled"
# The Release workflow runs this on the xcode-27 runner.
# By then macos-signing has imported both Developer ID identities and the notary key.
# They sit in a keychain that contains only them, so each --sign selects the identity by its certificate type.
#
# SIGND_PROVISIONING_PROFILE contains the Developer ID profile, base64.
# The entitlements come from it, so the repository contains no team identifier.
set -eu

rm -rf build
swift build -c release
app=build/root/Applications/Signd.app
version=$(cat VERSION)
mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchAgents"
cp Bundle/Info.plist "$app/Contents/Info.plist"
# actool compiles the Icon Composer icon into Assets.car and AppIcon.icns, which Info.plist names.
mkdir -p "$app/Contents/Resources"
xcrun actool Bundle/AppIcon.icon --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 \
  --app-icon AppIcon --output-partial-info-plist build/icon.plist --errors > /dev/null
test -f "$app/Contents/Resources/Assets.car"
test -f "$app/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"
cp Bundle/com.victor-software-house.signd.plist "$app/Contents/Library/LaunchAgents/"
ditto "$(swift build -c release --show-bin-path)/signd" "$app/Contents/MacOS/signd"
printf '%s' "$SIGND_PROVISIONING_PROFILE" | base64 -d > "$app/Contents/embedded.provisionprofile"

# The profile allows <team>.*; signd claims one group, <team>.com.victor-software-house.signd.
# The profile also grants iCloud with wildcards.
# signd claims CloudKit in production on the one container that the App ID lists, and the agent reads it back from its signature.
# It also claims push for the container's subscription, and none of the key-value or document stores.
#
# PlistBuddy steps through a key path at each colon.
# An entitlement name therefore keeps its dots.
# plutil steps at each dot, and the runner's plutil finds no key under an escaped one.
security cms -D -i "$app/Contents/embedded.provisionprofile" > build/profile.plist
plutil -extract Entitlements xml1 -o build/signd.entitlements build/profile.plist
team=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' build/profile.plist)
entitlements() { /usr/libexec/PlistBuddy "$@" build/signd.entitlements; }
for key in keychain-access-groups com.apple.developer.icloud-services com.apple.developer.icloud-container-environment \
  com.apple.developer.aps-environment com.apple.developer.ubiquity-container-identifiers com.apple.developer.ubiquity-kvstore-identifier; do
  entitlements -c "Delete :$key" > /dev/null 2>&1 || true
done
entitlements -c 'Add :keychain-access-groups array' -c "Add :keychain-access-groups:0 string $team.com.victor-software-house.signd"
entitlements -c 'Add :com.apple.developer.icloud-services array' -c 'Add :com.apple.developer.icloud-services:0 string CloudKit'
containers=$(entitlements -c 'Print :com.apple.developer.icloud-container-identifiers' 2> /dev/null) || containers=none
container=$(entitlements -c 'Print :com.apple.developer.icloud-container-identifiers:0' 2> /dev/null) || container=
if [ -z "$container" ] || entitlements -c 'Print :com.apple.developer.icloud-container-identifiers:1' > /dev/null 2>&1; then
  echo "✘ the profile must name exactly one iCloud container, not $containers" >&2
  exit 1
fi
case "$container" in
  *'*'*)
    echo "✘ the profile must name one iCloud container, not the pattern $container" >&2
    exit 1
    ;;
esac
entitlements -c 'Add :com.apple.developer.icloud-container-environment string Production' \
  -c 'Add :com.apple.developer.aps-environment string production'

codesign --force --options runtime --timestamp --entitlements build/signd.entitlements --sign 'Developer ID Application' "$app"
codesign --verify --strict --deep --verbose=2 "$app"

# pkgbuild marks bundles relocatable by default; signd must stay in /Applications.
pkgbuild --analyze --root build/root build/components.plist
plutil -replace 0.BundleIsRelocatable -bool NO build/components.plist
pkgbuild --root build/root --component-plist build/components.plist --scripts Bundle/scripts --install-location / \
  --identifier com.victor-software-house.signd.pkg --version "$version" build/signd-component.pkg
# The Installer pages are in Bundle/Installer. The license page is LICENSE.
mkdir build/installer
cp Bundle/Installer/welcome.html Bundle/Installer/conclusion.html build/installer/
cp LICENSE build/installer/license.txt
productbuild --distribution Bundle/Installer/distribution.xml --resources build/installer --package-path build \
  --sign 'Developer ID Installer' build/signd.pkg
xcrun notarytool submit build/signd.pkg --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
xcrun stapler staple build/signd.pkg
