import Foundation
import Synchronization
import Testing
@testable import Updates

// MARK: Support

/// A property list that does not exist, for settings that read no file.
let noPlist = URL(filePath: "/nonexistent/signd.plist")

/// A new temporary directory with its symbolic links resolved, since staging refuses a path through one.
func temporaryDirectory() throws -> URL {
    let base = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory).resolvingSymlinksInPath()
    let directory = base.appending(path: "signd-updates-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

func writePlist(_ values: [String: Any], to url: URL) throws {
    try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: url)
}

/// An app bundle with a version and a marker file in its `Contents`.
private func makeApp(in directory: URL, version: String, marker: String) throws -> AppBundle {
    let app = directory.appending(path: "Signd.app", directoryHint: .isDirectory)
    let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    try writePlist(["CFBundleShortVersionString": version], to: contents.appending(path: "Info.plist"))
    try Data(marker.utf8).write(to: contents.appending(path: "marker.txt"))
    return AppBundle(url: app)
}

private func marker(of app: AppBundle) throws -> String {
    String(decoding: try Data(contentsOf: app.url.appending(path: "Contents/marker.txt")), as: UTF8.self)
}

private func launch(_ path: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(filePath: path)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

/// Counts the checks and launches a test makes, and returns the new count.
private final class RunCount: Sendable {
    private let value = Mutex(0)

    @discardableResult
    func increment() -> Int { value.withLock { $0 += 1; return $0 } }

    var count: Int { value.withLock { $0 } }
}

/// Keeps a task waiting until a test opens it.
private actor Gate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

/// A release feed that answers with one release and records each request.
private final class FakeFeed: Sendable {
    private let urls = Mutex<[URL]>([])

    var requests: [URL] { urls.withLock { $0 } }

    func feed(tag: String) -> ReleaseFeed {
        ReleaseFeed { request in
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badURL)
            }
            self.urls.withLock { $0.append(url) }
            let json = #"{"tag_name":"\#(tag)","assets":[{"name":"Signd.app.zip","browser_download_url":"https://example.invalid/Signd.app.zip"}]}"#
            return (Data(json.utf8), response)
        }
    }
}

private func state(at time: Date, outcome: UpdateState.Outcome) -> UpdateState {
    var state = UpdateState()
    state.lastCheck = time
    state.outcome = outcome
    return state
}

// MARK: Settings

@Test func managedSettingsBeatMachineSettings() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let managed = directory.appending(path: "managed.plist")
    let machine = directory.appending(path: "machine.plist")
    try writePlist(["updates": false, "update-interval": "12h"], to: managed)
    try writePlist(["updates": true, "update-interval": "2d"], to: machine)
    let settings = UpdateSettings(managed: managed, machine: machine)
    #expect(!settings.isEnabled)
    #expect(settings.enabledSource == .managed)
    #expect(settings.interval == "12h")
    #expect(settings.intervalSeconds == 43_200)
    #expect(settings.intervalSource == .managed)
}

@Test func machineSettingsApplyBelowTheManagedOnes() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let managed = directory.appending(path: "managed.plist")
    let machine = directory.appending(path: "machine.plist")
    try writePlist(["updates": false], to: managed)
    try writePlist(["update-interval": "2d"], to: machine)
    let settings = UpdateSettings(managed: managed, machine: machine)
    #expect(!settings.isEnabled)
    #expect(settings.enabledSource == .managed)
    #expect(settings.interval == "2d")
    #expect(settings.intervalSeconds == 172_800)
    #expect(settings.intervalSource == .machine)
}

@Test func noPreferencesGiveTheDefaults() {
    let settings = UpdateSettings(managed: noPlist, machine: noPlist)
    #expect(settings.isEnabled)
    #expect(settings.enabledSource == .default)
    #expect(settings.interval == "6h")
    #expect(settings.intervalSeconds == 21_600)
    #expect(settings.intervalSource == .default)
}

