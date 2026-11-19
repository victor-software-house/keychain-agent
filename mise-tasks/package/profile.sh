#!/bin/sh
#MISE description="Install the Developer ID provisioning profile from SIGND_PROVISIONING_PROFILE for Xcode, check its iCloud container, and write DEVELOPMENT_TEAM and SIGND_PROFILE_UUID to GITHUB_ENV"
# The Release workflow runs this before package. SIGND_PROVISIONING_PROFILE contains the profile, base64.
# The team and the profile's UUID come from it, so the repository contains no team identifier.
set -eu

fail() {
  echo "✘ $1" >&2
  exit 1
}

mkdir -p build
printf '%s' "${SIGND_PROVISIONING_PROFILE:?}" | base64 -d > build/signd.provisionprofile
security cms -D -i build/signd.provisionprofile > build/profile.plist
uuid=$(plutil -extract UUID raw -o - build/profile.plist)
team=$(plutil -extract TeamIdentifier.0 raw -o - build/profile.plist)

# App/Signd.entitlements derives signd's container from the bundle identifier.
# Xcode fails the archive when the profile does not allow it.
# The profile must also list that one container, since the app reads it from its signature.
#
# PlistBuddy steps through a key path at each colon, so an entitlement name keeps its dots.
# plutil steps at each dot, and the runner's plutil finds no key under an escaped one.
plutil -extract Entitlements xml1 -o build/profile-entitlements.plist build/profile.plist
profile_entitlements() { /usr/libexec/PlistBuddy "$@" build/profile-entitlements.plist; }
containers=$(profile_entitlements -c 'Print :com.apple.developer.icloud-container-identifiers' 2> /dev/null) || containers=none
container=$(profile_entitlements -c 'Print :com.apple.developer.icloud-container-identifiers:0' 2> /dev/null) || container=
if [ "$container" != "${CLOUDKIT_CONTAINER:?}" ] || profile_entitlements -c 'Print :com.apple.developer.icloud-container-identifiers:1' > /dev/null 2>&1; then
  fail "the profile must list exactly the iCloud container $CLOUDKIT_CONTAINER, which App/Signd.entitlements derives, not $containers"
fi

# Xcode 16 and later read installed profiles from this folder.
profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$profiles"
cp build/signd.provisionprofile "$profiles/$uuid.provisionprofile"
printf 'DEVELOPMENT_TEAM=%s\nSIGND_PROFILE_UUID=%s\n' "$team" "$uuid" >> "${GITHUB_ENV:?}"
echo "✔ the profile is installed and lists $CLOUDKIT_CONTAINER"
