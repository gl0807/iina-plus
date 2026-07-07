//
//  VideoGetStructs.swift
//  iina+
//
//  Created by xjbeta on 2018/11/1.
//  Copyright © 2018 xjbeta. All rights reserved.
//

import Cocoa
import Marshal

protocol LiveInfo: Sendable {
    var title: String { get }
    var name: String { get }
    var avatar: String { get }
    var cover: String { get }
    var isLiving: Bool { get }
    
    var site: SupportSites { get }
}

final class VideoTreeNode: Sendable, Hashable {
    let title: String
    let isLeaf: Bool
    let children: [VideoTreeNode]
    
    // Common leaf properties
    let site: SupportSites
    let index: Int
    let id: String
    let url: String
    let isLiving: Bool
    let coverUrl: URL?
    
    // Bilibili-specific
    let bvid: String
    let duration: Int
    let isCollection: Bool
    let longTitle: String
    
    init(site: SupportSites = .unsupported,
         index: Int = 0,
         title: String,
         id: String,
         url: String = "",
         isLiving: Bool = false,
         coverUrl: URL? = nil,
         bvid: String = "",
         duration: Int = 0,
         isCollection: Bool = false,
         longTitle: String = "") {
        self.title = title
        self.isLeaf = true
        self.children = []
        self.site = site
        self.index = index
        self.id = id
        self.url = url
        self.isLiving = isLiving
        self.coverUrl = coverUrl
        self.bvid = bvid
        self.duration = duration
        self.isCollection = isCollection
        self.longTitle = longTitle
    }
    
    init(title: String, children: [VideoTreeNode]) {
        self.title = title
        self.isLeaf = false
        self.children = children
        self.site = .unsupported
        self.index = 0
        self.id = ""
        self.url = ""
        self.isLiving = false
        self.coverUrl = nil
        self.bvid = ""
        self.duration = 0
        self.isCollection = false
        self.longTitle = ""
    }
    
    static func == (lhs: VideoTreeNode, rhs: VideoTreeNode) -> Bool {
        lhs === rhs
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

extension [VideoTreeNode] {
    var flattened: [VideoTreeNode] {
        filter { !$0.isLeaf && !$0.children.filter(\.isLeaf).isEmpty }
    }
}

struct BilibiliInfo: Unmarshaling, LiveInfo {
    var title: String = ""
    var name: String = ""
    var avatar: String = ""
    var isLiving = false
    var cover: String = ""
    
    var site: SupportSites = .bilibili
    
    init() {
    }
    
    init(object: MarshaledObject) throws {
        title = try object.value(for: "title")
        name = try object.value(for: "info.uname")
        avatar = try object.value(for: "info.face")
        isLiving = "\(try object.any(for: "live_status"))" == "1"
    }
}
