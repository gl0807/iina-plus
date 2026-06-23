//
//  JSPlayerURL.swift
//  IINA+
//
//  Created by xjbeta on 2023/11/2.
//  Copyright © 2023 xjbeta. All rights reserved.
//

import Cocoa

class JSPlayerURL: NSObject {
	
	static func encode(_ url: String, site: SupportSites) -> String {
        let key = JSPlayerSchemeName + "://hack.iina-plus.key/webplayer/live.flv"
        
		guard var uc = URLComponents(string: key),
			  let url = url.base64Encode().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
		else {
			fatalError("JSPlayerURL encode \(url)")
		}
				
		uc.queryItems = [
//			.init(name: "site", value: siteKey),
			.init(name: "url", value: url)
		]
		
		return uc.url?.absoluteString ?? key
	}
	
	static func decode(_ url: String) -> (url: String, site: SupportSites) {
		let uc = URLComponents(string: url)

		var urlStr = ""
		
		uc?.queryItems?.forEach {
			switch $0.name {
			case "url":
				urlStr = $0.value?.removingPercentEncoding?.base64Decode() ?? ""
			default:
				break
			}
		}
		
		guard !urlStr.isEmpty else {
			fatalError("JSPlayerURL decode \(url)")
		}

		return (urlStr, SupportSites(url: urlStr))
	}
}
