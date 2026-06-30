//
//  ArticleSpeechDocument.swift
//  NetNewsWire
//
//  Created by NetNewsWire contributors on 4/30/26.
//  Copyright © 2026 Ranchero Software, LLC. All rights reserved.
//

import Foundation

struct ArticleSpeechDocument: Decodable {
	let text: String
	let tokens: [ArticleSpeechToken]
}

struct ArticleSpeechToken: Decodable {
	let id: String
	let text: String
}
