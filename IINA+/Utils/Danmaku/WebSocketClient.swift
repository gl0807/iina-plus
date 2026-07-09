import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import NIOFoundationCompat

actor WebSocketClient {
    enum Event: Sendable {
        case didOpen
        case message(Data)
        case close(code: Int, reason: String?, wasClean: Bool)
        case error(String)
    }

    enum ClientError: Swift.Error {
        case notConnected
        case invalidURL
        case upgradeFailed
    }

    struct Connection: Sendable {
        let stream: AsyncStream<Event>

        func runStream(onEvent: @escaping @Sendable (Event) async -> Void) -> Task<Void, Never> {
            Task {
                for await event in stream {
                    await onEvent(event)
                }
            }
        }
    }

    private var channel: Channel?
    private var continuation: AsyncStream<Event>.Continuation?
    private var didClose = false

    func connect(url: URL) -> Connection {
        connect(request: URLRequest(url: url))
    }

    func connect(request: URLRequest) -> Connection {
        Connection(stream: open(request))
    }

    private func open(_ request: URLRequest) -> AsyncStream<Event> {
        AsyncStream { [weak self] continuation in
            Task {
                await self?.close()
                await self?.setupConnection(request: request, continuation: continuation)
            }
        }
    }

    func send(data: Data) async throws {
        guard let channel else { throw ClientError.notConnected }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeData(data)
        let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: .random(), data: buffer)
        try await channel.writeAndFlush(frame).get()
    }

    func sendPing() async throws {
        guard let channel else { throw ClientError.notConnected }
        let frame = WebSocketFrame(fin: true, opcode: .ping, maskKey: .random(), data: ByteBuffer())
        try await channel.writeAndFlush(frame).get()
    }

    func close() async {
        didClose = true
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: ByteBuffer())
        try? await channel?.writeAndFlush(frame).get()
        try? await channel?.close().get()
        cleanup()
    }

    // MARK: - Private

    private func setupConnection(
        request: URLRequest,
        continuation: AsyncStream<Event>.Continuation
    ) async {
        didClose = false
        guard let url = request.url else {
            continuation.yield(.error("Invalid URL"))
            continuation.finish()
            return
        }

        self.continuation = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.close() }
        }

        let host = url.host ?? "localhost"
        let port = url.port ?? (url.scheme == "wss" ? 443 : 80)
        let path: String
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let p = components.percentEncodedPath
            if let q = components.percentEncodedQuery, !q.isEmpty {
                path = p + "?" + q
            } else {
                path = p
            }
        } else {
            path = url.path.isEmpty ? "/" : url.path + (url.query.map { "?" + $0 } ?? "")
        }

        do {
            let group = MultiThreadedEventLoopGroup.singleton
            let upgradePromise = group.any().makePromise(of: Void.self)

            let channel: Channel = try await ClientBootstrap(group: group)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
                .channelInitializer { channel in
                    do {
                        if url.scheme == "wss" {
                            let sslContext = try Self.makeSSLContext()
                            try channel.pipeline.syncOperations.addHandler(
                                NIOSSLClientHandler(context: sslContext, serverHostname: host)
                            )
                        }

                        let inbound = InboundHandler(continuation: continuation)

                        var headers = HTTPHeaders()
                        if let reqHeaders = request.allHTTPHeaderFields {
                            for (key, value) in reqHeaders {
                                headers.add(name: key, value: value)
                            }
                        }
                        headers.add(name: "Host", value: host + (port == 443 || port == 80 ? "" : ":\(port)"))

                        let requestHandler = HTTPRequestHandler(
                            uri: path,
                            headers: headers,
                            upgradePromise: upgradePromise
                        )

                        let upgrader = NIOWebSocketClientUpgrader(
                            maxFrameSize: 1 << 20,
                            automaticErrorHandling: true,
                            upgradePipelineHandler: { channel, _ in
                                channel.eventLoop.makeCompletedFuture {
                                    try channel.pipeline.syncOperations.addHandler(inbound)
                                }
                            }
                        )

                        let config: NIOHTTPClientUpgradeConfiguration = (
                            upgraders: [upgrader],
                            completionHandler: { context in
                                context.pipeline.removeHandler(requestHandler).whenComplete { _ in
                                    upgradePromise.succeed(())
                                }
                            }
                        )

                        try channel.pipeline.syncOperations.addHTTPClientHandlers(
                            leftOverBytesStrategy: .forwardBytes,
                            withClientUpgrade: config
                        )

                        try channel.pipeline.syncOperations.addHandler(requestHandler)

                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                .connect(host: host, port: port)
                .get()

            self.channel = channel
            try await upgradePromise.futureResult.get()

            continuation.yield(.didOpen)

            try await channel.closeFuture.get()

            if !didClose {
                continuation.yield(.close(code: 1006, reason: nil, wasClean: false))
                cleanup()
            }
        } catch is CancellationError {
            Log("WebSocketClient cancelled")
            cleanup()
        } catch {
            Log("WebSocketClient error: \(error.localizedDescription)")
            continuation.yield(.error(error.localizedDescription))
            cleanup()
        }
    }

    private static func makeSSLContext() throws -> NIOSSLContext {
        var config = TLSConfiguration.makeClientConfiguration()
        config.certificateVerification = .none
        config.minimumTLSVersion = .tlsv12
        return try NIOSSLContext(configuration: config)
    }

    private func cleanup() {
        channel = nil
        let cont = continuation
        continuation = nil
        cont?.finish()
    }
}

// MARK: - Handlers

private final class InboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame

    private let continuation: AsyncStream<WebSocketClient.Event>.Continuation

    init(continuation: AsyncStream<WebSocketClient.Event>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .binary, .text:
            let data = Data(buffer: frame.unmaskedData)
            continuation.yield(.message(data))
        case .connectionClose:
            var closeData = frame.unmaskedData
            let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: closeData)
            context.writeAndFlush(NIOAny(closeFrame), promise: nil)
            let code: Int = {
                guard let bytes = closeData.readBytes(length: 2), bytes.count == 2 else { return 1005 }
                return Int(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            }()
            continuation.yield(.close(code: code, reason: nil, wasClean: true))
        case .ping:
            var pongData = frame.data
            if let maskingKey = frame.maskKey {
                pongData.webSocketUnmask(maskingKey)
            }
            let pongFrame = WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: pongData)
            context.writeAndFlush(NIOAny(pongFrame), promise: nil)
        case .pong, .continuation:
            break
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.yield(.error(error.localizedDescription))
        context.fireErrorCaught(error)
    }
}

private final class HTTPRequestHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let uri: String
    private let headers: HTTPHeaders
    private let upgradePromise: EventLoopPromise<Void>
    private var requestSent = false

    init(
        uri: String,
        headers: HTTPHeaders,
        upgradePromise: EventLoopPromise<Void>
    ) {
        self.uri = uri
        self.headers = headers
        self.upgradePromise = upgradePromise
    }

    func channelActive(context: ChannelHandlerContext) {
        sendRequest(context: context)
        context.fireChannelActive()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            sendRequest(context: context)
        }
    }

    private func sendRequest(context: ChannelHandlerContext) {
        guard !requestSent else { return }
        requestSent = true

        let requestHead = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: uri,
            headers: headers
        )

        context.write(wrapOutboundOut(.head(requestHead)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        switch response {
        case .head(let head):
            if head.status != .switchingProtocols {
                upgradePromise.fail(WebSocketClient.ClientError.upgradeFailed)
            }
        case .body:
            break
        case .end:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        upgradePromise.fail(error)
        context.close(promise: nil)
    }
}
