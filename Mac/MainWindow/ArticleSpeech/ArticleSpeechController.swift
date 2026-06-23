//
//  ArticleSpeechController.swift
//  NetNewsWire
//
//  Created by NetNewsWire contributors on 4/30/26.
//  Copyright © 2026 Ranchero Software, LLC. All rights reserved.
//

@preconcurrency import AVFoundation
import Foundation
import KokoroCoreML
import os

@MainActor final class ArticleSpeechController: @unchecked Sendable {

	private enum PlaybackState: Equatable {
		case idle
		case preparing(String)
		case downloading(Double)
		case playing
		case paused
		case failed(String)

		var isActive: Bool {
			self != .idle
		}
	}

	private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ArticleSpeechController")
	private static let defaultVoice = "af_heart"
	private static let defaultSpeed: Float = 1.0
	private static let highlightLeadTime: TimeInterval = 0.03
	private static let seekInterval: TimeInterval = 10

	private weak var detailViewController: DetailViewController?
	private let controlsView: ArticleSpeechControlsView
	private let invalidateToolbar: () -> Void

	private var engine: KokoroEngine?
	private let audioEngine = AVAudioEngine()
	private let player = AVAudioPlayerNode()
	private var isAudioConfigured = false

	private var speechTask: Task<Void, Never>?
	private var timer: Timer?
	private var state: PlaybackState = .idle {
		didSet {
			updateControls()
			invalidateToolbar()
		}
	}

	private var documentTokens: [ArticleSpeechToken] = []
	private var normalizedDocumentTokens: [String] = []
	private var nextDocumentTokenIndex = 0
	private var timestamps: [SynthesisTimestamp] = []
	private var timestampTokenIDs: [String?] = []
	private var highlightedTimestampIndex: Int?
	private var followsHighlightedText = true

	private var generatedSamples: [Float] = []
	private var scheduledFrameEnd = 0
	private var anchorFrame = 0
	private var pausedFrame = 0
	private var streamFinished = false

	init(detailViewController: DetailViewController, controlsView: ArticleSpeechControlsView, invalidateToolbar: @escaping () -> Void) {
		self.detailViewController = detailViewController
		self.controlsView = controlsView
		self.invalidateToolbar = invalidateToolbar
		configureControlActions()
		detailViewController.articleSpeechUserScrollAction = { [weak self] in
			self?.articleViewDidScroll()
		}
	}

	var isActive: Bool {
		state.isActive
	}

	var isPlaying: Bool {
		state == .playing
	}

	func toggleSpeech() {
		if state.isActive {
			stop()
		} else {
			speechTask = Task { [weak self] in
				await self?.startSpeech()
			}
		}
	}

	func togglePlayPause() {
		switch state {
		case .playing:
			pause()
		case .paused:
			resume()
		default:
			break
		}
	}

	func stop() {
		speechTask?.cancel()
		speechTask = nil
		timer?.invalidate()
		timer = nil
		player.stop()
		audioEngine.stop()
		resetPlaybackData()
		detailViewController?.clearArticleSpeech()
		controlsView.setPlaybackActive(false)
		state = .idle
	}

	func rewind() {
		seek(to: currentPlaybackTime() - Self.seekInterval)
	}

	func forward() {
		seek(to: currentPlaybackTime() + Self.seekInterval)
	}

	func seek(to time: TimeInterval) {
		guard state == .playing || state == .paused else {
			return
		}

		let targetFrame = clampedSeekFrame(for: time)
		let shouldResume = state == .playing
		player.stop()
		anchorFrame = targetFrame
		pausedFrame = targetFrame
		scheduledFrameEnd = targetFrame
		scheduleAvailableAudio(from: targetFrame)

		if shouldResume {
			player.play()
			state = .playing
		} else {
			state = .paused
		}

		updateHighlight(at: Double(targetFrame) / Double(KokoroEngine.sampleRate))
		updateControls()
	}
}

private extension ArticleSpeechController {

