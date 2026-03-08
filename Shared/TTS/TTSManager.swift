//
//  TTSManager.swift
//  NetNewsWire
//
//  Created for TTS integration with KokoroTTS.
//

@preconcurrency import AVFoundation
@preconcurrency import MLX
import Foundation
import CommonCrypto
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

	/// Whether model files are being downloaded
	@Published private(set) var isDownloading: Bool = false

	/// Overall download progress (0.0 – 1.0)
	@Published private(set) var downloadProgress: Double = 0.0

	/// Human-readable download status message
	@Published private(set) var downloadStatus: String = ""

	/// Error message from the last failed load/download attempt, if any
	@Published private(set) var modelLoadError: String?

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

	/// The directory where TTS model files are stored.
	static var ttsModelDirectory: URL {
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		return appSupport.appendingPathComponent("NetNewsWire/TTS", isDirectory: true)
	}

	/// Returns true if both model files exist on disk.
	static var modelFilesExist: Bool {
		let dir = ttsModelDirectory
		return FileManager.default.fileExists(atPath: dir.appendingPathComponent("kokoro-v1_0.safetensors").path) &&
			   FileManager.default.fileExists(atPath: dir.appendingPathComponent("voices.npz").path)
	}

	/// Downloads model files from GitHub (if needed) then loads the model.
	/// This is what the "Load Model" button should call.
	func downloadAndLoadModel() {
		guard !isModelLoaded, !isModelLoading, !isDownloading else { return }

		modelLoadError = nil

		if TTSManager.modelFilesExist {
			loadModelFromDisk()
			return
		}

		isDownloading = true
		downloadProgress = 0.0

		let baseURL = "https://github.com/hashb/KokoroTTS/releases/download/v1.2.1"
		let files: [(name: String, sha256: String)] = [
			("kokoro-v1_0.safetensors", "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8"),
			("voices.npz",              "56dbfa2f2970af2e395397020393d368c5f441d09b3de4e9b77f6222e790f10f"),
		]

		Task {
			do {
				let dir = TTSManager.ttsModelDirectory
				try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

				for (index, file) in files.enumerated() {
					let dest = dir.appendingPathComponent(file.name)

					// Skip if file already exists and hash matches
					if FileManager.default.fileExists(atPath: dest.path),
					   sha256(of: dest) == file.sha256 {
						let progress = Double(index + 1) / Double(files.count)
						await MainActor.run {
							downloadProgress = progress
							downloadStatus = "\(file.name) already downloaded"
						}
						continue
					}

					await MainActor.run {
						downloadStatus = "Downloading \(file.name)…"
					}

					let url = URL(string: "\(baseURL)/\(file.name)")!
					try await downloadFile(from: url, to: dest, fileIndex: index, fileCount: files.count)

					guard sha256(of: dest) == file.sha256 else {
						try? FileManager.default.removeItem(at: dest)
						throw DownloadError.hashMismatch(file.name)
					}
				}

				await MainActor.run {
					isDownloading = false
					downloadStatus = ""
					loadModelFromDisk()
				}
			} catch {
				await MainActor.run {
					isDownloading = false
					downloadStatus = ""
					modelLoadError = "Download failed: \(error.localizedDescription)"
					print("TTS download error: \(error)")
				}
			}
		}
	}

	private enum DownloadError: LocalizedError {
		case hashMismatch(String)
		var errorDescription: String? {
			switch self {
			case .hashMismatch(let name): return "SHA-256 mismatch for \(name) — file may be corrupted"
			}
		}
	}

	/// Downloads a single file with progress reporting using URLSession download task.
	/// Each file contributes an equal share of the overall `downloadProgress`.
	private func downloadFile(from url: URL, to dest: URL, fileIndex: Int, fileCount: Int) async throws {
		// Holder keeps the KVO observation alive for the duration of the download.
		final class ProgressHolder: @unchecked Sendable {
			var observation: NSKeyValueObservation?
		}

		let tempURL: URL = try await withCheckedThrowingContinuation { continuation in
			let holder = ProgressHolder()
			let task = URLSession.shared.downloadTask(with: url) { tempURL, _, error in
				holder.observation = nil  // release observation after task completes
				if let error {
					continuation.resume(throwing: error)
				} else if let tempURL {
					continuation.resume(returning: tempURL)
				} else {
					continuation.resume(throwing: URLError(.unknown))
				}
			}

			holder.observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
				let fileProgress = progress.fractionCompleted
				let overall = (Double(fileIndex) + fileProgress) / Double(fileCount)
				let received = Double(task.countOfBytesReceived) / 1_048_576
				let total = task.countOfBytesExpectedToReceive > 0
					? String(format: " / %.0f MB", Double(task.countOfBytesExpectedToReceive) / 1_048_576)
					: ""
				DispatchQueue.main.async {
					self?.downloadProgress = overall
					self?.downloadStatus = "Downloading \(url.lastPathComponent): \(String(format: "%.0f", received)) MB\(total)"
				}
			}
			task.resume()
		}

		// Move from temp location to final destination
		if FileManager.default.fileExists(atPath: dest.path) {
			try FileManager.default.removeItem(at: dest)
		}
		try FileManager.default.moveItem(at: tempURL, to: dest)
	}

	/// Computes the SHA-256 hex digest of a file.
	private func sha256(of url: URL) -> String? {
		guard let data = try? Data(contentsOf: url) else { return nil }
		var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
		data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
		return digest.map { String(format: "%02x", $0) }.joined()
	}

	/// Loads already-downloaded model files from disk into memory.
	private func loadModelFromDisk() {
		guard !isModelLoaded, !isModelLoading else { return }

		isModelLoading = true
		modelLoadError = nil

		let dir = TTSManager.ttsModelDirectory
		let modelPath = dir.appendingPathComponent("kokoro-v1_0.safetensors")
		let voiceFilePath = dir.appendingPathComponent("voices.npz")

		guard FileManager.default.fileExists(atPath: modelPath.path),
			  FileManager.default.fileExists(atPath: voiceFilePath.path) else {
			modelLoadError = "Model files not found in \(dir.path)"
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
				self.modelLoadError = nil

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
		print("TTS-DEBUG: say() called, isModelLoaded=\(isModelLoaded), kokoroEngine=\(kokoroTTSEngine != nil), audioEngine=\(audioEngine != nil), playerNode=\(playerNode != nil), selectedVoice='\(selectedVoice)'")
		guard isModelLoaded, let engine = kokoroTTSEngine, let audioEngine, let playerNode else {
			print("TTS-DEBUG: say() guard failed — model or audio engine not ready")
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
		print("TTS-DEBUG: split into \(chunks.count) chunks, voice='\(selectedVoice)', voices.keys=\(voices.keys.sorted())")

		let sampleRate = Double(KokoroTTS.Constants.samplingRate)
		let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
		audioFormat = format

		// Connect the player node and start the engine
		print("TTS-DEBUG: connecting player node, engine.isRunning=\(audioEngine.isRunning)")
		audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
		do {
			try audioEngine.start()
			print("TTS-DEBUG: audio engine started successfully")
		} catch {
			print("TTS-DEBUG: audio engine failed to start: \(error)")
			isGeneratingAudio = false
			return
		}

		guard !voices.isEmpty else {
			print("TTS-DEBUG: voices dictionary is empty — model may not have loaded voices correctly")
			audioEngine.stop()
			isGeneratingAudio = false
			return
		}
		guard voices[selectedVoice + ".npy"] != nil else {
			print("TTS-DEBUG: voice '\(selectedVoice).npy' not found in voices dict. Available: \(voices.keys.sorted())")
			audioEngine.stop()
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
