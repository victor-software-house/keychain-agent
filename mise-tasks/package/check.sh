#!/bin/sh
#MISE description="Expand build/signd.pkg and check the title, the host architecture and the macOS floor that its Installer distribution sets"
# The Release workflow runs this on the package it built.
set -eu

fail() {
  echo "✘ $1" >&2
  exit 1
}

rm -rf build/expanded
pkgutil --expand build/signd.pkg build/expanded
distribution() {
  xmllint --xpath "$1" build/expanded/Distribution
}

# Package.swift's .macOS(.v26) is macOS 26.0.
floor=$(sed -n 's/.*\.macOS(\.v\([0-9]*\)).*/\1.0/p' Package.swift)
[ -n "$floor" ] || fail "Package.swift names no macOS deployment target"

[ "$(distribution 'string(//title)')" = signd ] || fail "the distribution's title is not signd"
[ "$(distribution 'string(//options/@hostArchitectures)')" = arm64 ] || fail "the distribution's hostArchitectures is not arm64"
[ "$(distribution 'string(//allowed-os-versions/os-version/@min)')" = "$floor" ] || fail "the distribution's allowed-os-versions is not macOS $floor"
[ "$(distribution 'string(//domains/@enable_localSystem)')" = true ] || fail "the distribution's domains do not enable the local system"
echo "✔ the package's distribution has the title signd, arm64 as its host architecture, macOS $floor as its floor, and installs on the boot volume"