	func configureControlActions() {
		controlsView.playPauseAction = { [weak self] in
			self?.togglePlayPause()
		}
		controlsView.rewindAction = { [weak self] in
			self?.rewind()
		}
		controlsView.forwardAction = { [weak self] in
			self?.forward()
		}
		controlsView.syncAction = { [weak self] in
			self?.syncHighlightToViewport()
		}
		controlsView.scrubAction = { [weak self] time in
			self?.seek(to: time)
		}
	}

	func startSpeech() async {
		followsHighlightedText = true
		state = .preparing(NSLocalizedString("Preparing article...", comment: "Article speech status"))
		controlsView.setPlaybackActive(true)

		do {
			guard let detailViewController else {
				throw ArticleSpeechError.noArticle
			}

			let document = try await detailViewController.prepareArticleSpeech()
			let text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !text.isEmpty, !document.tokens.isEmpty else {
				throw ArticleSpeechError.noReadableText
			}

			try Task.checkCancellation()
			resetPlaybackData()
			documentTokens = document.tokens
			normalizedDocumentTokens = document.tokens.map { Self.normalizedToken($0.text) }

			let engine = try await loadEngine()
			try Task.checkCancellation()
			try configureAudioEngine()

			state = .preparing(NSLocalizedString("Generating audio...", comment: "Article speech status"))
			let voice = Self.defaultVoice
			let speed = Self.defaultSpeed
			let stream = try await Task.detached(priority: .userInitiated) {
				try engine.speakWithTimestamps(text, voice: voice, speed: speed)
			}.value

			try Task.checkCancellation()
			state = .playing
			startTimer()

			for await event in stream {
				if Task.isCancelled {
					break
				}
				handle(event)
			}

			if !Task.isCancelled {
				streamFinished = true
				if generatedSamples.isEmpty {
					throw ArticleSpeechError.noAudioGenerated
				}
				updateControls()
			}
		} catch is CancellationError {
			// Stop handles cancellation cleanup.
		} catch {
			fail(error)
		}
	}

	func loadEngine() async throws -> KokoroEngine {
		if let engine {
			return engine
		}

		if !KokoroEngine.isDownloaded {
			state = .downloading(0)
			try await downloadModels()
		}

		state = .preparing(NSLocalizedString("Loading voice...", comment: "Article speech status"))
		let loadedEngine = try await Task.detached(priority: .userInitiated) {
			try KokoroEngine(modelDirectory: KokoroEngine.defaultModelDirectory)
		}.value
		engine = loadedEngine
		return loadedEngine
	}

	func downloadModels() async throws {
		let progressStream = AsyncThrowingStream<Double, Error> { continuation in
			let task = Task.detached(priority: .userInitiated) {
				do {
					try KokoroEngine.download { progress in
						continuation.yield(progress)
					}
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in
				task.cancel()
			}
		}

		for try await progress in progressStream {
			state = .downloading(progress)
		}
	}

	func configureAudioEngine() throws {
		if !isAudioConfigured {
			audioEngine.attach(player)
			audioEngine.connect(player, to: audioEngine.mainMixerNode, format: KokoroEngine.audioFormat)
			isAudioConfigured = true
		}

		if !audioEngine.isRunning {
			try audioEngine.start()
		}
	}

	func handle(_ event: TimedSpeakEvent) {
		switch event {
		case .audio(let buffer, let newTimestamps):
			append(buffer: buffer, timestamps: newTimestamps)
		case .chunkFailed(let error):
			Self.logger.error("Article speech chunk failed: \(error.localizedDescription)")
		}
	}

	func append(buffer: AVAudioPCMBuffer, timestamps newTimestamps: [SynthesisTimestamp]) {
		let samples = Self.samples(from: buffer)
		guard !samples.isEmpty else {
			return
		}

		let oldFrameEnd = generatedSamples.count
		generatedSamples.append(contentsOf: samples)
		timestamps.append(contentsOf: newTimestamps)
		appendTimestampMappings(newTimestamps)

		if state == .playing || state == .paused {
			if scheduledFrameEnd <= oldFrameEnd {
				let scheduleStart = max(scheduledFrameEnd, oldFrameEnd)
				scheduleAudio(from: scheduleStart, to: generatedSamples.count)
			}
			if state == .playing, !player.isPlaying {
				player.play()
			}
		}

		updateControls()
	}

	func pause() {
		guard state == .playing else {
			return
		}
		pausedFrame = currentPlaybackFrame()
		player.pause()
		state = .paused
	}

	func resume() {
		guard state == .paused else {
			return
		}

		if scheduledFrameEnd <= pausedFrame {
			anchorFrame = pausedFrame
			scheduleAvailableAudio(from: pausedFrame)
		}
		player.play()
		state = .playing
	}

	func startTimer() {
		timer?.invalidate()
		let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
			Task { @MainActor [weak self] in
				self?.tick()
			}
		}
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
	}

