# Research

Retrieved 2026-11-19 (UTC).

The local toolchain for the experiments is Xcode 27.2 (27B52) and XcodeGen 2.47.0.

## 1. Icon Composer `.icon` in an Xcode build

1.1 Xcode treats `.icon` as file type `folder.iconcomposer.icon`, based on `folder.abstractassetcatalog`.

Source: Xcode 27.2 `SWBUniversalPlatform.framework/Resources/StandardFileTypes.xcspec`, lines 1436-1443 (local file in Xcode.app).

1.2 The asset catalog compiler (actool) takes that type as an input, through a synthesized build rule, in the Copy Bundle Resources phase.

Source: Xcode 27.2 `SWBApplePlatform.framework/Resources/AssetCatalogCompiler.xcspec`, lines 26-40 (local file).

Ghostty does the same in its hand-made project.
It lists `Ghostty.icon` with `lastKnownFileType = folder.iconcomposer.icon` in Resources ([pbxproj L80][gh-ref], [L390][gh-res]).

1.3 The build setting is `ASSETCATALOG_COMPILER_APPICON_NAME`, which Xcode passes as `actool --app-icon`.
Its value is the `.icon` file name without its extension.

Sources: AssetCatalogCompiler.xcspec lines 224-231 (local).
Apple, [Creating your app icon using Icon Composer][apple-icon], section "Add your Icon Composer file to an Xcode project".
That section requires the App Icon field to match the file name, and the `.icon` file replaces an `AppIcon` asset catalog.

Ghostty sets `ASSETCATALOG_COMPILER_APPICON_NAME = Ghostty` ([L538][gh-name]).

1.4 No asset catalog is needed.

