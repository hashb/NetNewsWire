//
//  TTSPreferencesViewController.swift
//  NetNewsWire
//
//  TTS settings pane for Preferences window.
//

import AppKit
import Combine

final class TTSPreferencesViewController: NSViewController {

	// MARK: - UI Elements

	private let enableCheckbox = NSButton(checkboxWithTitle: "Enable Text-to-Speech", target: nil, action: nil)
	private let modelStatusLabel = NSTextField(labelWithString: "")
	private let loadModelButton = NSButton(title: "Download & Load Model", target: nil, action: nil)
	private let openModelFolderButton = NSButton(title: "Open Model Folder", target: nil, action: nil)
	private let downloadProgressBar = NSProgressIndicator()
	private let modelErrorLabel = NSTextField(wrappingLabelWithString: "")
	private let voiceLabel = NSTextField(labelWithString: "Voice:")
	private let voicePopup = NSPopUpButton()
	private let speedLabel = NSTextField(labelWithString: "Speed:")
	private let speedSlider = NSSlider()
	private let speedValueLabel = NSTextField(labelWithString: "1.0×")
	private let previewButton = NSButton(title: "Preview", target: nil, action: nil)

	private var cancellables = Set<AnyCancellable>()

	// MARK: - Lifecycle

	override func loadView() {
		let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 310))
		self.view = containerView
		setupUI()
		bindState()
	}

	override func viewWillAppear() {
		super.viewWillAppear()
		updateUI()
	}

	// MARK: - Setup

	private func setupUI() {
		// Enable checkbox
		enableCheckbox.state = AppDefaults.shared.isTTSEnabled ? .on : .off
		enableCheckbox.target = self
		enableCheckbox.action = #selector(enableToggled)
		enableCheckbox.translatesAutoresizingMaskIntoConstraints = false

		// Model status
		modelStatusLabel.font = .systemFont(ofSize: 12)
		modelStatusLabel.textColor = .secondaryLabelColor
		modelStatusLabel.translatesAutoresizingMaskIntoConstraints = false

		// Load model button
		loadModelButton.bezelStyle = .rounded
		loadModelButton.target = self
		loadModelButton.action = #selector(loadModelTapped)
		loadModelButton.translatesAutoresizingMaskIntoConstraints = false

		// Open model folder button
		openModelFolderButton.bezelStyle = .rounded
		openModelFolderButton.target = self
		openModelFolderButton.action = #selector(openModelFolderTapped)
		openModelFolderButton.translatesAutoresizingMaskIntoConstraints = false

		// Download progress bar
		downloadProgressBar.style = .bar
		downloadProgressBar.isIndeterminate = false
		downloadProgressBar.minValue = 0
		downloadProgressBar.maxValue = 1
		downloadProgressBar.doubleValue = 0
		downloadProgressBar.isHidden = true
		downloadProgressBar.translatesAutoresizingMaskIntoConstraints = false

		// Error label
		modelErrorLabel.font = .systemFont(ofSize: 11)
		modelErrorLabel.textColor = .systemRed
		modelErrorLabel.isHidden = true
		modelErrorLabel.translatesAutoresizingMaskIntoConstraints = false

		// Voice label and popup
		voiceLabel.alignment = .right
		voiceLabel.translatesAutoresizingMaskIntoConstraints = false
		voicePopup.target = self
		voicePopup.action = #selector(voiceChanged)
		voicePopup.translatesAutoresizingMaskIntoConstraints = false

		// Speed label, slider, value
		speedLabel.alignment = .right
		speedLabel.translatesAutoresizingMaskIntoConstraints = false
		speedSlider.minValue = 0.5
		speedSlider.maxValue = 2.0
		speedSlider.doubleValue = Double(AppDefaults.shared.ttsSpeechSpeed)
		speedSlider.target = self
		speedSlider.action = #selector(speedChanged)
		speedSlider.translatesAutoresizingMaskIntoConstraints = false
		speedValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
		speedValueLabel.translatesAutoresizingMaskIntoConstraints = false

		// Preview button
		previewButton.bezelStyle = .rounded
		previewButton.target = self
		previewButton.action = #selector(previewTapped)
		previewButton.translatesAutoresizingMaskIntoConstraints = false

		// Add to view
		view.addSubview(enableCheckbox)
		view.addSubview(modelStatusLabel)
		view.addSubview(loadModelButton)
		view.addSubview(openModelFolderButton)
		view.addSubview(downloadProgressBar)
		view.addSubview(modelErrorLabel)
		view.addSubview(voiceLabel)
		view.addSubview(voicePopup)
		view.addSubview(speedLabel)
		view.addSubview(speedSlider)
		view.addSubview(speedValueLabel)
		view.addSubview(previewButton)

		// Layout
		NSLayoutConstraint.activate([
			// Enable checkbox
			enableCheckbox.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
			enableCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

			// Model status
			modelStatusLabel.topAnchor.constraint(equalTo: enableCheckbox.bottomAnchor, constant: 16),
			modelStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

			// Load model button
			loadModelButton.centerYAnchor.constraint(equalTo: modelStatusLabel.centerYAnchor),
			loadModelButton.leadingAnchor.constraint(equalTo: modelStatusLabel.trailingAnchor, constant: 12),

			// Open model folder button
			openModelFolderButton.centerYAnchor.constraint(equalTo: modelStatusLabel.centerYAnchor),
			openModelFolderButton.leadingAnchor.constraint(equalTo: loadModelButton.trailingAnchor, constant: 8),

			// Download progress bar
			downloadProgressBar.topAnchor.constraint(equalTo: modelStatusLabel.bottomAnchor, constant: 8),
			downloadProgressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
			downloadProgressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

			// Error label
			modelErrorLabel.topAnchor.constraint(equalTo: downloadProgressBar.bottomAnchor, constant: 4),
			modelErrorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
			modelErrorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

			// Voice label
			voiceLabel.topAnchor.constraint(equalTo: modelErrorLabel.bottomAnchor, constant: 14),
			voiceLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
			voiceLabel.widthAnchor.constraint(equalToConstant: 50),

			// Voice popup
			voicePopup.centerYAnchor.constraint(equalTo: voiceLabel.centerYAnchor),
			voicePopup.leadingAnchor.constraint(equalTo: voiceLabel.trailingAnchor, constant: 8),
			voicePopup.widthAnchor.constraint(equalToConstant: 200),

			// Speed label
			speedLabel.topAnchor.constraint(equalTo: voiceLabel.bottomAnchor, constant: 16),
			speedLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
			speedLabel.widthAnchor.constraint(equalToConstant: 50),

			// Speed slider
			speedSlider.centerYAnchor.constraint(equalTo: speedLabel.centerYAnchor),
			speedSlider.leadingAnchor.constraint(equalTo: speedLabel.trailingAnchor, constant: 8),
			speedSlider.widthAnchor.constraint(equalToConstant: 180),

			// Speed value label
			speedValueLabel.centerYAnchor.constraint(equalTo: speedSlider.centerYAnchor),
			speedValueLabel.leadingAnchor.constraint(equalTo: speedSlider.trailingAnchor, constant: 8),
			speedValueLabel.widthAnchor.constraint(equalToConstant: 40),

			// Preview button
			previewButton.topAnchor.constraint(equalTo: speedLabel.bottomAnchor, constant: 20),
			previewButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 78),
		])
	}

	// MARK: - State Binding

	private func bindState() {
		let tts = TTSManager.shared

		tts.$isModelLoaded
			.receive(on: RunLoop.main)
			.sink { [weak self] _ in
				self?.updateUI()
			}
			.store(in: &cancellables)

		tts.$isModelLoading
			.receive(on: RunLoop.main)
			.sink { [weak self] _ in
				self?.updateUI()
			}
			.store(in: &cancellables)

		tts.$voiceNames
			.receive(on: RunLoop.main)
			.sink { [weak self] _ in
				self?.updateVoicePopup()
			}
			.store(in: &cancellables)

		tts.$modelLoadError
			.receive(on: RunLoop.main)
			.sink { [weak self] _ in
				self?.updateUI()
			}
			.store(in: &cancellables)

		tts.$isDownloading
			.receive(on: RunLoop.main)
			.sink { [weak self] _ in
				self?.updateUI()
			}
			.store(in: &cancellables)

		tts.$downloadProgress
			.receive(on: RunLoop.main)
			.sink { [weak self] progress in
				self?.downloadProgressBar.doubleValue = progress
			}
			.store(in: &cancellables)

		tts.$downloadStatus
			.receive(on: RunLoop.main)
			.sink { [weak self] status in
				self?.modelStatusLabel.stringValue = status.isEmpty ? "Downloading…" : status
			}
			.store(in: &cancellables)
	}

	private func updateUI() {
		let tts = TTSManager.shared
		let isEnabled = AppDefaults.shared.isTTSEnabled
		let isLoaded = tts.isModelLoaded
		let isLoading = tts.isModelLoading
		let isDownloading = tts.isDownloading

		if isDownloading {
			// Status label is updated live via downloadStatus publisher
			loadModelButton.isEnabled = false
			downloadProgressBar.isHidden = false
		} else if isLoading {
			modelStatusLabel.stringValue = "Loading model…"
			loadModelButton.isEnabled = false
			downloadProgressBar.isHidden = true
		} else if isLoaded {
			modelStatusLabel.stringValue = "Model loaded ✓"
			loadModelButton.title = "Reload Model"
			loadModelButton.isEnabled = isEnabled
			downloadProgressBar.isHidden = true
		} else {
			modelStatusLabel.stringValue = "Model not loaded"
			loadModelButton.title = "Download & Load Model"
			loadModelButton.isEnabled = isEnabled
			downloadProgressBar.isHidden = true
		}

		if let error = tts.modelLoadError {
			modelErrorLabel.stringValue = error
			modelErrorLabel.isHidden = false
		} else {
			modelErrorLabel.isHidden = true
		}

		voicePopup.isEnabled = isEnabled && isLoaded
		speedSlider.isEnabled = isEnabled
		previewButton.isEnabled = isEnabled && isLoaded

		speedValueLabel.stringValue = String(format: "%.1f×", speedSlider.doubleValue)

		updateVoicePopup()
	}

	private func updateVoicePopup() {
		let tts = TTSManager.shared
		let menu = voicePopup.menu!
		menu.removeAllItems()

		for name in tts.voiceNames {
			let displayName = tts.displayNameForVoice(name)
			let item = NSMenuItem(title: "\(displayName) (\(name))", action: nil, keyEquivalent: "")
			item.representedObject = name
			menu.addItem(item)
		}

		if let savedVoice = AppDefaults.shared.ttsSelectedVoice {
			let index = voicePopup.indexOfItem(withRepresentedObject: savedVoice)
			if index >= 0 {
				voicePopup.selectItem(at: index)
			}
		}
	}

	// MARK: - Actions

	@objc private func enableToggled() {
		let isEnabled = enableCheckbox.state == .on
		AppDefaults.shared.isTTSEnabled = isEnabled

		if isEnabled && !TTSManager.shared.isModelLoaded {
			TTSManager.shared.downloadAndLoadModel()
		}

		updateUI()
	}

	@objc private func loadModelTapped() {
		TTSManager.shared.downloadAndLoadModel()
	}

	@objc private func openModelFolderTapped() {
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		let ttsDir = appSupport.appendingPathComponent("NetNewsWire/TTS", isDirectory: true)
		try? FileManager.default.createDirectory(at: ttsDir, withIntermediateDirectories: true)
		NSWorkspace.shared.open(ttsDir)
	}

	@objc private func voiceChanged() {
		guard let voice = voicePopup.selectedItem?.representedObject as? String else {
			return
		}
		AppDefaults.shared.ttsSelectedVoice = voice
		TTSManager.shared.selectedVoice = voice
	}

	@objc private func speedChanged() {
		let speed = Float(speedSlider.doubleValue)
		let roundedSpeed = (speed * 10).rounded() / 10 // Round to 1 decimal
		AppDefaults.shared.ttsSpeechSpeed = roundedSpeed
		TTSManager.shared.speechSpeed = roundedSpeed
		speedValueLabel.stringValue = String(format: "%.1f×", roundedSpeed)
	}

	@objc private func previewTapped() {
		TTSManager.shared.say("Hello, this is a preview of the Kokoro text to speech voice.")
	}
}