	func tick() {
		if state == .playing {
			pausedFrame = currentPlaybackFrame()
		}

		let time = currentPlaybackTime()
		updateHighlight(at: time)
		updateControls()

		if streamFinished, generatedSamples.count > 0, currentPlaybackFrame() >= generatedSamples.count - 1 {
			stop()
		}
	}

	func scheduleAvailableAudio(from frame: Int) {
		scheduleAudio(from: frame, to: generatedSamples.count)
	}

	func scheduleAudio(from startFrame: Int, to endFrame: Int) {
		guard startFrame < endFrame, startFrame >= 0, endFrame <= generatedSamples.count else {
			return
		}
		let frameCount = endFrame - startFrame
		guard let buffer = AVAudioPCMBuffer(pcmFormat: KokoroEngine.audioFormat, frameCapacity: AVAudioFrameCount(frameCount)),
			  let dest = buffer.floatChannelData?[0] else {
			return
		}
		buffer.frameLength = AVAudioFrameCount(frameCount)
		generatedSamples.withUnsafeBufferPointer { src in
			guard let base = src.baseAddress else {
				return
			}
			dest.initialize(from: base + startFrame, count: frameCount)
		}
		player.scheduleBuffer(buffer, completionHandler: nil)
		scheduledFrameEnd = endFrame
	}

	func currentPlaybackFrame() -> Int {
		guard state == .playing, audioEngine.isRunning else {
			return min(pausedFrame, generatedSamples.count)
		}

		guard let nodeTime = player.lastRenderTime,
			  let playerTime = player.playerTime(forNodeTime: nodeTime),
			  playerTime.sampleRate > 0 else {
			return min(pausedFrame, generatedSamples.count)
		}

		let frame = anchorFrame + Int(playerTime.sampleTime)
		return min(max(frame, 0), generatedSamples.count)
	}

	func currentPlaybackTime() -> TimeInterval {
		Double(currentPlaybackFrame()) / Double(KokoroEngine.sampleRate)
	}

	func clampedSeekFrame(for time: TimeInterval) -> Int {
		let frame = Int((max(time, 0) * Double(KokoroEngine.sampleRate)).rounded())
		return min(max(frame, 0), generatedSamples.count)
	}

	func appendTimestampMappings(_ newTimestamps: [SynthesisTimestamp]) {
		for timestamp in newTimestamps {
			timestampTokenIDs.append(nextTokenID(for: timestamp.text))
		}
	}

	func nextTokenID(for text: String) -> String? {
		guard nextDocumentTokenIndex < documentTokens.count else {
			return nil
		}

		let target = Self.normalizedToken(text)
		if !target.isEmpty {
			let searchEnd = min(documentTokens.count, nextDocumentTokenIndex + 12)
			for index in nextDocumentTokenIndex..<searchEnd {
				if normalizedDocumentTokens[index] == target {
					nextDocumentTokenIndex = index + 1
					return documentTokens[index].id
				}
			}
		}

		let token = documentTokens[nextDocumentTokenIndex]
		nextDocumentTokenIndex += 1
		return token.id
	}

