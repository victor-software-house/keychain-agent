#!/bin/sh
#MISE description="Build build/signd.pkg: the exported Signd.app in a signed, notarized and stapled package"
#MISE depends=["export"]
# The Release workflow runs this on the xcode-27 runner, after package:profile.
# By then macos-signing has imported both Developer ID identities and the notary key.
# They sit in a keychain that contains only them.
# So each --sign selects the identity by its certificate type.
#
# The export task has signed Signd.app.
set -eu

version=$(cat VERSION)
rm -rf build/root build/installer
mkdir -p build/root/Applications
ditto build/export/Signd.app build/root/Applications/Signd.app

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
