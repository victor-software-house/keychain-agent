#!/bin/sh
#MISE description="Write build/signd.mobileconfig: Bundle/signd.mobileconfig with the team identifier of the signed build/export/Signd.app"
# The Release workflow runs this after package. It needs the exported app and no signing identity.
# The repository contains no team identifier, so the team comes from the app's signature.
set -eu

fail() {
  echo "✘ $1" >&2
  exit 1
}

app=build/export/Signd.app
profile=build/signd.mobileconfig
rule=PayloadContent.0.Rules.0.TeamIdentifier

[ -d "$app" ] || fail "$app is missing: run export first"
# An unsigned build prints TeamIdentifier=not set, which does not match.
team=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
printf '%s\n' "$team" | grep -Eq '^[A-Z0-9]{10}$' || fail "the app's TeamIdentifier is ${team:-missing}, not 10 capital letters and digits"

cp Bundle/signd.mobileconfig "$profile"
plutil -replace "$rule" -string "$team" "$profile"
plutil -lint "$profile"
if grep -q TEAM_IDENTIFIER "$profile"; then fail "$profile still contains TEAM_IDENTIFIER"; fi
[ "$(plutil -extract "$rule" raw -o - "$profile")" = "$team" ] || fail "the profile's team is not the app's"
echo "✔ $profile approves the login items of com.victor-software-house.signd for the team that signed the app"