@Test(arguments: ["30m", "31d", "soon", "-6h", "6", "inf"])
func anIntervalOutOfRangeIsPassedOver(text: String) throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let managed = directory.appending(path: "managed.plist")
    let machine = directory.appending(path: "machine.plist")
    try writePlist(["update-interval": text], to: managed)
    try writePlist(["update-interval": "1d"], to: machine)
    let settings = UpdateSettings(managed: managed, machine: machine)
    #expect(settings.interval == "1d")
    #expect(settings.intervalSource == .machine)
}

@Test func aUsersPreferencesAreNotRead() throws {
    let domain = UpdateSettings.domain as CFString
    CFPreferencesSetAppValue("updates" as CFString, NSNumber(value: false), domain)
    CFPreferencesSetAppValue("update-interval" as CFString, "2d" as CFString, domain)
    CFPreferencesAppSynchronize(domain)
    defer {
        CFPreferencesSetAppValue("updates" as CFString, nil, domain)
        CFPreferencesSetAppValue("update-interval" as CFString, nil, domain)
        CFPreferencesAppSynchronize(domain)
    }
    try #require(CFPreferencesCopyAppValue("updates" as CFString, domain) as? Bool == false)
    let settings = UpdateSettings(managed: noPlist, machine: noPlist)
    #expect(settings.isEnabled)
    #expect(settings.interval == "6h")
    #expect(settings.intervalSource == .default)
}

// MARK: Schedule

@Test func aRunIsDueOnceTheIntervalHasPassed() {
    let schedule = UpdateSchedule(now: { at(0) }, random: { 0 })
    #expect(schedule.isDue(lastCheck: nil, interval: 21_600))
    #expect(!schedule.isDue(lastCheck: at(-3 * 3600), interval: 21_600))
    #expect(!schedule.isDue(lastCheck: at(-21_599), interval: 21_600))
    #expect(schedule.isDue(lastCheck: at(-21_600), interval: 21_600))
    #expect(schedule.isDue(lastCheck: at(-86_400), interval: 21_600))
}

@Test func theScheduleFollowsTheClock() {
    let clock = TestClock()
    let schedule = UpdateSchedule(now: { clock.now }, random: { 0 })
    #expect(!schedule.isDue(lastCheck: at(0), interval: 3600))
    clock.advance(3600)
    #expect(schedule.isDue(lastCheck: at(0), interval: 3600))
}

@Test func theDelayIsAtMostTenMinutes() {
    #expect(UpdateSchedule(random: { 0 }).delay() == 0)
    #expect(UpdateSchedule(random: { 0.5 }).delay() == 300)
    #expect(UpdateSchedule(random: { 0.999 }).delay() < 600)
}

// MARK: Versions

@Test(arguments: [
    ("v0.0.14", "0.0.13", true),
    ("v0.0.13", "0.0.13", false),
    ("v0.0.12", "0.0.13", false),
    ("v0.1.0", "0.0.13", true),
    ("v0.0.10", "0.0.9", true),
    ("v1.0", "0.9.9", true),
    ("v0.0.13.1", "0.0.13", true),
    ("v1.0.0", "1.0", false),
    ("0.0.14", "0.0.13", true),
    ("nightly", "0.0.13", false),
    ("v0.0.14-rc1", "0.0.13", false),
    ("v0.0.14", "dev", false),
    ("v0.0.14", "", false),
    ("v", "0.0.13", false),
    ("v0..14", "0.0.13", false),
])
func aTagIsNewerNumberByNumber(tag: String, installed: String, isNewer: Bool) {
    #expect(Release(tag: tag, assetURL: URL(filePath: "/Signd.app.zip")).isNewer(than: installed) == isNewer)
}

@Test func theVersionIsTheTagWithoutItsV() {
    #expect(Release(tag: "v0.0.14", assetURL: URL(filePath: "/Signd.app.zip")).version == "0.0.14")
    #expect(Release(tag: "0.0.14", assetURL: URL(filePath: "/Signd.app.zip")).version == "0.0.14")
}

// MARK: The updater

