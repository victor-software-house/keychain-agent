import AgentProtocol
import Darwin
import Foundation
import KeyStore
import NIOCore
import NIOFoundationCompat
import NIOPosix
import os
import SSHWire
import Sync

/// signd's own extensions, for its command line.
public enum PrivateExtension {
    public static let status = "signd-status@victor-software-house.com"
    public static let reload = "signd-reload@victor-software-house.com"
    /// Runs a check of 1Password now and answers with its `CheckSummary` as JSON.
    public static let sync = "signd-sync@victor-software-house.com"
}

/// Splits the byte stream into message bodies by their 4-byte length.
struct FrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    struct TooLong: Error {}

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) else { return .needMoreData }
        guard length <= Frame.maximumLength else { throw TooLong() }
        guard buffer.readableBytes >= 4 + Int(length) else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 4)
        context.fireChannelRead(wrapInboundOut(buffer.readSlice(length: Int(length))!))
        return .continue
    }
}

/// Serves the agent on a Unix socket.
public struct Server: Sendable {
    let agent: Agent
    let sync: SyncService?
    let pool: NIOThreadPool

    public init(agent: Agent, sync: SyncService? = nil) {
        self.agent = agent
        self.sync = sync
        pool = .singleton
    }

    struct OtherUser: Error {}

    /// Listens on `path` until the task is cancelled.
    public func run(socketPath path: String) async throws {
        await agent.reload()
        await sync?.start()
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true) { channel in
                Self.accept(channel)
            }
        chmod(path, 0o600)
        log.notice("serving \(path, privacy: .public)")
        try await withThrowingDiscardingTaskGroup { group in
            group.addTask { try await sweep() }
            try await server.executeThenClose { inbound in
                for try await connection in inbound {
                    group.addTask { await serve(connection) }
                }
            }
        }
    }

    /// Accepts a connection only from a process of this user.
    private static func accept(_ channel: any Channel) -> EventLoopFuture<NIOAsyncChannel<ByteBuffer, ByteBuffer>> {
        guard let provider = channel as? any SocketOptionProvider else {
            return channel.eventLoop.makeFailedFuture(OtherUser())
        }
        let credentials: EventLoopFuture<xucred> = provider.unsafeGetSocketOption(level: SOL_LOCAL, name: LOCAL_PEERCRED)
        return credentials.flatMapThrowing { credentials in
            guard credentials.cr_uid == getuid() else {
                log.error("refused a connection from uid \(credentials.cr_uid)")
                throw OtherUser()
            }
            try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(FrameDecoder()))
            return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
        }
    }

    private func serve(_ connection: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async {
        do {
            try await connection.executeThenClose { inbound, outbound in
                for try await frame in inbound {
                    let body = await respond(to: Request(body: Data(buffer: frame))).body
                    var reply = ByteBuffer()
                    reply.writeInteger(UInt32(body.count))
                    reply.writeBytes(body)
                    try await outbound.write(reply)
                }
            }
        } catch {
            log.debug("connection closed: \(String(describing: error), privacy: .public)")
        }
    }

    func respond(to request: Request) async -> Response {
        switch request {
        case .identities:
            sync?.noteRequest()
            return .identities(await agent.identities())
        case let .sign(blob, data, flags):
            sync?.noteRequest()
            guard let signer = await agent.signer(for: blob) else { return .failure }
            do {
                // Signing runs on the thread pool, so a slow Secure Enclave call holds no event loop or actor.
                return .signature(try await pool.runIfActive { try signer.sign(data, flags: flags) })
            } catch {
                log.error("signing failed: \(String(describing: error), privacy: .public)")
                return .failure
            }
        case let .add(key, comment, constraints):
            return await agent.add(key, comment: comment, constraints: constraints)
        case let .remove(blob):
            return await agent.remove(blob: blob)
        case .removeAll:
            return await agent.removeAll()
        case let .extension(name, _):
            return await respond(toExtension: name)
        case .unsupported, .malformed:
            return .failure
        }
    }

    private func respond(toExtension name: String) async -> Response {
        switch name {
        case Extension.query:
            return .query
        case Extension.sessionBind:
            await agent.recordSessionBind()
            return .success
        case PrivateExtension.reload:
            await agent.reload()
            await sync?.reconfigure()
            return .success
        case PrivateExtension.sync:
            guard let sync else { return .failure }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            guard let json = try? encoder.encode(await sync.checkNow()) else { return .failure }
            var contents = Data()
            contents.appendString(json)
            return .extensionResponse(name: name, contents: contents)
        case PrivateExtension.status:
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            guard let json = try? encoder.encode(await agent.status()) else { return .failure }
            var contents = Data()
            contents.appendString(json)
            return .extensionResponse(name: name, contents: contents)
        default:
            return .failure
        }
    }

    /// Drops expired keys at an interval set by the key lifetime: half of it, from 1 to 60 seconds.
    private func sweep() async throws {
        while true {
            let interval = min(60, max(1, await agent.lifetimeSeconds() / 2))
            try await Task.sleep(for: .seconds(interval))
            await agent.dropExpired(now: Date())
        }
    }
}

extension Agent {
    func lifetimeSeconds() -> TimeInterval { lifetime() }
}
