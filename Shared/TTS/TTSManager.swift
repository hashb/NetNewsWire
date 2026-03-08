//
//  TTSManager.swift
//  NetNewsWire
//
//  Created for TTS integration with KokoroTTS.
//

@preconcurrency import AVFoundation
import AudioToolbox
@preconcurrency import MLX
import Foundation
@preconcurrency import KokoroSwift
import Combine
import MLXUtilsLibrary
import MediaPlayer

/// Wraps a non-Sendable value for safe transfer across concurrency boundaries when the caller
/// guarantees exclusive access (no concurrent reads and writes to the same instance).
private struct UncheckedSendable<T>: @unchecked Sendable {
	let value: T
}

/// Protocol for receiving TTS playback events (word highlighting, state changes).
@MainActor protocol TTSManagerDelegate: AnyObject {
	func ttsDidStartPlaying()
	func ttsDidStopPlaying()
	func ttsDidUpdateCurrentTokenIndex(_ index: Int)
	func ttsDidFinishGenerating()
}

/// Singleton service that manages text-to-speech using the Kokoro TTS engine.
/// Adapted from KokoroTTS app's KokoroTTSModel.
@MainActor final class TTSManager: ObservableObject {

	static let shared = TTSManager()

	// MARK: - Delegate

	weak var delegate: TTSManagerDelegate?

	// MARK: - TTS Engine

	/// The Kokoro text-to-speech engine instance
	private(set) var kokoroTTSEngine: KokoroTTS?

	/// Dictionary of available voices, mapped by voice name to MLX array data
	private(set) var voices: [String: MLXArray] = [:]

	/// Array of voice names available for selection
	@Published private(set) var voiceNames: [String] = []

	/// Whether the TTS model is loaded and ready
	@Published private(set) var isModelLoaded: Bool = false

	/// Whether the model is currently loading
	@Published private(set) var isModelLoading: Bool = false

	// MARK: - Audio Engine

	/// The audio engine used for playback
	var audioEngine: AVAudioEngine?

	/// The audio player node attached to the audio engine
	var playerNode: AVAudioPlayerNode?

	// MARK: - Voice Selection

	/// The currently selected voice name
	@Published var selectedVoice: String = "" {
		didSet {
			UserDefaults.standard.set(selectedVoice, forKey: "ttsSelectedVoice")
		}
	}

	/// Speech speed multiplier (0.5 = half speed, 1.0 = normal, 2.0 = double speed)
	@Published var speechSpeed: Float = 1.0 {
		didSet {
			UserDefaults.standard.set(speechSpeed, forKey: "ttsSpeechSpeed")
		}
	}

	// MARK: - Playback State

	/// Whether audio is currently playing
	@Published var isPlaying: Bool = false

	/// Whether there is audio loaded and ready to play
	@Published var hasAudio: Bool = false

	/// Whether audio generation is still in progress
	@Published var isGeneratingAudio: Bool = false

	/// Flag to cancel ongoing generation
	nonisolated(unsafe) var shouldCancelGeneration: Bool = false

	/// Current playback position in seconds
	@Published var currentTime: Double = 0.0

	/// Total duration of loaded audio in seconds
	@Published var totalDuration: Double = 0.0

	/// Stored audio samples for seeking
	var audioSamples: [Float] = []

	/// Stored tokens for follow-along display
	var allTokens: [(text: String, start_ts: Double?, end_ts: Double?, whitespace: String)] = []

	/// Index of the token currently being spoken (-1 if none)
	@Published var currentTokenIndex: Int = -1 {
		didSet {
			if currentTokenIndex != oldValue {
				delegate?.ttsDidUpdateCurrentTokenIndex(currentTokenIndex)
			}
		}
	}

	/// Audio format for playback
	var audioFormat: AVAudioFormat?

	/// Timer for updating playback position
	var timer: Timer?

	/// Position tracking for seek operations
	var playbackStartTime: Date?
	var playbackStartPosition: Double = 0.0

	// MARK: - Initialization

	private init() {
		// Load saved preferences
		let savedVoice = UserDefaults.standard.string(forKey: "ttsSelectedVoice") ?? ""
		let savedSpeed = UserDefaults.standard.float(forKey: "ttsSpeechSpeed")

		if !savedVoice.isEmpty {
			selectedVoice = savedVoice
		}
		if savedSpeed > 0 {
			speechSpeed = savedSpeed
		}
	}