Verified: a stub macOS app with only `AppIcon.icon` (signd's icon from commit 36eb336) and `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` built with `xcodebuild`.
actool produced `Contents/Resources/Assets.car` and `AppIcon.icns`.
Xcode merged `CFBundleIconFile = AppIcon` and `CFBundleIconName = AppIcon` into the built Info.plist from actool's partial plist.

Evidence: `(local experiment)` lines 165-177 and 303, product `(local experiment)`.

So the hand-written `CFBundleIconFile` and `CFBundleIconName` keys in `Bundle/Info.plist` go away.

## 2. XcodeGen support for `.icon`

2.1 XcodeGen supports `.icon` since 2.45.1.
The [CHANGELOG L78][xg-chg] entry reads "Added built in `.icon` folder support for IconComposer `#1600`".
The change is PR [#1600][xg-1600], merged 2026-03-05.

It adds `icon` to the default file types with build phase `resources` ([FileType.swift L77][xg-ft]).
So a `.icon` listed in `sources` becomes one file reference in Copy Bundle Resources, and its inner files do not.

Issue [#1556][xg-1556] (still open) reported the old behaviour, where the inner `icon.json` and SVGs went into Resources.
A 2026-11-10 comment there reports it fixed in 2.46.0.

2.2 Known quirk: XcodeGen writes `lastKnownFileType = wrapper.icon` ([XCProjExtensions.swift L68-69][xg-ext]).
Xcode's own type is `folder.iconcomposer.icon`.
XcodeProj 9.17.8 maps `icon` to `folder.iconcomposer.icon` ([Xcode.swift L178][xp-map]), and XcodeGen's override wins.

`wrapper.icon` is in no Xcode 27.2 spec (searched the SwiftBuild and XCBuild frameworks).

Verified anyway: with the `wrapper.icon` reference, Xcode 27.2 still ran `actool` on the icon.
It produced Assets.car, AppIcon.icns and the Info.plist keys (1.4).
XcodeGen 2.47.0 generated the stub.

Inference: Xcode resolves the type by extension when the stored type is unknown.
This is not verified on Xcode 26.x.

2.3 Declaration: list the icon in `sources` (`- Bundle/AppIcon.icon`) and set `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`.

Karabiner-Elements is a well-maintained project that does exactly this with XcodeGen.
It lists `KarabinerElements.icon` in sources and sets the app icon name ([project.yml L33][ke-py]).

signd's mise pin should be XcodeGen 2.47.0.
lattice and mac-use pin 2.46.0, and both have the fix.

## 3. App target from a SwiftPM package

3.1 XcodeGen links local package products through a top-level `packages: {Name: {path: .}}`.
Target dependencies then read `- package: Name, product: X` ([ProjectSpec L1259-1290][xg-pkg], [Dependency L604][xg-dep]).

Verified: a stub app target with `@main` in its own source file depended on a local library product.
It built and ran the linked code path (`(local experiment)`).

3.2 In-house prior art: lattice keeps all modules in `Package.swift` and declares `packages: Lattice: path: .`.
Its app target has only `App/` sources plus package products.

Source: local checkout `machine-state/lattice` at 4eea78c, `project.yml` lines 7-9 and 56-63.

3.3 A package executable target cannot be an Xcode target's sources or product.
The app target needs library products.

So signd's command code moves from the `signd` executable target into a library target with a library product.
Two thin entry points then call it.
One is the SwiftPM `signd` executable, for `swift build`, `swift test` and Linux CI.
The other is the Xcode app target's one-file `@main`.

This is inference from 3.1 and SwiftPM product rules.
It is not a quoted Apple rule.

3.4 Names: `PRODUCT_NAME: Signd` with `EXECUTABLE_NAME: signd` builds `Signd.app/Contents/MacOS/signd` with `CFBundleExecutable = signd`.
So `BundleProgram` in the agent plist stays `Contents/MacOS/signd`.

Verified in `(local experiment)`.

lattice notes that `lattice.app` and `Lattice.app` collide on a case-insensitive volume.
So no second target may be named `signd`.

3.5 The agent plist location: `SMAppService.agent(plistName:)` requires the plist in the app's `Contents/Library/LaunchAgents` ([Apple][apple-agent]).

## 4. The declarative pieces

4.1 Info.plist: XcodeGen's `info:` writes the plist from `properties` at every generate ([ProjectSpec L757][xg-plist]).
Xcode adds the rest: CFBundleExecutable, the identifier, the platform keys and the icon keys.

Keep `LSUIElement: true`, `CFBundleShortVersionString: $(MARKETING_VERSION)` and `CFBundleVersion: $(CURRENT_PROJECT_VERSION)`, as lattice does.

4.2 LaunchAgents plist: a source with `buildPhase: copyFiles: {destination: wrapper, subpath: Contents/Library/LaunchAgents}` ([ProjectSpec L595][xg-copy]).

Verified: XcodeGen wrote a Copy Files phase with `dstSubfolderSpec = 1` and `dstPath = Contents/Library/LaunchAgents`.
The plist landed at `Signd.app/Contents/Library/LaunchAgents/` (`(local experiment)`).

Karabiner-Elements instead copies its LaunchAgents plists with `cp` after `xcodebuild` ([Makefile L5-7][ke-mk]).
The copy phase is the declarative form.

4.3 Version: passing `MARKETING_VERSION=1.2.3 CURRENT_PROJECT_VERSION=1.2.3` on the `xcodebuild` command line set both Info.plist keys (verified, `(local experiment)`).

So the task reads `VERSION` and passes it, with no plist edit after the build.
XcodeGen can also expand `${VAR}` from the environment at generate time ([ProjectSpec L10][xg-env]).

4.4 Entitlements: `CODE_SIGN_ENTITLEMENTS` names a file, and Xcode evaluates build settings inside it.
Examples are `$(TeamIdentifierPrefix)` and `$(AppIdentifierPrefix)` ([swift-build PlanningOperation.swift L203-239][sb-ent]).

lattice claims its keychain group as `$(AppIdentifierPrefix)com.victor-software-house.lattice`.
signd's group `<team>.com.victor-software-house.signd` becomes `$(TeamIdentifierPrefix)com.victor-software-house.signd`, which names no team.

Xcode 16 and later validate at build time that the profile allow-lists every restricted entitlement in the file ([Xcode 16 release notes, 130299863][xc16]).

The iCloud container must appear in the file as `com.apple.developer.icloud-container-identifiers`, for example as `iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)`.
This conflicts with signd AGENTS.md 2.7 ("named only in the App ID").
The operator chose the derived name (operator, 2026-11-19).

`com.apple.developer.icloud-container-environment` comes from the `-exportOptionsPlist` key `iCloudContainerEnvironment`.
It defaults to Production for distribution signing (local `xcodebuild -help`, Xcode 27.2).

`aps-environment` goes to `production` for distribution ([Apple, Creating distribution-signed code][apple-dist], "Configure your entitlements").

4.5 Profile and signing: macOS products embed the profile as `Contents/embedded.provisionprofile` (`EMBEDDED_PROFILE_NAME` default, [macOSCoreBuildSystem.xcspec L58-60][sb-emb]).

Manual signing names the profile with `PROVISIONING_PROFILE_SPECIFIER` (name or UUID).
It also needs `CODE_SIGN_STYLE = Manual`, `CODE_SIGN_IDENTITY = Developer ID Application` and `DEVELOPMENT_TEAM`.
lattice keeps these in `packaging/DeveloperID.xcconfig`, passed with `-xcconfig`.

For a public repository, CI passes `DEVELOPMENT_TEAM` and the profile UUID on the command line.
Both are read from the decoded profile (`TeamIdentifier`, `UUID`).

Xcode 16 and later read installed profiles from `~/Library/Developer/Xcode/UserData/Provisioning Profiles` ([Xcode 16 release notes, 48821779][xc16]).
CI writes the decoded profile there as `<UUID>.provisionprofile`.

## 5. CI build: archive and export, then the package

5.1 For a Mac app bundle built with Xcode, Apple recommends using Xcode "to export a distribution-signed app".
That means building an archive, then exporting it.
Both steps run with `xcodebuild` ([Creating distribution-signed code for macOS][apple-dist]).

An app with an associated daemon, or one distributed directly, then goes into a container such as an Installer package ([Packaging Mac software for distribution][apple-pack]).

5.2 `-exportOptionsPlist` keys for this case (Xcode 27.2 `xcodebuild -help`): `method: developer-id`, `signingStyle: manual`, `signingCertificate: Developer ID Application`, `provisioningProfiles: {bundle-id: name-or-UUID}`, `iCloudContainerEnvironment` and `teamID`.

The old method names `app-store`, `ad-hoc` and `development` are deprecated.
`developer-id` is current.

5.3 What projects do:

- lattice and mac-use (in-house): `xcodebuild archive -xcconfig packaging/DeveloperID.xcconfig`.
  Then `xcodebuild -exportArchive` with `method developer-id`, manual signing and per-bundle profiles.
  Then `ditto` the export into a root, `pkgbuild`, `productbuild --sign`, `notarytool submit --wait` and `stapler staple` (lattice `mise.toml` lines 77-101, `packaging/ExportOptions.plist`).
- Ghostty: `xcodebuild -target Ghostty -configuration Release`.
  Then manual `codesign -o runtime` inside out, a disk image (DMG), notarization and stapling ([release-tag.yml L187][gh-b], [L237][gh-cs], [L268][gh-n]).
- CodeEdit: `xcodebuild archive`, then manual `codesign` of the archived app, with no `-exportArchive` ([pre-release.yml L51][ce-a], [L62-66][ce-cs]).
- Karabiner-Elements: XcodeGen plus `xcodebuild`, then a shell `codesign.sh`, `pkgbuild` and `productbuild` ([make-package.sh][ke-pkg]).

Ghostty and CodeEdit claim no profile-authorized entitlements, so manual `codesign` suffices there.
signd claims keychain groups and iCloud, which need the profile.
So export is the closer fit.

5.4 Notarization of a signed flat package is supported, and the ticket covers nested items ([Customizing the notarization workflow][apple-notar]).

`pkgbuild` and `productbuild` stay.
Xcode does not produce a Developer ID Installer package for an app with an embedded agent and install scripts.

## 6. Is the hand-assembled bundle wrong?

6.1 No Apple document found forbids it.
Apple documents manual signing for products from "an external build system, such as `make`" ([Creating distribution-signed code][apple-dist]).

The current script follows its rules: inside-out signing, `--timestamp`, `-o runtime`, the profile at `Contents/embedded.provisionprofile`, and entitlements narrowed to what the profile allows ([Placing content in a bundle][apple-bundle]).

6.2 The Xcode path adds four things:

- Apple's recommended path for an Xcode-built app (5.1).
- Build-time validation of entitlements against the profile (4.4).
- An actool run with the full argument set Xcode passes (`--target-device mac`, `--development-region`, the partial Info.plist merge), where the script's call omits some.
- dSYMs in the archive.

## 7. Not verified

1. The iCloud container: Xcode's build validation rejects a container the profile does not allow, which covers part of the script's single-container check.
2. `wrapper.icon` worked on Xcode 27.2 only, and Xcode 26.x is not tested.
3. `-exportArchive` with manual signing and a profile given by UUID was not run, because no Developer ID identity was used here.
   lattice runs the same flow with profile names in CI.
4. Whether `-exportArchive` rewrites `aps-environment` is not in Apple's documents, so set it in the file.

## 8. Sources left out

- GitHub code search hits for `project.yml` with `SMAppService` or `Library/LaunchAgents` are mostly small or new repositories.
  Only Karabiner-Elements and `ShadowsocksX-NG` are established, and only Karabiner was read.
- Apple's entitlement page for `icloud-container-environment` has a one-line abstract only, so the `xcodebuild -help` text was used instead.

[apple-icon]: https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer
[apple-agent]: https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:)
[apple-dist]: https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac
[apple-pack]: https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution
[apple-notar]: https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
[apple-bundle]: https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle
[xc16]: https://developer.apple.com/documentation/xcode-release-notes/xcode-16-release-notes
[xg-chg]: https://github.com/yonaskolb/XcodeGen/blob/d212e4debe1031fd5979892ce9ba3e87fa580278/CHANGELOG.md#L78
[xg-1600]: https://github.com/yonaskolb/XcodeGen/pull/1600
[xg-1556]: https://github.com/yonaskolb/XcodeGen/issues/1556
[xg-ft]: https://github.com/yonaskolb/XcodeGen/blob/d212e4debe1031fd5979892ce9ba3e87fa580278/Sources/ProjectSpec/FileType.swift#L77
[xg-ext]: https://github.com/yonaskolb/XcodeGen/blob/d212e4debe1031fd5979892ce9ba3e87fa580278/Sources/XcodeGenKit/XCProjExtensions.swift#L68-L69
[xg-pkg]: https://github.com/yonaskolb/XcodeGen/blob/d212e4debe1031fd5979892ce9ba3e87fa580278/Docs/ProjectSpec.md#L1259-L1290
[xg-dep]: https://github.com/yonaskolb/XcodeGen/blob/d212e4debe1031fd5979892ce9ba3e87fa580278/Docs/ProjectSpec.md#L604
[xg-plist]: https://github.com/yonaskolb/XcodeGen/blob/d212e4debe1031fd5979892ce9ba3e87fa580278/Docs/ProjectSpec.md#L757
[xg-copy]: https://github.com/yonaskolb/XcodeGen/blob/d212e4debe1031fd5979892ce9ba3e87fa580278/Docs/ProjectSpec.md#L591-L598
[xg-env]: https://github.com/yonaskolb/XcodeGen/blob/d212e4debe1031fd5979892ce9ba3e87fa580278/Docs/ProjectSpec.md#L10
[xp-map]: https://github.com/tuist/XcodeProj/blob/df6041d0dc3b493d38525bbc5b1fcd36bb99ff22/Sources/XcodeProj/Project/Xcode.swift#L178
[sb-ent]: https://github.com/swiftlang/swift-build/blob/e82354bb9501accd6cb8a5c6dcde9074c6ab9f81/Sources/SWBBuildService/PlanningOperation.swift#L203-L239
[sb-emb]: https://github.com/swiftlang/swift-build/blob/e82354bb9501accd6cb8a5c6dcde9074c6ab9f81/Sources/SWBApplePlatform/Specs/macOSCoreBuildSystem.xcspec#L58-L60
[gh-ref]: https://github.com/ghostty-org/ghostty/blob/3f2fe1472882349ca140a83deca150573a7018fb/macos/Ghostty.xcodeproj/project.pbxproj#L80
[gh-res]: https://github.com/ghostty-org/ghostty/blob/3f2fe1472882349ca140a83deca150573a7018fb/macos/Ghostty.xcodeproj/project.pbxproj#L390
[gh-name]: https://github.com/ghostty-org/ghostty/blob/3f2fe1472882349ca140a83deca150573a7018fb/macos/Ghostty.xcodeproj/project.pbxproj#L538
[gh-b]: https://github.com/ghostty-org/ghostty/blob/3f2fe1472882349ca140a83deca150573a7018fb/.github/workflows/release-tag.yml#L187
[gh-cs]: https://github.com/ghostty-org/ghostty/blob/3f2fe1472882349ca140a83deca150573a7018fb/.github/workflows/release-tag.yml#L237
[gh-n]: https://github.com/ghostty-org/ghostty/blob/3f2fe1472882349ca140a83deca150573a7018fb/.github/workflows/release-tag.yml#L268
[ce-a]: https://github.com/CodeEditApp/CodeEdit/blob/fa2aebd86373211c78626074b53ab75010767575/.github/workflows/pre-release.yml#L51
[ce-cs]: https://github.com/CodeEditApp/CodeEdit/blob/fa2aebd86373211c78626074b53ab75010767575/.github/workflows/pre-release.yml#L62-L66
[ke-py]: https://github.com/pqrs-org/Karabiner-Elements/blob/b237a07b74f30a1db713091c9fb89ad071939c27/src/apps/ServiceManager-Non-Privileged-Agents/project.yml#L33
[ke-mk]: https://github.com/pqrs-org/Karabiner-Elements/blob/b237a07b74f30a1db713091c9fb89ad071939c27/src/apps/ServiceManager-Non-Privileged-Agents/Makefile#L5-L7
[ke-pkg]: https://github.com/pqrs-org/Karabiner-Elements/blob/b237a07b74f30a1db713091c9fb89ad071939c27/make-package.sh
