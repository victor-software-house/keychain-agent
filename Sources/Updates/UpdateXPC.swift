import Dispatch
import Foundation
import Synchronization
import XPC

/// The one request the updater answers over its cross-process (XPC) service: check now.
public struct UpdateRequest: Codable, Sendable {
    public var isCheckNow = true

    public init() {}
}

/// Waits on a thread of a dispatch queue for a result that a task delivers.
final class Waiter<Value: Sendable>: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let value = Mutex<Value?>(nil)

    func finish(_ result: Value?) {
        value.withLock { $0 = result }
        semaphore.signal()
    }

    /// The result, or nil when none came within `timeout` seconds.
    func wait(timeout: TimeInterval? = nil) -> Value? {
        if let timeout { _ = semaphore.wait(timeout: .now() + timeout) } else { semaphore.wait() }
        return value.withLock { $0 }
    }
}

extension Updater {
    /// The Mach service the updater's launch daemon declares.
    public static let service = "com.victor-software-house.signd.updater"

    /// Starts answering check requests on the Mach service, from any user: a check installs only what the signature check accepts.
    /// The reply comes after the check, so a request waits on its own session's thread.
    public nonisolated func listen() throws -> XPCListener {
        let updater = self
        let listener = try XPCListener(service: Self.service, options: .inactive) { request in
            request.accept { (_: UpdateRequest) -> (any Encodable)? in
                let reply = Waiter<UpdateState>()
                Task { reply.finish(await updater.check()) }
                return reply.wait()
            }
        }
        try listener.activate()
        return listener
    }

    /// Asks the updater to check now and waits up to `timeout` seconds for the result.
    /// It returns nil when no updater answers.
    public static func requestCheck(timeout: TimeInterval = 900) -> UpdateState? {
        guard let session = try? XPCSession(machService: service) else { return nil }
        defer { session.cancel(reason: "the request is answered") }
        let reply = Waiter<UpdateState>()
        do {
            try session.send(UpdateRequest()) { (result: Result<UpdateState, any Error>) in
                reply.finish(try? result.get())
            }
        } catch {
            return nil
        }
        return reply.wait(timeout: timeout)
    }
}
