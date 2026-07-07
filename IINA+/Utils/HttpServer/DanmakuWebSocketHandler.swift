//
//  WebSocketDanmakuHandler.swift
//  IINA+
//
//  Created by xjbeta on 2024/11/25.
//  Copyright © 2024 xjbeta. All rights reserved.
//

import Foundation
import NIO
import NIOWebSocket

actor WebSocketSession {
    private let asyncChannel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>
    private var outboundWriter: NIOAsyncChannelOutboundWriter<WebSocketFrame>?
    private var awaitingClose = false
    let contextName: String
    private let manager: DanmakuSessionManager

    init(
        asyncChannel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>,
        manager: DanmakuSessionManager
    ) {
        self.asyncChannel = asyncChannel
        self.contextName = UUID().uuidString
        self.manager = manager
    }

    func handle() async {
        Log("Websocket client connected. \(contextName)")
        await manager.sessionStarted(self)

        do {
            try await asyncChannel.executeThenClose { inbound, outbound in
                self.outboundWriter = outbound

                for try await frame in inbound {
                    switch frame.opcode {
                    case .connectionClose:
                        await self.receivedClose(frame: frame)
                        return
                    case .ping:
                        try await self.pong(frame: frame)
                    case .text:
                        var data = frame.unmaskedData
                        let text = data.readString(length: data.readableBytes) ?? ""
                        await manager.textReceived(text, contextName: self.contextName)
                    case .binary, .continuation, .pong:
                        break
                    default:
                        await self.closeOnError()
                    }
                }
            }
        } catch is CancellationError {
        } catch {
            Log("WebSocket session error: \(error)")
        }

        await manager.sessionEnded(self)
        Log("Websocket client disconnected.")
    }

    func writeText(_ string: String) async {
        guard !awaitingClose else { return }
        var buffer = ByteBufferAllocator().buffer(capacity: string.utf8.count)
        buffer.writeString(string)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        try? await outboundWriter?.write(frame)
    }

    // MARK: - Private

    private func receivedClose(frame: WebSocketFrame) async {
        if awaitingClose {
            return
        }
        var data = frame.unmaskedData
        let closeDataCode = data.readSlice(length: 2) ?? ByteBuffer()
        let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeDataCode)
        try? await outboundWriter?.write(closeFrame)
    }

    private func pong(frame: WebSocketFrame) async throws {
        var frameData = frame.data
        if let maskingKey = frame.maskKey {
            frameData.webSocketUnmask(maskingKey)
        }
        let responseFrame = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
        try await outboundWriter?.write(responseFrame)
    }

    private func closeOnError() async {
        var data = ByteBufferAllocator().buffer(capacity: 2)
        data.write(webSocketErrorCode: .protocolError)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
        try? await outboundWriter?.write(frame)
        awaitingClose = true
    }
}

@MainActor
final class DanmakuSessionManager: DanmakuDelegate, DanmakuWSDelegate {
    private var connectedItems = [DanmakuWS]()
    private var danmakus = [Danmaku]()
    private var sessions: [String: WebSocketSession] = [:]

    // MARK: - Session lifecycle

    func sessionStarted(_ session: WebSocketSession) {
        sessions[session.contextName] = session
    }

    func sessionEnded(_ session: WebSocketSession) {
        let contextName = session.contextName
        sessions.removeValue(forKey: contextName)
        connectedItems.removeAll { $0.contextName == contextName }
        let activeURLs = Set(connectedItems.map { $0.url })
        danmakus.removeAll { dm in
            let remove = !activeURLs.contains(dm.url)
            if remove {
                dm.stop()
            }
            return remove
        }
    }

    // MARK: - Text handling

    func textReceived(_ text: String, contextName: String) {
        var clickType: IINAUrlType = .none

        var ws: DanmakuWS? = {
            if text.starts(with: "iinaDM://") {
                clickType = .plugin
                var v = 0
                var u = String(text.dropFirst("iinaDM://".count))

                if u.starts(with: "v=") {
                    let vu = u.split(separator: "&", maxSplits: 1)
                    guard vu.count == 2 else { return nil }
                    v = Int(vu[0].dropFirst(2)) ?? 0
                    u = String(vu[1])
                }

                var re = DanmakuWS(id: u,
                                   site: .init(url: u),
                                   url: u,
                                   contextName: contextName)
                re.version = v
                return re
            } else if text.starts(with: "iinaWebDM://") {
                let hex = String(text.dropFirst("iinaWebDM://".count))
                clickType = .danmaku
                guard let ids = String(data: Data(hex: hex), encoding: .utf8)?.split(separator: "👻").map(String.init),
                      ids.count == 2 else { return nil }
                let u = ids[1]

                var re = DanmakuWS(id: ids[0],
                                   site: .init(url: u),
                                   url: u,
                                   contextName: contextName)
                re.version = 1
                return re
            } else {
                return nil
            }
        }()

        guard var ws else { return }

        ws.delegate = self
        ws.loadCustomFont()
        ws.customDMSpeed()
        ws.customDMOpdacity()

        switch clickType {
        case .danmaku:
            if [.bilibili, .bangumi, .b23].contains(ws.site) {
                ws.loadFilters()
                ws.loadXMLDM()
            } else if ws.site != .unsupported {
                loadNewDanmaku(ws)
                guard !connectedItems.contains(where: { $0.contextName == ws.contextName && $0.url == ws.url }) else { return }
                connectedItems.append(ws)
            }
        case .plugin where ![.unsupported, .bangumi, .bilibili, .b23].contains(ws.site):
            loadNewDanmaku(ws)
            guard !connectedItems.contains(where: { $0.contextName == ws.contextName && $0.url == ws.url }) else { return }
            connectedItems.append(ws)
        default:
            break
        }
    }

    // MARK: - DanmakuDelegate

    func send(_ event: DanmakuEvent, sender: Danmaku) {
        connectedItems.filter { $0.url == sender.url }.forEach {
            $0.send(event)
        }
    }

    // MARK: - DanmakuWSDelegate

    func writeDanmakuEventText(contextName: String, _ string: String) {
        guard let session = sessions[contextName] else { return }
        Task {
            await session.writeText(string)
        }
    }

    // MARK: - Private

    private func loadNewDanmaku(_ ws: DanmakuWS) {
        guard !danmakus.contains(where: { $0.url == ws.url }) else { return }
        let d = Danmaku(ws.url)
        d.id = ws.url
        d.delegate = self
        danmakus.append(d)
        Task { await d.loadDM() }
    }
}