@Test func aCheckDuringARunGetsThatRunsResult() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = Gate()
    let runs = RunCount()
    let updater = Updater(
        run: {
            runs.increment()
            await gate.wait()
            var result = state(at: at(0), outcome: .installed)
            result.latest = "0.0.14"
            return result
        },
        now: { at(0) }, stateURL: directory.appending(path: "update.json")
    )
    let first = Task { await updater.check() }
    let second = Task { await updater.check() }
    await gate.open()
    let results = await (first.value, second.value)
    #expect(results.0 == results.1)
    #expect(results.0.outcome == .installed)
    #expect(results.0.latest == "0.0.14")
    #expect(runs.count == 1)
}

@Test func aCheckWithinFiveMinutesGetsTheRecordedResult() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = TestClock()
    let runs = RunCount()
    let url = directory.appending(path: "update.json")
    let updater = Updater(run: { state(at: clock.now, outcome: runs.increment() == 1 ? .installed : .upToDate) }, now: { clock.now }, stateURL: url)
    #expect(await updater.check().outcome == .installed)
    clock.advance(299)
    #expect(await updater.check().outcome == .installed)
    #expect(runs.count == 1)
    clock.advance(2)
    #expect(await updater.check().outcome == .upToDate)
    #expect(runs.count == 2)
    #expect(UpdateState.load(from: url).outcome == .upToDate)
}

@Test func anOffResultDoesNotAnswerTheNextRequest() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = TestClock()
    let runs = RunCount()
    let updater = Updater(
        run: { state(at: clock.now, outcome: runs.increment() == 1 ? .off : .upToDate) }, now: { clock.now },
        stateURL: directory.appending(path: "update.json")
    )
    #expect(await updater.check().outcome == .off)
    clock.advance(1)
    #expect(await updater.check().outcome == .upToDate)
    #expect(runs.count == 2)
}

@Test func aShutdownFailsWhileACheckRunsAndRefusesLaterChecks() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = Gate()
    let runs = RunCount()
    let updater = Updater(
        run: {
            runs.increment()
            await gate.wait()
            return state(at: at(0), outcome: .upToDate)
        },
        now: { at(0) }, stateURL: directory.appending(path: "update.json")
    )
    let first = Task { await updater.check() }
    while runs.count == 0 { await Task.yield() }
    #expect(await updater.shutdown(idleFor: 0) == false)
    await gate.open()
    #expect(await first.value.outcome == .upToDate)
    #expect(await updater.shutdown(idleFor: 0))
    let refused = await updater.check()
    #expect(refused.outcome == .failed)
    #expect(refused.error != nil)
    #expect(runs.count == 1)
}

@Test func aMissingStateFileLoadsEmpty() {
    #expect(UpdateState.load(from: noPlist) == UpdateState())
}

@Test func aCheckWithUpdatesOffMakesNoRequest() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let machine = directory.appending(path: "machine.plist")
    try writePlist(["updates": false], to: machine)
    let feed = FakeFeed()
    let run = UpdateRun(UpdateRun.Dependencies(settings: { UpdateSettings(managed: noPlist, machine: machine) }, feed: feed.feed(tag: "v0.0.14"), now: { at(0) }))
    let result = await run.perform()
    #expect(result.outcome == .off)
    #expect(result.lastCheck == at(0))
    #expect(feed.requests.isEmpty)
}

@Test func theInstalledVersionIsUpToDate() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = try makeApp(in: directory, version: "0.0.13", marker: "installed")
    let feed = FakeFeed()
    let run = UpdateRun(
        UpdateRun.Dependencies(settings: { UpdateSettings(managed: noPlist, machine: noPlist) }, feed: feed.feed(tag: "v0.0.13"), app: app.url)
    )
    let result = await run.perform()
    #expect(result.outcome == .upToDate)
    #expect(result.installed == "0.0.13")
    #expect(result.latest == "0.0.13")
    #expect(result.error == nil)
    #expect(feed.requests == [ReleaseFeed.latestURL])
}

@Test func anUpdaterWithNoTeamRefusesToUpdate() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = try makeApp(in: directory, version: "0.0.13", marker: "installed")
    let feed = FakeFeed()
    let run = UpdateRun(
        UpdateRun.Dependencies(
            settings: { UpdateSettings(managed: noPlist, machine: noPlist) }, feed: feed.feed(tag: "v0.0.14"), app: app.url,
            team: { throw UpdateError("the updater has no team") }
        )
    )
    let result = await run.perform()
    #expect(result.outcome == .failed)
    #expect(result.error == "the updater has no team")
    #expect(result.latest == "0.0.14")
    #expect(try marker(of: app) == "installed")
    #expect(feed.requests == [ReleaseFeed.latestURL])
}