	func updateHighlight(at time: TimeInterval) {
		guard !timestamps.isEmpty else {
			return
		}

		let adjustedTime = time + Self.highlightLeadTime
		let index = timestamps.lastIndex { $0.startTime <= adjustedTime }
		guard index != highlightedTimestampIndex else {
			return
		}

		highlightedTimestampIndex = index
		let tokenID = index.flatMap { timestampTokenIDs.indices.contains($0) ? timestampTokenIDs[$0] : nil }
		detailViewController?.setArticleSpeechHighlight(tokenID, scrollToHighlight: followsHighlightedText)
	}

	func articleViewDidScroll() {
		guard state.isActive, followsHighlightedText else {
			return
		}
		followsHighlightedText = false
		updateControls()
	}

	func syncHighlightToViewport() {
		guard state.isActive else {
			return
		}

		followsHighlightedText = true
		if let tokenID = highlightedTokenID() {
			detailViewController?.setArticleSpeechHighlight(tokenID, scrollToHighlight: true)
		} else {
			updateHighlight(at: currentPlaybackTime())
		}
		updateControls()
	}

	func highlightedTokenID() -> String? {
		guard let index = highlightedTimestampIndex, timestampTokenIDs.indices.contains(index) else {
			return nil
		}
		return timestampTokenIDs[index]
	}

	func updateControls() {
		let position = currentPlaybackTime()
		let generatedDuration = Double(generatedSamples.count) / Double(KokoroEngine.sampleRate)

		let status: String?
		let isBusy: Bool
		switch state {
		case .idle:
			status = nil
			isBusy = false
		case .preparing(let message):
			status = message
			isBusy = true
		case .downloading(let progress):
			let percent = Int((min(max(progress, 0), 1) * 100).rounded())
			status = String(format: NSLocalizedString("Downloading voice... %d%%", comment: "Article speech status"), percent)
			isBusy = true
		case .playing:
			status = streamFinished ? nil : NSLocalizedString("Generating audio...", comment: "Article speech status")
			isBusy = false
		case .paused:
			status = streamFinished ? nil : NSLocalizedString("Generating audio...", comment: "Article speech status")
			isBusy = false
		case .failed(let message):
			status = message
			isBusy = false
		}

		controlsView.setPlaybackActive(state.isActive)
		controlsView.update(
			isPlaying: state == .playing,
			isBusy: isBusy,
			position: position,
			duration: generatedDuration,
			status: status,
			followsHighlight: followsHighlightedText)
	}

	func fail(_ error: Error) {
		Self.logger.error("Article speech failed: \(error.localizedDescription)")
		speechTask = nil
		timer?.invalidate()
		timer = nil
		player.stop()
		audioEngine.stop()
		detailViewController?.clearArticleSpeech()
		resetPlaybackData()
		state = .failed(error.localizedDescription)

		Task { @MainActor [weak self] in
			try? await Task.sleep(for: .seconds(2))
			guard let self, case .failed = self.state else {
				return
			}
			self.controlsView.setPlaybackActive(false)
			self.state = .idle
		}
	}

	func resetPlaybackData() {
		documentTokens = []
		normalizedDocumentTokens = []
		nextDocumentTokenIndex = 0
		timestamps = []
		timestampTokenIDs = []
		highlightedTimestampIndex = nil
		followsHighlightedText = true
		generatedSamples = []
		scheduledFrameEnd = 0
		anchorFrame = 0
		pausedFrame = 0
		streamFinished = false
	}

	static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
		guard let channel = buffer.floatChannelData?[0] else {
			return []
		}
		let count = Int(buffer.frameLength)
		return Array(UnsafeBufferPointer(start: channel, count: count))
	}

	static func normalizedToken(_ text: String) -> String {
		String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
	}
}

private enum ArticleSpeechError: LocalizedError {
	case noArticle
	case noReadableText
	case noAudioGenerated

	var errorDescription: String? {
		switch self {
		case .noArticle:
			return NSLocalizedString("No article selected.", comment: "Article speech error")
		case .noReadableText:
			return NSLocalizedString("This article has no readable text.", comment: "Article speech error")
		case .noAudioGenerated:
			return NSLocalizedString("No audio was generated.", comment: "Article speech error")
		}
	}
}
