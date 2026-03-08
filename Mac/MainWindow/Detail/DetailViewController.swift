//
//  DetailViewController.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 7/26/15.
//  Copyright © 2015 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import WebKit
import RSCore
import Articles
import RSWeb
import Combine

enum DetailState: Equatable {
	case noSelection
	case multipleSelection
	case loading
	case article(Article, CGFloat?)
	case extracted(Article, ExtractedArticle, CGFloat?)
}

final class DetailViewController: NSViewController, WKUIDelegate {

	@IBOutlet var containerView: DetailContainerView!
	@IBOutlet var statusBarView: DetailStatusBarView!

	private lazy var regularWebViewController = createWebViewController()
	private var searchWebViewController: DetailWebViewController?

	var windowState: DetailWindowState {
		currentWebViewController.windowState
	}

	private var currentWebViewController: DetailWebViewController! {
		didSet {
			let webview = currentWebViewController.view
			if containerView.contentView === webview {
				return
			}
			statusBarView.mouseoverLink = nil
			containerView.contentView = webview
		}
	}

	private var currentSourceMode: TimelineSourceMode = .regular {
		didSet {
			currentWebViewController = webViewController(for: currentSourceMode)
		}
	}

	private var detailStateForRegular: DetailState = .noSelection {
		didSet {
			webViewController(for: .regular).state = detailStateForRegular
		}
	}

	private var detailStateForSearch: DetailState = .noSelection {
		didSet {
			webViewController(for: .search).state = detailStateForSearch
		}
	}

	private var isArticleContentJavascriptEnabled = AppDefaults.shared.isArticleContentJavascriptEnabled

	private var cancellables = Set<AnyCancellable>()

	override func viewDidLoad() {
		currentWebViewController = regularWebViewController
		NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor in
				self?.userDefaultsDidChange()
			}
		}

		// Set up TTS delegate
		TTSManager.shared.delegate = self

		// Sync controls immediately (model may already be loaded)
		updateTTSControlsVisibility()

		// Subscribe to future state changes
		TTSManager.shared.$isModelLoaded
			.receive(on: RunLoop.main)
			.sink { [weak self] _ in self?.updateTTSControlsVisibility() }
			.store(in: &cancellables)

		TTSManager.shared.$hasAudio
			.receive(on: RunLoop.main)
			.sink { [weak self] _ in self?.updateTTSControlsVisibility() }
			.store(in: &cancellables)
	}

	override func viewWillAppear() {
		super.viewWillAppear()
		updateTTSControlsVisibility()
	}

	private func updateTTSControlsVisibility() {
		let tts = TTSManager.shared
		if tts.isModelLoaded || tts.hasAudio {
			containerView.showTTSControls()
		} else {
			containerView.hideTTSControls()
		}
	}

	// MARK: - API

	func setState(_ state: DetailState, mode: TimelineSourceMode) {
		// Stop TTS when article changes
		if TTSManager.shared.hasAudio {
			stopTTS()
		}

		switch mode {
		case .regular:
			detailStateForRegular = state
		case .search:
			detailStateForSearch = state
		}
	}

	func showDetail(for mode: TimelineSourceMode) {
		currentSourceMode = mode
	}

	func stopMediaPlayback() {
		currentWebViewController.stopMediaPlayback()
	}

	func canScrollDown() async -> Bool {
		await currentWebViewController.canScrollDown()
	}

	func canScrollUp() async -> Bool {
		await currentWebViewController.canScrollUp()
	}

	override func scrollPageDown(_ sender: Any?) {
		currentWebViewController.scrollPageDown(sender)
	}

	override func scrollPageUp(_ sender: Any?) {
		currentWebViewController.scrollPageUp(sender)
	}

	// MARK: - Navigation

	func focus() {
		guard let window = currentWebViewController.webView.window else {
			return
		}
		window.makeFirstResponderUnlessDescendantIsFirstResponder(currentWebViewController.webView)
	}

	// MARK: - TTS

	/// Starts TTS for the current article.
	func startTTS() {
		print("TTS-DEBUG: startTTS called, isTTSEnabled=\(AppDefaults.shared.isTTSEnabled), isModelLoaded=\(TTSManager.shared.isModelLoaded)")
		guard AppDefaults.shared.isTTSEnabled else {
			print("TTS-DEBUG: startTTS aborted - TTS not enabled")
			return
		}

		let tts = TTSManager.shared
		if !tts.isModelLoaded {
			print("TTS-DEBUG: model not loaded, triggering download")
			tts.downloadAndLoadModel()
		}

		// Extract text from the web view
		print("TTS-DEBUG: extracting article text...")
		currentWebViewController.extractArticleText { [weak self] text in
			print("TTS-DEBUG: extractArticleText returned text=\(text.map { "\($0.prefix(80))..." } ?? "nil")")
			guard let self, let text, !text.isEmpty else {
				print("TTS-DEBUG: text is nil or empty, aborting")
				return
			}

			// Start TTS first — say() calls stop() internally which clears any
			// previous highlighting. Preparing spans after ensures they aren't wiped.
			tts.say(text)

			// Prepare word highlighting after stop() has already run
			self.currentWebViewController.prepareHighlighting()
		}
	}

	/// Stops TTS and clears highlighting.
	func stopTTS() {
		TTSManager.shared.stop()
		currentWebViewController.clearHighlighting()
	}
}

// MARK: - DetailWebViewControllerDelegate

extension DetailViewController: DetailWebViewControllerDelegate {

	func mouseDidEnter(_ detailWebViewController: DetailWebViewController, link: String) {
		guard !link.isEmpty, detailWebViewController === currentWebViewController else {
			return
		}
		statusBarView.mouseoverLink = link
	}

	func mouseDidExit(_ detailWebViewController: DetailWebViewController) {
		guard detailWebViewController === currentWebViewController else {
			return
		}
		statusBarView.mouseoverLink = nil
	}
}

// MARK: - TTSManagerDelegate

extension DetailViewController: TTSManagerDelegate {

	func ttsDidStartPlaying() {
		// Controls shown via Combine binding on hasAudio
	}

	func ttsDidStopPlaying() {
		currentWebViewController.clearHighlighting()
	}

	func ttsDidUpdateCurrentTokenIndex(_ index: Int) {
		currentWebViewController.highlightWord(at: index)
	}

	func ttsDidFinishGenerating() {
		// No action needed
	}
}

// MARK: - Private

private extension DetailViewController {

	func createWebViewController() -> DetailWebViewController {
		let controller = DetailWebViewController()
		controller.delegate = self
		controller.state = .noSelection
		return controller
	}

	func webViewController(for mode: TimelineSourceMode) -> DetailWebViewController {
		switch mode {
		case .regular:
			return regularWebViewController
		case .search:
			if searchWebViewController == nil {
				searchWebViewController = createWebViewController()
			}
			return searchWebViewController!
		}
	}

	func userDefaultsDidChange() {
		if AppDefaults.shared.isArticleContentJavascriptEnabled != isArticleContentJavascriptEnabled {
			isArticleContentJavascriptEnabled = AppDefaults.shared.isArticleContentJavascriptEnabled
			createNewWebViewsAndRestoreState()
		}
	}

	func createNewWebViewsAndRestoreState() {

		regularWebViewController = createWebViewController()
		currentWebViewController = regularWebViewController
		regularWebViewController.state = detailStateForRegular

		searchWebViewController = nil

		if currentSourceMode == .search {
			searchWebViewController = createWebViewController()
			currentWebViewController = searchWebViewController
			searchWebViewController!.state = detailStateForSearch
		}
	}
}