// MARK: Download

private func response(for url: URL) throws -> HTTPURLResponse {
    try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
}

@Test func aDownloadMovesTheZipIntoTheDirectory() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let asset = URL(filePath: "/Signd.app.zip")
    let downloaded = directory.appending(path: "download.tmp")
    try Data("zip".utf8).write(to: downloaded)
    let requests = RunCount()
    let feed = ReleaseFeed(downloader: { request in
        requests.increment()
        return (downloaded, try response(for: request.url ?? asset))
    })
    let zip = try await feed.download(Release(tag: "v0.0.14", assetURL: asset, assetSize: 3), to: directory)
    #expect(zip.lastPathComponent == "Signd.app.zip")
    #expect(try Data(contentsOf: zip) == Data("zip".utf8))
    #expect(requests.count == 1)
}

@Test func aDownloadOverTheLimitIsRefusedByTheReportedSize() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let requests = RunCount()
    let feed = ReleaseFeed(downloader: { _ in
        requests.increment()
        throw URLError(.badServerResponse)
    })
    let release = Release(tag: "v0.0.14", assetURL: URL(filePath: "/Signd.app.zip"), assetSize: ReleaseFeed.maximumAssetSize + 1)
    await #expect(throws: UpdateError.self) { try await feed.download(release, to: directory) }
    #expect(requests.count == 0)
}

@Test func aDownloadOverTheLimitIsRefusedByTheFileSize() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let asset = URL(filePath: "/Signd.app.zip")
    let downloaded = directory.appending(path: "download.tmp")
    try Data().write(to: downloaded)
    let handle = try FileHandle(forWritingTo: downloaded)
    try handle.truncate(atOffset: UInt64(ReleaseFeed.maximumAssetSize + 1))
    try handle.close()
    let feed = ReleaseFeed(downloader: { request in (downloaded, try response(for: request.url ?? asset)) })
    // The feed reported a small size, so only the file's own size can refuse it.
    await #expect(throws: UpdateError.self) { try await feed.download(Release(tag: "v0.0.14", assetURL: asset, assetSize: 3), to: directory) }
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "Signd.app.zip").path))
}

// MARK: Staging

@Test func stagingMakesAFreshPrivateDirectoryEachTime() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "signd/update", directoryHint: .isDirectory)
    let staging = Staging(root: root, owner: getuid())
    let first = try staging.makeDirectory()
    let second = try staging.makeDirectory()
    #expect(first != second)
    #expect(first.deletingLastPathComponent().path == root.path)
    #expect(second.deletingLastPathComponent().path == root.path)
    let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
    #expect(attributes[.posixPermissions] as? Int == 0o700)
}

@Test func stagingRefusesASymbolicLink() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let real = directory.appending(path: "real", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
    let link = directory.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let staging = Staging(root: link.appending(path: "update", directoryHint: .isDirectory), owner: getuid())
    #expect(throws: UpdateError.self) { try staging.makeDirectory() }
    #expect(!FileManager.default.fileExists(atPath: real.appending(path: "update").path))
}

@Test(.enabled(if: getuid() != 0))
func stagingRefusesAComponentThatTheExpectedOwnerDoesNotOwn() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let staging = Staging(root: directory.appending(path: "update", directoryHint: .isDirectory), owner: getuid() + 1)
    #expect(throws: UpdateError.self) { try staging.makeDirectory() }
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "update").path))
}

