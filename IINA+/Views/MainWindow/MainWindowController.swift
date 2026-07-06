//
//  MainWindowController.swift
//  iina+
//
//  Created by xjbeta on 2018/7/13.
//  Copyright © 2018 xjbeta. All rights reserved.
//

import Cocoa

class MainWindowController: NSWindowController, NSWindowDelegate {
    
    override func windowDidLoad() {
        super.windowDidLoad()
        window?.isMovableByWindowBackground = true
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .hidden
        
        window?.backgroundColor = .controlBackgroundColor
    }
    
    func windowDidBecomeMain(_ notification: Notification) {
        NotificationCenter.default.post(name: .reloadMainWindowTableView, object: nil)
    }
    
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let w = window,
              w.occlusionState.rawValue == 8194,
              !w.isMainWindow
        else { return }
        NotificationCenter.default.post(name: .reloadMainWindowTableView, object: nil)
		
		Task {
			do {
				let _ = try await Bilibili.shared.isLogin()
			} catch let error {
				Log(error)
			}
		}
    }
}