	// MARK: - Model Loading

	/// Loads the TTS model and voices. Call this when TTS is first enabled or model is downloaded.
	func loadModel() {
		guard !isModelLoaded, !isModelLoading else { return }

		isModelLoading = true

		guard let modelPath = Bundle.main.url(forResource: "kokoro-v1_0", withExtension: "safetensors"),
			  let voiceFilePath = Bundle.main.url(forResource: "voices", withExtension: "npz") else {
			print("TTS model files not found in bundle")
			isModelLoading = false
			return
		}

		DispatchQueue.global(qos: .userInitiated).async { [weak self] in
			let engine = KokoroTTS(modelPath: modelPath)
			let loadedVoices = NpyzReader.read(fileFromPath: voiceFilePath) ?? [:]
			let names = loadedVoices.keys.map { String($0.split(separator: ".")[0]) }.sorted(by: <)

			// Warm up the model
			if let firstVoice = names.first, let voiceData = loadedVoices[firstVoice + ".npy"] {
				let _ = try? engine.generateAudio(
					voice: voiceData,
					language: firstVoice.first == "a" ? .enUS : .enGB,
					text: "Hello",
					speed: 1.0
				)
			}

			DispatchQueue.main.async {
				guard let self else { return }
				self.kokoroTTSEngine = engine
				self.voices = loadedVoices
				self.voiceNames = names

				// Set default voice if not yet selected
				if self.selectedVoice.isEmpty || !names.contains(self.selectedVoice) {
					self.selectedVoice = names.first ?? ""
				}

				self.isModelLoaded = true
				self.isModelLoading = false

				// Set up audio engine
				self.setupAudioEngine()
				self.setupRemoteCommandCenter()

				print("TTS model loaded with \(names.count) voices")
			}
		}
	}

	/// Sets up the audio engine and player node.
	private func setupAudioEngine() {
		let engine = AVAudioEngine()
		let node = AVAudioPlayerNode()
		engine.attach(node)
		audioEngine = engine
		playerNode = node
	}

	// MARK: - Speech Generation

	/// Converts the provided text to speech and plays it.
	/// - Parameter text: The plain text to be converted to speech
	func say(_ text: String) {
		guard isModelLoaded, let engine = kokoroTTSEngine, let audioEngine, let playerNode else {
			print("TTS model not loaded")
			return
		}

		// Stop any existing playback
		stop()

		// Mark as generating and reset cancel flag
		isGeneratingAudio = true
		shouldCancelGeneration = false

		// Preprocess text
		var processedText = text
		processedText = removeHyphensFromCompoundWords(processedText)
		processedText = convertParentheticalsToDashes(processedText)
		processedText = convertSlashesToDashes(processedText)
		let chunks = splitIntoChunks(processedText, sentencesPerChunk: 2)
		print("TTS: Split text into \(chunks.count) chunk(s)")

		let sampleRate = Double(KokoroTTS.Constants.samplingRate)
		let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
		audioFormat = format

		// Connect the player node
		audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)

		// Request a larger buffer size
		let outputUnit = audioEngine.outputNode.audioUnit!
		var bufferSize: UInt32 = 2048
		AudioUnitSetProperty(
			outputUnit,
			kAudioDevicePropertyBufferFrameSize,
			kAudioUnitScope_Global,
			0,
			&bufferSize,
			UInt32(MemoryLayout<UInt32>.size)
		)

		// Start the audio engine
		do {
			try audioEngine.start()
		} catch {
			print("Audio engine failed to start: \(error.localizedDescription)")
			isGeneratingAudio = false
			return
		}

		// Reset stored data
		audioSamples = []
		allTokens = []

		// Show player UI immediately
		hasAudio = true
		currentTime = 0.0
		totalDuration = 0.0

		delegate?.ttsDidStartPlaying()

		// Capture values for background processing.
		// Wrap non-Sendable KokoroSwift types so they can cross the concurrency boundary safely.
		// The engine and language value are read-only during generation and never concurrently mutated.
		let voice = voices[selectedVoice + ".npy"]!
		let wrappedEngine = UncheckedSendable(value: engine)
		let wrappedLanguage = UncheckedSendable(value: selectedVoice.first == "a" ? Language.enUS : Language.enGB)
		let speed = speechSpeed