@Test func sealingFixesAFileWritableByOthers() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = try makeApp(in: directory, version: "0.0.14", marker: "new")
    let writable = app.url.appending(path: "Contents/marker.txt")
    let setuid = app.url.appending(path: "Contents/Info.plist")
    #expect(chmod(writable.path, 0o666) == 0)
    #expect(chmod(setuid.path, 0o4777) == 0)
    let staging = Staging(root: directory.appending(path: "update", directoryHint: .isDirectory), owner: getuid(), group: getgid())
    #expect(throws: UpdateError.self) { try staging.check(app.url) }
    try staging.seal(app.url)
    try staging.check(app.url)
    #expect(try FileManager.default.attributesOfItem(atPath: writable.path)[.posixPermissions] as? Int == 0o644)
    #expect(try FileManager.default.attributesOfItem(atPath: setuid.path)[.posixPermissions] as? Int == 0o755)
}

@Test(.enabled(if: getuid() != 0))
func aStagedFileOfAnotherOwnerIsRefused() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = try makeApp(in: directory, version: "0.0.14", marker: "new")
    let staging = Staging(root: directory.appending(path: "update", directoryHint: .isDirectory), owner: getuid() + 1, group: getgid())
    #expect(throws: UpdateError.self) { try staging.check(app.url) }
}

// MARK: Swap

@Test func theSwapInstallsTheNewContentsAndDeletesTheOldOnes() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let installed = try makeApp(in: directory.appending(path: "installed", directoryHint: .isDirectory), version: "0.0.13", marker: "old")
    let new = try makeApp(in: directory.appending(path: "new", directoryHint: .isDirectory), version: "0.0.14", marker: "new")
    try installed.swapContents(with: new)
    #expect(installed.version == "0.0.14")
    #expect(try marker(of: installed) == "new")
    #expect(!FileManager.default.fileExists(atPath: new.url.appending(path: "Contents").path))
}

@Test func aFailedSwapLeavesTheInstalledAppWhole() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let installed = try makeApp(in: directory.appending(path: "installed", directoryHint: .isDirectory), version: "0.0.13", marker: "old")
    let empty = directory.appending(path: "empty/Signd.app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    #expect(throws: UpdateError.self) { try installed.swapContents(with: AppBundle(url: empty)) }
    #expect(installed.version == "0.0.13")
    #expect(try marker(of: installed) == "old")
}

// MARK: Verification

private let calculator = URL(filePath: "/System/Applications/Calculator.app", directoryHint: .isDirectory)

@Test func anAppOfAnotherTeamAndIdentifierIsRejected() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let copy = directory.appending(path: "Calculator.app", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: calculator, to: copy)
    #expect(throws: UpdateError.self) { try AppBundle(url: copy).verify(team: "ABCDE12345") }
}

@Test func anUnnotarizedAppIsRejected() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let copy = directory.appending(path: "Calculator.app", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: calculator, to: copy)
    try #require(try launch("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", AppBundle.identifier, copy.path]) == 0)
    #expect(throws: UpdateError.self) { try AppBundle(url: copy).verify(team: "ABCDE12345") }
}

@Test func anAppWhoseVersionIsNotTheTagIsRejected() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = try makeApp(in: directory, version: "0.0.12", marker: "new")
    #expect(throws: UpdateError.self) { try app.requireVersion("0.0.14") }
    try app.requireVersion("0.0.12")
}

// MARK: Restart

@Test func theRestartFindsEachUsersAgentOnce() throws {
    let executable = "/Applications/Signd.app/Contents/MacOS/signd"
    let agents = AgentRestart(
        processes: {
            [
                RunningProcess(path: executable, arguments: ["signd", "serve"], uid: 502),
                RunningProcess(path: executable, arguments: ["signd", "serve"], uid: 501),
                RunningProcess(path: executable, arguments: ["signd", "serve"], uid: 502),
                RunningProcess(path: executable, arguments: ["signd", "status"], uid: 503),
                RunningProcess(path: "/opt/other/signd", arguments: ["signd", "serve"], uid: 504),
            ]
        },
        kickstart: { _ in }
    )
    #expect(agents.users(running: executable) == [501, 502])
}

@Test func aFailedRestartDoesNotStopTheOthers() throws {
    let launched = RunCount()
    let agents = AgentRestart(
        processes: { [] },
        kickstart: { uid in
            launched.increment()
            if uid == 501 { throw UpdateError("no job") }
        }
    )
    #expect(throws: UpdateError.self) { try agents.restart([501, 502]) }
    #expect(launched.count == 2)
}
