//
//  NIOHTTPServer.swift
//  IINA+
//
//  Created by xjbeta on 2024/11/25.
//  Copyright © 2024 xjbeta. All rights reserved.
//


import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket

enum UpgradeResult {
    case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
    case notUpgraded(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
}

final class HTTPByteBufferResponsePartHandler: ChannelOutboundHandler {
    typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = Self.unwrapOutboundIn(data)
        switch part {
        case .head(let head):
            context.write(Self.wrapOutboundOut(.head(head)), promise: promise)
        case .body(let buffer):
            context.write(Self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
        case .end(let trailers):
            context.write(Self.wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }
}

actor NIOHTTPServer {
    private var serverChannel: Channel?
    private let group = MultiThreadedEventLoopGroup.singleton

    func start() async {
        do {
            try await setupServer()
        } catch {
            Log("NIOHTTPServer start failed: \(error)")
        }
    }

    func stop() {
        Log("NIOHTTPServer stopping")
        serverChannel?.close(mode: .all, promise: nil)
        serverChannel = nil
    }

    private func setupServer() async throws {
        let manager = await MainActor.run { DanmakuSessionManager() }

        let channel: NIOAsyncChannel<EventLoopFuture<UpgradeResult>, Never> = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: Preferences.shared.dmPort) { channel in
                channel.eventLoop.makeCompletedFuture {
                    let upgrader = NIOTypedWebSocketServerUpgrader<UpgradeResult>(
                        shouldUpgrade: { channel, head in
                            channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                        },
                        upgradePipelineHandler: { channel, _ in
                            channel.eventLoop.makeCompletedFuture {
                                let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
                                    wrappingChannelSynchronously: channel
                                )
                                return UpgradeResult.websocket(asyncChannel)
                            }
                        }
                    )

                    let config = NIOTypedHTTPServerUpgradeConfiguration(
                        upgraders: [upgrader],
                        notUpgradingCompletionHandler: { channel in
                            channel.eventLoop.makeCompletedFuture {
                                try channel.pipeline.syncOperations.addHandler(HTTPByteBufferResponsePartHandler())
                                let asyncChannel = try NIOAsyncChannel<
                                    HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>
                                >(wrappingChannelSynchronously: channel)
                                return UpgradeResult.notUpgraded(asyncChannel)
                            }
                        }
                    )

                    return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                        configuration: .init(upgradeConfiguration: config)
                    )
                }
            }

        self.serverChannel = channel.channel

        guard let localAddress = channel.channel.localAddress else {
            Log("NIOHTTPServer address was unable to bind")
            return
        }
        Log("NIOHTTPServer started on \(localAddress)")

        try await channel.executeThenClose { inbound, _ in
            for try await upgradeResult in inbound {
                Task {
                    await self.handleConnection(upgradeResult, manager: manager)
                }
            }
        }

        Log("NIOHTTPServer closed")
    }

    private func handleConnection(
        _ upgradeResult: EventLoopFuture<UpgradeResult>,
        manager: DanmakuSessionManager
    ) async {
        do {
            switch try await upgradeResult.get() {
            case .websocket(let wsChannel):
                Log("NIOHTTPServer accepting websocket connection")
                let session = WebSocketSession(asyncChannel: wsChannel, manager: manager)
                await session.handle()
            case .notUpgraded(let httpChannel):
                Log("NIOHTTPServer accepting http connection")
                try await HTTPHandler.handleChannel(httpChannel)
            }
        } catch {
            Log("NIOHTTPServer connection error: \(error)")
        }
    }
}
