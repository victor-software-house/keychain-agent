// swift-tools-version: 6.4
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "keychain-agent",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "keychain-agent", targets: ["keychain-agent"]),
    ],
    targets: [
        // The SSH agent message format, with no Security or socket code, so tests check it byte by byte.
        .target(name: "AgentProtocol", swiftSettings: strict),
        .executableTarget(name: "keychain-agent", dependencies: ["AgentProtocol"], swiftSettings: strict),
        .testTarget(
            name: "AgentProtocolTests",
            dependencies: ["AgentProtocol"],
            resources: [.copy("Fixtures")],
            swiftSettings: strict
        ),
    ]
)
