//
//  TTSControlsView.swift
//  NetNewsWire
//
//  TTS playback controls bar displayed at the top of the article detail view.
//

import AppKit
import Combine

/// A horizontal bar with TTS playback controls: rewind 10s, play/pause, forward 10s.
@MainActor final class TTSControlsView: NSView {

	// MARK: - UI Elements

	private let rewindButton = NSButton()
	private let playPauseButton = NSButton()
	private let forwardButton = NSButton()
	private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
	private let stopButton = NSButton()
	private let separator = NSBox()

	private var cancellables = Set<AnyCancellable>()

	// MARK: - Configuration

	static let controlsHeight: CGFloat = 40.0

	// MARK: - Initialization

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		setupUI()
		bindToTTSManager()
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		setupUI()
		bindToTTSManager()
	}

	// MARK: - Setup

	private func setupUI() {
		wantsLayer = true

		// Configure rewind button
		rewindButton.bezelStyle = .accessoryBarAction
		rewindButton.isBordered = false
		rewindButton.image = NSImage(systemSymbolName: "gobackward.10", accessibilityDescription: "Rewind 10 seconds")
		rewindButton.target = self
		rewindButton.action = #selector(rewindTapped)
		rewindButton.toolTip = "Rewind 10 seconds"
		rewindButton.translatesAutoresizingMaskIntoConstraints = false

		// Configure play/pause button
		playPauseButton.bezelStyle = .accessoryBarAction
		playPauseButton.isBordered = false
		playPauseButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
		playPauseButton.target = self
		playPauseButton.action = #selector(playPauseTapped)
		playPauseButton.toolTip = "Play / Pause"
		playPauseButton.translatesAutoresizingMaskIntoConstraints = false

		// Configure forward button
		forwardButton.bezelStyle = .accessoryBarAction
		forwardButton.isBordered = false
		forwardButton.image = NSImage(systemSymbolName: "goforward.10", accessibilityDescription: "Forward 10 seconds")
		forwardButton.target = self
		forwardButton.action = #selector(forwardTapped)
		forwardButton.toolTip = "Forward 10 seconds"
		forwardButton.translatesAutoresizingMaskIntoConstraints = false

		// Configure time label
		timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
		timeLabel.textColor = .secondaryLabelColor
		timeLabel.alignment = .center
		timeLabel.translatesAutoresizingMaskIntoConstraints = false

		// Configure stop button
		stopButton.bezelStyle = .accessoryBarAction
		stopButton.isBordered = false
		stopButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Stop")
		stopButton.target = self
		stopButton.action = #selector(stopTapped)
		stopButton.toolTip = "Stop reading"
		stopButton.translatesAutoresizingMaskIntoConstraints = false

		// Configure separator
		separator.boxType = .separator
		separator.translatesAutoresizingMaskIntoConstraints = false

		// Add subviews
		addSubview(rewindButton)
		addSubview(playPauseButton)
		addSubview(forwardButton)
		addSubview(timeLabel)
		addSubview(stopButton)
		addSubview(separator)

		translatesAutoresizingMaskIntoConstraints = false

		// Layout constraints
		NSLayoutConstraint.activate([
			// Height
			heightAnchor.constraint(equalToConstant: Self.controlsHeight),

			// Rewind button
			rewindButton.centerYAnchor.constraint(equalTo: centerYAnchor),
			rewindButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
			rewindButton.widthAnchor.constraint(equalToConstant: 28),
			rewindButton.heightAnchor.constraint(equalToConstant: 28),

			// Play/Pause button
			playPauseButton.centerYAnchor.constraint(equalTo: centerYAnchor),
			playPauseButton.leadingAnchor.constraint(equalTo: rewindButton.trailingAnchor, constant: 4),
			playPauseButton.widthAnchor.constraint(equalToConstant: 28),
			playPauseButton.heightAnchor.constraint(equalToConstant: 28),

			// Forward button
			forwardButton.centerYAnchor.constraint(equalTo: centerYAnchor),
			forwardButton.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 4),
			forwardButton.widthAnchor.constraint(equalToConstant: 28),
			forwardButton.heightAnchor.constraint(equalToConstant: 28),

			// Time label
			timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
			timeLabel.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 12),
			timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),

			// Stop button
			stopButton.centerYAnchor.constraint(equalTo: centerYAnchor),
			stopButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
			stopButton.widthAnchor.constraint(equalToConstant: 24),
			stopButton.heightAnchor.constraint(equalToConstant: 24),

			// Separator at bottom
			separator.leadingAnchor.constraint(equalTo: leadingAnchor),
			separator.trailingAnchor.constraint(equalTo: trailingAnchor),
			separator.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
	}

	// MARK: - Binding

	private func bindToTTSManager() {
		let tts = TTSManager.shared

		tts.$isPlaying
			.receive(on: RunLoop.main)
			.sink { [weak self] isPlaying in
				let symbolName = isPlaying ? "pause.fill" : "play.fill"
				let description = isPlaying ? "Pause" : "Play"
				self?.playPauseButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
			}
			.store(in: &cancellables)

		tts.$currentTime
			.combineLatest(tts.$totalDuration)
			.receive(on: RunLoop.main)
			.sink { [weak self] currentTime, totalDuration in
				let current = tts.formatTime(currentTime)
				let total = tts.formatTime(totalDuration)
				self?.timeLabel.stringValue = "\(current) / \(total)"
			}
			.store(in: &cancellables)
	}

	// MARK: - Actions

	@objc private func rewindTapped() {
		TTSManager.shared.seekBackward10s()
	}

	@objc private func playPauseTapped() {
		TTSManager.shared.togglePlayPause()
	}

	@objc private func forwardTapped() {
		TTSManager.shared.seekForward10s()
	}

	@objc private func stopTapped() {
		TTSManager.shared.stop()
	}
}
