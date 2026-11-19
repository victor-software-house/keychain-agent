#!/bin/sh
#MISE description="Write build/ExportOptions.plist for the Developer ID export"
# package:profile sets the team and the profile UUID.
# The repository has no team.
# The export sets the container to Production.
set -eu
mkdir -p build
cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
	<key>teamID</key>
	<string>${SIGND_TEAM:?run package:profile first}</string>
	<key>iCloudContainerEnvironment</key>
	<string>Production</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>com.victor-software-house.signd</key>
		<string>${SIGND_PROFILE_UUID:?run package:profile first}</string>
	</dict>
</dict>
</plist>
EOF
