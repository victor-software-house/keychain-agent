import Foundation
import Testing
@testable import Sync

let includeLine = SSHInclude.line

@Test func aMissingSSHFolderAndConfigAreCreatedPrivately() throws {
    let directory = try TestDirectory()
    #expect(try SSHInclude.enable(home: directory.url))
    let folder = directory.url.appendingPathComponent(".ssh")
    #expect(try mode(folder) == 0o700)
    #expect(try mode(folder.appendingPathComponent("config")) == 0o600)
    #expect(try String(contentsOf: folder.appendingPathComponent("config"), encoding: .utf8) == includeLine + "\n\n")
}

@Test func aConfigWithoutTheLineGetsItAtTheTopAndKeepsItsMode() throws {
    let directory = try TestDirectory()
    let folder = directory.url.appendingPathComponent(".ssh")
    let config = folder.appendingPathComponent("config")
    let original = "Host example.com\n  User git\n"
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    #expect(FileManager.default.createFile(atPath: config.path, contents: Data(original.utf8), attributes: [.posixPermissions: 0o640]))
    #expect(try SSHInclude.enable(home: directory.url))
    #expect(try String(contentsOf: config, encoding: .utf8) == includeLine + "\n\n" + original)
    #expect(try mode(config) == 0o640)
    #expect(try !SSHInclude.enable(home: directory.url))
    #expect(try String(contentsOf: config, encoding: .utf8) == includeLine + "\n\n" + original)
    #expect(SSHInclude.isEnabled(home: directory.url))
}

@Test(arguments: [
    "Include ~/.ssh/signd/config",
    "include ~/.ssh/signd/config",
    "INCLUDE ~/.ssh/signd/config",
    "Include=~/.ssh/signd/config",
    "Include = ~/.ssh/signd/config",
    "  Include\t~/.ssh/signd/config",
    "Include \"~/.ssh/signd/config\"",
    "Include /Users/test/.ssh/signd/config",
    "Include signd/config",
    "Include other/config signd/config",
    "# a comment\n\nInclude signd/config\nHost example.com\n",
])
func aCountedFormIsLeftAlone(_ config: String) {
    #expect(SSHInclude.isPresent(in: config, home: testHome))
    #expect(SSHInclude.adding(to: config, home: testHome) == config)
}

@Test(arguments: [
    "Host example.com\n  Include ~/.ssh/signd/config\n",
    "Host=example.com\n  Include ~/.ssh/signd/config\n",
    "Match all\nInclude ~/.ssh/signd/config\n",
    "Include ~/.ssh/other/config\n",
    "# Include ~/.ssh/signd/config\n",
])
func aLineThatDoesNotCountGetsTheLineAtTheTop(_ config: String) {
    #expect(!SSHInclude.isPresent(in: config, home: testHome))
    #expect(SSHInclude.adding(to: config, home: testHome) == includeLine + "\n\n" + config)
}

@Test func aConfigThatIsASymbolicLinkStaysALinkAndItsTargetIsWritten() throws {
    let directory = try TestDirectory()
    let folder = directory.url.appendingPathComponent(".ssh")
    let dotfiles = directory.url.appendingPathComponent("dotfiles")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
    let target = dotfiles.appendingPathComponent("ssh_config")
    try Data("Host example.com\n".utf8).write(to: target)
    let config = folder.appendingPathComponent("config")
    try FileManager.default.createSymbolicLink(atPath: config.path, withDestinationPath: "../dotfiles/ssh_config")

    #expect(try SSHInclude.enable(home: directory.url))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: config.path) == "../dotfiles/ssh_config")
    #expect(try String(contentsOf: target, encoding: .utf8) == includeLine + "\n\nHost example.com\n")
    #expect(SSHInclude.isEnabled(home: directory.url))
}

@Test(.enabled(if: getuid() != 0))
func aConfigThatCannotBeReadIsNotReplaced() throws {
    let directory = try TestDirectory()
    let folder = directory.url.appendingPathComponent(".ssh")
    let config = folder.appendingPathComponent("config")
    let original = "Host example.com\n  User git\n"
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    #expect(FileManager.default.createFile(atPath: config.path, contents: Data(original.utf8), attributes: [.posixPermissions: 0o000]))
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path) }

    #expect(throws: (any Error).self) { try SSHInclude.enable(home: directory.url) }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
    #expect(try Data(contentsOf: config) == Data(original.utf8))
}
