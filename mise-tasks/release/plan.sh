#!/bin/sh
#MISE description="Write the version on HEAD, the commit to package and whether to build signd.pkg, to GITHUB_OUTPUT"
# A published run builds the package only when the version's GitHub release exists and lacks
# signd.pkg, so a push that releases nothing costs no macOS job; a run with publish off always
# builds HEAD, as a run artifact.
set -eu
read -r version < VERSION
ref=v$version
if [ "${PUBLISH:?}" != true ]; then
  build=true ref=$GITHUB_SHA
elif ! assets=$(gh release view "v$version" --json assets --jq '.assets[].name' 2> /dev/null); then
  build=false
elif printf '%s\n' "$assets" | grep -qx signd.pkg; then
  build=false
else
  build=true
fi
echo "v$version build=$build ref=$ref"
printf 'version=%s\nbuild=%s\nref=%s\n' "$version" "$build" "$ref" >> "$GITHUB_OUTPUT"
