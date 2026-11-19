# Research: deploying signd through Mobile Device Management (MDM)

Read on 2026-11-19 UTC.

## 1. What an admin needs

1. A signed, notarized distribution package from the organization's MDM server, installed through `InstallEnterpriseApplication` or the MDM's own package deploy ([Apple, packages][apple-pkg]; [InstallEnterpriseApplication][iea]).
2. A managed login items profile, `com.apple.servicemanagement`, from macOS 13, device channel only, which a user cannot install by hand ([payload][sm-yaml]).
   Its `Rules` match by `BundleIdentifier`, `BundleIdentifierPrefix`, `Label`, `LabelPrefix` or `TeamIdentifier`.
   An optional `TeamIdentifier` key is checked after the match.
3. A matching item is approved with no prompt.
   macOS shows one notice that managed items were installed ([Apple, login items][apple-bgt]).
   From macOS 26, a rule by bundle identifier, bundle prefix or team avoids the prompt for tasks that outlive their app.
   A label rule does not.
4. Without the profile, `SMAppService.register()` registers the service subject to user approval ([SMAppService][smapp]).

## 2. Who controls what

The payload contains only match strings: no address, key or callback ([payload][sm-yaml]).
The organization writes the profile, signs it if its MDM needs that, and pushes it.
No part of this belongs to the publisher.
A Mac has one MDM, and removing its enrollment removes the profiles it installed ([MDM profiles][apple-mdm]).

Kandji recommends team rules over bundle rules because bundle identifiers can be copied ([Kandji][kandji]).
A bundle rule that also sets the `TeamIdentifier` key approves signd alone.

## 3. The team identifier is public

Apple writes it into every signing certificate's Organizational Unit (OU) field ([TN3161][tn3161]), and `codesign -dv` prints it for any app.
Vendors publish theirs in their MDM docs, among them Microsoft ([Defender][mdatp]) and Tailscale ([Tailscale][tailscale]).
signd keeps it out of the repository, so the code contains no team and a fork can sign with its own.

## 4. What vendors ship

Microsoft keeps unsigned `.mobileconfig` files in a public repository ([mdatp-xplat][mdatp-sm]).
Tailscale shows inline XML, and Zoom gives values only.
Admins sign a profile when their MDM needs it.
Jamf leaves a signed upload unchanged ([Jamf][jamf-upload]).

[apple-pkg]: https://support.apple.com/guide/deployment/distribute-packages-to-mac-computers-dep873c25ac4/web
[iea]: https://github.com/apple/device-management/blob/9e7fdbe23990b2551c4b29b39bc8b0de956805eb/mdm/commands/application.install.enterprise.yaml
[sm-yaml]: https://github.com/apple/device-management/blob/9e7fdbe23990b2551c4b29b39bc8b0de956805eb/mdm/profiles/com.apple.servicemanagement.yaml
[apple-bgt]: https://support.apple.com/guide/deployment/manage-login-items-background-tasks-mac-depdca572563/web
[smapp]: https://developer.apple.com/documentation/servicemanagement/smappservice
[apple-mdm]: https://support.apple.com/guide/deployment/intro-to-mdm-profiles-depc0aadd3fe/web
[kandji]: https://support.kandji.io/kb/configure-the-login-background-items-library-item
[tn3161]: https://developer.apple.com/documentation/technotes/tn3161-inside-code-signing-certificates
[mdatp]: https://learn.microsoft.com/en-us/defender-endpoint/mac-support-sys-ext
[tailscale]: https://tailscale.com/docs/integrations/mdm/mac
[mdatp-sm]: https://github.com/microsoft/mdatp-xplat/blob/6f37485b1d742567ffbd5cf597b30f6ec5398dbd/macos/mobileconfig/profiles/background_services.mobileconfig
[jamf-upload]: https://learn.jamf.com/r/en-US/jamf-pro-documentation-current/Uploading_a_Configuration_Profile_macOS
