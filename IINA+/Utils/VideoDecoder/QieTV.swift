//
//  QieTV.swift
//  IINA+
//
//  Created by xjbeta on 6/9/22.
//  Copyright © 2022 xjbeta. All rights reserved.
//

import Cocoa
import Alamofire
import Marshal

actor QieTV: SupportSiteProtocol {
    
    func liveInfo(_ url: String) async throws -> any LiveInfo {
        try await roomInfo(url)
    }
    
    func decodeUrl(_ url: String) async throws -> YouGetJSON {
        let info = try await mInfo(url)
        var re = YouGetJSON(rawUrl: url)
        re.title = info.title
        re.streams["Default"] = .init(url: info.url.https())
        return re
    }
    
    private func roomID(from url: String) -> String? {
        guard let u = URL(string: url) else { return nil }
        return u.pathComponents.first { $0 != "/" && !$0.isEmpty }
    }
    
    private func fetchRoomData(_ url: String) async throws -> (JSONObject, isNextData: Bool) {
        guard let rid = roomID(from: url) else { throw VideoGetError.invalidLink }
        let api = "https://www.qie.tv/api/v1/room/\(rid)"
        let data = try await AF.request(api).serializingData().value
        let json: JSONObject = try JSONParser.JSONObjectWithData(data)

        if let errorCode: Int = try? json.value(for: "error"),
           errorCode == 101 {
            let nextData = try await fetchRoomDataFallback(url)
            return (nextData, true)
        }

        if let dict: JSONObject = try? json.value(for: "data") {
            return (dict, false)
        } else if let str: String = try? json.value(for: "data") {
            Log("qieTV fetchRoomData data string: \(str)")
            throw VideoGetError.isNotLiving
        } else {
            throw VideoGetError.notFountData
        }
    }

    private func fetchRoomDataFallback(_ url: String) async throws -> JSONObject {
        var html = try await AF.request(url).serializingString().value
        html = html.subString(from: "__NEXT_DATA__", to: "</script>")
            .subString(from: ">")

        guard let data = html.data(using: .utf8) else { throw VideoGetError.notFountData }
        return try JSONParser.JSONObjectWithData(data)
    }
    
    func roomInfo(_ url: String) async throws -> QieTVInfo {
        let (data, isNextData) = try await fetchRoomData(url)
        if isNextData {
            return try QieTVInfo(nextData: data)
        }
        return try QieTVInfo(object: data)
    }
    
    func mInfo(_ url: String) async throws -> QieTVInfo {
        let (data, isNextData) = try await fetchRoomData(url)
        if isNextData { throw VideoGetError.notFountData }
        return try QieTVInfo(streamObject: data)
    }
}

struct QieTVInfo: Unmarshaling, LiveInfo {
    var title: String = ""
    var name: String = ""
    var avatar: String
    var isLiving = false
    var cover: String = ""
    var site: SupportSites = .qieTV
    
    var roomID: String = ""
    var url: String = ""
    
    init(object: MarshaledObject) throws {
        title = try object.value(for: "room_name")
        name = try object.value(for: "nickname")
        if let s: String = try? object.value(for: "show_status") {
            isLiving = s == "1"
        } else {
            let i: Int = try object.value(for: "show_status")
            isLiving = i == 1
        }
        cover = try object.value(for: "room_src")
        roomID = try object.value(for: "room_id")
        avatar = try object.value(for: "owner_avatar")
    }
    
    init(nextData: MarshaledObject) throws {
        let roomInfoPath = "props.initialState.roomInfo.roomInfo.room_info"
        title = try nextData.value(for: "\(roomInfoPath).room_name")
        name = try nextData.value(for: "\(roomInfoPath).nickname")
        isLiving = "\(try nextData.any(for: "\(roomInfoPath).is_live"))" == "1"
        cover = try nextData.value(for: "\(roomInfoPath).room_src_square")
        roomID = try nextData.value(for: "\(roomInfoPath).room_id")

        let uid: String = try nextData.value(for: "\(roomInfoPath).owner_uid")
        let avatarCDN: String = try nextData.value(for: "runtimeConfig.AVATAR_CDN")
        avatar = "https:" + avatarCDN + "/avatar.php?uid=\(uid)&size=middle&force=1"
    }
    
    init(streamObject: MarshaledObject) throws {
        try self.init(object: streamObject)
        let rtmpUrl: String = try streamObject.value(for: "rtmp_url")
        let rtmpLive: String = try streamObject.value(for: "rtmp_live")
        url = rtmpUrl + "/" + rtmpLive
    }
}
