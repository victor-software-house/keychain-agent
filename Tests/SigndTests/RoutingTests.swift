import Foundation
import KeyStore
import SSHWire
import Testing
@testable import Sync

/// A key with `hosts`, as the store holds it.
func routedKey(_ name: String, hosts: [String]) -> StoredKey {
    var key = storedSoftwareKey(name)
    key.hosts = hosts
    return key
}

func mode(_ url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
}

@Suite struct SSHRouting {
    let home = "/Users/test"

    @Test func eachKeyWithHostsGetsOneBlockInNameOrder() {
        let keys = [
            routedKey("work", hosts: ["git.example.com", "*.example.org"]),
            routedKey("deploy", hosts: ["git.example.com"]),
            routedKey("none", hosts: []),
        ]
        #expect(Routing.config(keys, socket: "/Users/test/.ssh/signd.sock", home: home) == """
        Host git.example.com
          IdentityAgent ~/.ssh/signd.sock
          IdentityFile ~/.ssh/signd/deploy.pub
          IdentitiesOnly yes

        Host git.example.com *.example.org
          IdentityAgent ~/.ssh/signd.sock
          IdentityFile ~/.ssh/signd/work.pub
          IdentitiesOnly yes

        """)
    }

    @Test func aHostPatternWithAnythingButPatternCharactersIsNeverWritten() {
        let keys = [routedKey("bad", hosts: ["example.com ProxyCommand x"]), routedKey("semicolon", hosts: ["a.example.com", "b;c"])]
        #expect(Routing.config(keys, socket: "/Users/test/.ssh/signd.sock", home: home).isEmpty)
    }

    @Test func aSocketOutsideTheHomeIsWrittenInFull() {
        let config = Routing.config([routedKey("k", hosts: ["h"])], socket: "/tmp/a b/s.sock", home: home)
        #expect(config.contains("IdentityAgent \"/tmp/a b/s.sock\""))
    }

    @Test func writesPrivateFilesAndFollowsTheKeys() throws {
        let directory = try TestDirectory()
        let socket = directory.url.appendingPathComponent(".ssh/signd.sock").path
        let deploy = routedKey("deploy", hosts: ["git.example.com"])
        let work = routedKey("work", hosts: ["work.example.com"])
        try Routing.write([deploy, work], socket: socket, home: directory.url)

        let folder = directory.url.appendingPathComponent(".ssh/signd")
        #expect(try mode(folder) == 0o700)
        #expect(try mode(folder.appendingPathComponent("config")) == 0o600)
        #expect(try mode(folder.appendingPathComponent("deploy.pub")) == 0o644)
        let line = try #require(deploy.publicKey?.openSSHLine(comment: deploy.displayComment))
        #expect(try String(contentsOf: folder.appendingPathComponent("deploy.pub"), encoding: .utf8) == line + "\n")
        let config = try String(contentsOf: folder.appendingPathComponent("config"), encoding: .utf8)
        #expect(config.contains("Host git.example.com\n"))
        #expect(config.contains("Host work.example.com\n"))

        // The last host of a key goes, and a key goes: their blocks and public files go with them.
        var bare = deploy
        bare.hosts = []
        try Routing.write([bare], socket: socket, home: directory.url)
        #expect(try String(contentsOf: folder.appendingPathComponent("config"), encoding: .utf8).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["config"])
    }

    @Test func noTemporaryFileRemains() throws {
        let directory = try TestDirectory()
        try Routing.write([routedKey("deploy", hosts: ["h"])], socket: "/s", home: directory.url)
        try Routing.write([routedKey("deploy", hosts: ["h", "i"])], socket: "/s", home: directory.url)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.appendingPathComponent(".ssh/signd").path)
        #expect(names.sorted() == ["config", "deploy.pub"])
    }
}

let routingHome = ProcessInfo.processInfo.environment["SIGND_E2E_ROUTING_HOME"]

/// Writes the files that `mise run ci:e2e` checks with `ssh -G`; it runs only when that task names a directory.
@Suite(.enabled(if: routingHome != nil)) struct RoutingForEndToEnd {
    @Test func writesTheFilesForTheShellScenarios() throws {
        let home = URL(fileURLWithPath: try #require(routingHome), isDirectory: true)
        let step = ProcessInfo.processInfo.environment["SIGND_E2E_ROUTING_STEP"] ?? "1"
        let deploy = routedKey("deploy", hosts: step == "1" ? ["git.example.com"] : [])
        let other = routedKey("other", hosts: ["git.example.com", "*.example.org"])
        let bad = routedKey("bad", hosts: ["evil.example.com ProxyCommand x"])
        try Routing.write([deploy, other, bad], socket: home.appendingPathComponent(".ssh/signd.sock").path, home: home)
    }
}