		// Process chunks in background
		DispatchQueue.global(qos: .userInitiated).async { [weak self, wrappedEngine, wrappedLanguage] in
			let engine = wrappedEngine.value
			let language = wrappedLanguage.value
			guard let self else { return }

			var totalAudioLength: Double = 0.0

			for (index, chunk) in chunks.enumerated() {
				if self.shouldCancelGeneration {
					print("TTS: Generation cancelled")
					break
				}

				// Generate audio
				let result: ([Float], [MToken]?)
				do {
					result = try engine.generateAudio(
						voice: voice,
						language: language,
						text: chunk,
						speed: speed
					)
				} catch KokoroTTS.KokoroTTSError.tooManyTokens {
					let subChunks = self.splitLongSentence(chunk)
					var combinedAudio: [Float] = []
					var combinedTokens: [MToken] = []
					var subFailed = false
					for subChunk in subChunks {
						guard !self.shouldCancelGeneration else { break }
						do {
							let (subAudio, subTokens) = try engine.generateAudio(
								voice: voice,
								language: language,
								text: subChunk,
								speed: speed
							)
							combinedAudio.append(contentsOf: subAudio)
							if let subTokens {
								combinedTokens.append(contentsOf: subTokens)
							}
						} catch {
							print("TTS: Sub-chunk failed: \(error)")
							subFailed = true
						}
					}
					if combinedAudio.isEmpty && subFailed {
						continue
					}
					result = (combinedAudio, combinedTokens.isEmpty ? nil : combinedTokens)
				} catch {
					print("TTS: Chunk \(index + 1) failed: \(error)")
					continue
				}

				let (audio, tokenArray) = result
				let chunkAudioLength = Double(audio.count) / sampleRate
				let currentTotalLength = totalAudioLength

				// Convert MToken values to the Sendable tuple format before crossing to the main actor.
				let sendableTokens: [(text: String, start_ts: Double?, end_ts: Double?, whitespace: String)]? = tokenArray.map { tokens in
					tokens.map { t in (text: t.text, start_ts: t.start_ts, end_ts: t.end_ts, whitespace: t.whitespace) }
				}

				DispatchQueue.main.async {
					self.audioSamples.append(contentsOf: audio)

					// Adjust token timestamps
					if let sendableTokens {
						if index > 0 && !self.allTokens.isEmpty {
							self.allTokens.append((text: " ", start_ts: currentTotalLength, end_ts: currentTotalLength, whitespace: ""))
						}
						for token in sendableTokens {
							let adjustedStart = token.start_ts.map { $0 + currentTotalLength }
							let adjustedEnd = token.end_ts.map { $0 + currentTotalLength }
							self.allTokens.append((text: token.text, start_ts: adjustedStart, end_ts: adjustedEnd, whitespace: token.whitespace))
						}
					}

					// Create and schedule the buffer
					guard let buffer = self.createBuffer(from: audio, format: format) else { return }

					let options: AVAudioPlayerNodeBufferOptions = index == 0 ? .interrupts : []
					playerNode.scheduleBuffer(buffer, at: nil, options: options, completionHandler: nil)

					// Start playback on first chunk
					if index == 0 {
						playerNode.play()
						self.isPlaying = true
						self.playbackStartTime = Date()
						self.playbackStartPosition = 0.0
						self.startPlaybackTimer()
					}

					self.totalDuration = currentTotalLength + chunkAudioLength
					self.updateNowPlayingInfo()
				}

				totalAudioLength += chunkAudioLength
			}

			DispatchQueue.main.async {
				self.isGeneratingAudio = false
				self.delegate?.ttsDidFinishGenerating()
			}
		}
	}

	// MARK: - Display Helpers

	/// Returns the display name for a voice (e.g., "af_bella" -> "Bella").
	func displayNameForVoice(_ voice: String) -> String {
		if let underscoreIndex = voice.firstIndex(of: "_") {
			let nameStart = voice.index(after: underscoreIndex)
			let name = String(voice[nameStart...])
			return name.prefix(1).uppercased() + name.dropFirst()
		}
		return voice
	}

	/// Formats a time interval as mm:ss.
	func formatTime(_ time: Double) -> String {
		let minutes = Int(time) / 60
		let seconds = Int(time) % 60
		return String(format: "%d:%02d", minutes, seconds)
	}
}
