//
//  PreferencesWindowController.swift
//  iina+
//
//  Created by xjbeta on 2018/7/30.
//  Copyright © 2018 xjbeta. All rights reserved.
//

import Cocoa

class PreferencesWindowController: NSWindowController {

    override func windowDidLoad() {
        super.windowDidLoad()
        window?.isMovableByWindowBackground = true
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .hidden
        window?.delegate = self
        
		Processes.shared.iina.updateIINAState()
        
        if let preferencesTabViewController = contentViewController as? PreferencesTabViewController {
            preferencesTabViewController.autoResizeWindow(preferencesTabViewController.tabView.selectedTabViewItem, animate: false)
        }
    }

}

extension PreferencesWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
		Processes.shared.iina.updateIINAState()
        NSColorPanel.shared.close()
    }
}
