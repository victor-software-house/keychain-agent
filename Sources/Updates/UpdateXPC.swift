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

/// Counts the requests the XPC handler has accepted and not yet answered.
/// The daemon exits inside the lock that guards the count, so a handler that arrives later waits on the lock and never starts work.
public final class InFlight: Sendable {
    private let count = Mutex(0)

    public init() {}

    public func begin() { count.withLock { $0 += 1 } }

    public func end() { count.withLock { $0 -= 1 } }

    /// Calls `terminate` while holding the lock when no request is in flight, and returns whether it did.
    public func exitIfNoneInFlight(_ terminate: () -> Void) -> Bool {
        count.withLock { count in
            guard count == 0 else { return false }
            terminate()
            return true
        }
    }
}

extension Updater {
    /// The Mach service the updater's launch daemon declares.
    public static let service = "com.victor-software-house.signd.updater"

    /// Starts answering check requests on the Mach service, from any user: a check installs only what the signature check accepts.
    /// The reply comes after the check, so a request waits on its own session's thread.
    /// `inFlight` counts each request from the moment the handler starts until its result is ready.
    public nonisolated func listen(counting inFlight: InFlight) throws -> XPCListener {
        let updater = self
        let listener = try XPCListener(service: Self.service, options: .inactive) { request in
            request.accept { (_: UpdateRequest) -> (any Encodable)? in
                inFlight.begin()
                let reply = Waiter<UpdateState>()
                Task { reply.finish(await updater.check()) }
                let result = reply.wait()
                inFlight.end()
                return result
            }
        }
        try listener.activate()
        return listener
    }

    /// How long `signd update` waits for the result of a check.
    public static let checkTimeout: TimeInterval = 900

    /// How a request for a check ended.
    public enum CheckReply: Sendable, Equatable {
        case answered(UpdateState)
        /// The connection stayed up and no result came within the timeout.
        case timedOut
        /// No updater took the request, or the connection broke again on the second try.
        case unreachable
    }

    /// Asks the updater to check now and waits up to `timeout` seconds for the result.
    /// A connection that breaks before a reply is tried once more, since launchd starts a new daemon for the second message.
    public static func requestCheck(timeout: TimeInterval = checkTimeout) -> CheckReply {
        for _ in 0..<2 {
            switch ask(timeout: timeout) {
            case let .answered(state): return .answered(state)
            case .interrupted: continue
            case .unanswered: return .unreachable
            case .timedOut: return .timedOut
            }
        }
        return .unreachable
    }

    private enum Answer {
        case answered(UpdateState)
        /// The connection broke before a reply, so asking again may reach a new daemon.
        case interrupted
        case unanswered
        case timedOut
    }

    private static func ask(timeout: TimeInterval) -> Answer {
        guard let session = try? XPCSession(machService: service) else { return .unanswered }
        defer { session.cancel(reason: "the request is answered") }
        let reply = Waiter<Result<UpdateState, any Error>>()
        do {
            try session.send(UpdateRequest()) { (result: Result<UpdateState, any Error>) in reply.finish(result) }
        } catch {
            return .interrupted
        }
        switch reply.wait(timeout: timeout) {
        case let .success(state)?: return .answered(state)
        case let .failure(error)?: return error is XPCRichError ? .interrupted : .unanswered
        case nil: return .timedOut
        }
    }
}
