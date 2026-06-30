//
//  ArticleSpeechControlsView.swift
//  NetNewsWire
//
//  Created by NetNewsWire contributors on 4/30/26.
//  Copyright © 2026 Ranchero Software, LLC. All rights reserved.
//

import AppKit
import QuartzCore

@MainActor final class ArticleSpeechControlsView: NSVisualEffectView {

	var playPauseAction: (() -> Void)?
	var rewindAction: (() -> Void)?
	var forwardAction: (() -> Void)?
	var syncAction: (() -> Void)?
	var scrubAction: ((TimeInterval) -> Void)?

	private let playPauseButton = ArticleSpeechButton()
	private let rewindButton = ArticleSpeechButton()
	private let forwardButton = ArticleSpeechButton()
	private let syncButton = ArticleSpeechButton()
	private let positionSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
	private let elapsedLabel = ArticleSpeechLabel("0:00")
	private let durationLabel = ArticleSpeechLabel("0:00")
	private let statusLabel = ArticleSpeechLabel("")
	private let progressIndicator = NSProgressIndicator()

	private static let fadeDelay: Duration = .seconds(5)
	private var isPlaybackActive = false
	private var isUpdatingSlider = false
	private var fadeTask: Task<Void, Never>?
	private var hidePanelTask: Task<Void, Never>?
	private var mouseEventMonitor: Any?

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		configureView()
		configureControls()
		buildLayout()
		update(isPlaying: false, isBusy: false, position: 0, duration: 0, status: nil, followsHighlight: true)
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		configureView()
		configureControls()
		buildLayout()
		update(isPlaying: false, isBusy: false, position: 0, duration: 0, status: nil, followsHighlight: true)
	}

	override func viewWillMove(toWindow newWindow: NSWindow?) {
		if newWindow == nil {
			cancelFadeTask()
			removeMouseEventMonitor()
		}
		super.viewWillMove(toWindow: newWindow)
	}

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		window?.acceptsMouseMovedEvents = true
		installMouseEventMonitor()
		scheduleFadeIfPointerOutside()
	}

	override func resetCursorRects() {
		super.resetCursorRects()
		addCursorRect(bounds, cursor: .arrow)
	}

	func setPlaybackActive(_ active: Bool) {
		guard isPlaybackActive != active else {
			return
		}

		isPlaybackActive = active
		cancelFadeTask()

		if active {
			showPanel(animated: false)
			scheduleFadeIfPointerOutside()
		} else {
			hidePanel(animated: false)
		}
	}

	func update(isPlaying: Bool, isBusy: Bool, position: TimeInterval, duration: TimeInterval, status: String?, followsHighlight: Bool) {
		playPauseButton.image = symbol(isPlaying ? "pause.fill" : "play.fill", description: isPlaying ? "Pause" : "Play")
		playPauseButton.isEnabled = !isBusy && duration > 0
		rewindButton.isEnabled = !isBusy && duration > 0
		forwardButton.isEnabled = !isBusy && duration > 0
		syncButton.isEnabled = !isBusy && duration > 0
		syncButton.contentTintColor = followsHighlight ? .secondaryLabelColor : .controlAccentColor
		syncButton.toolTip = followsHighlight ? NSLocalizedString("Following Spoken Text", comment: "Article speech sync button tooltip") : NSLocalizedString("Sync to Spoken Text", comment: "Article speech sync button tooltip")
		positionSlider.isEnabled = !isBusy && duration > 0

		let clampedDuration = max(duration, 0)
		let clampedPosition = min(max(position, 0), clampedDuration)
		isUpdatingSlider = true
		positionSlider.maxValue = max(clampedDuration, 1)
		positionSlider.doubleValue = clampedPosition
		isUpdatingSlider = false

		elapsedLabel.stringValue = Self.formattedTime(clampedPosition)
		durationLabel.stringValue = Self.formattedTime(clampedDuration)

		if let status, !status.isEmpty {
			statusLabel.stringValue = status
			statusLabel.isHidden = false
			progressIndicator.isHidden = !isBusy
			if isBusy {
				progressIndicator.startAnimation(nil)
			}
		} else {
			statusLabel.stringValue = ""
			statusLabel.isHidden = true
			progressIndicator.stopAnimation(nil)
			progressIndicator.isHidden = true
		}
	}
}

private extension ArticleSpeechControlsView {

	func configureView() {
		material = .hudWindow
		blendingMode = .withinWindow
		state = .active
		wantsLayer = true
		layer?.cornerRadius = 13
		layer?.masksToBounds = true
		isHidden = true
	}

	func configureControls() {
		configureButton(rewindButton, symbolName: "gobackward.10", description: "Rewind 10 Seconds", action: #selector(rewind(_:)))
		configureButton(playPauseButton, symbolName: "play.fill", description: "Play", action: #selector(playPause(_:)))
		configureButton(forwardButton, symbolName: "goforward.10", description: "Forward 10 Seconds", action: #selector(forward(_:)))
		configureButton(syncButton, symbolName: "scope", description: "Sync to Spoken Text", action: #selector(sync(_:)))

		positionSlider.target = self
		positionSlider.action = #selector(sliderChanged(_:))
		positionSlider.isContinuous = true
		positionSlider.controlSize = .small

		for label in [elapsedLabel, durationLabel, statusLabel] {
			label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
			label.textColor = .secondaryLabelColor
			label.lineBreakMode = .byTruncatingTail
		}

		progressIndicator.style = .spinning
		progressIndicator.controlSize = .small
		progressIndicator.isDisplayedWhenStopped = false
	}

	func configureButton(_ button: NSButton, symbolName: String, description: String, action: Selector) {
		button.bezelStyle = .regularSquare
		button.isBordered = false
		button.image = symbol(symbolName, description: description)
		button.imageScaling = .scaleProportionallyDown
		button.target = self
		button.action = action
		button.toolTip = description
		button.setAccessibilityLabel(description)
		button.translatesAutoresizingMaskIntoConstraints = false
		NSLayoutConstraint.activate([
			button.widthAnchor.constraint(equalToConstant: 30),
			button.heightAnchor.constraint(equalToConstant: 26)
		])
	}

	func buildLayout() {
		let transportStack = NSStackView(views: [rewindButton, playPauseButton, forwardButton, syncButton])
		transportStack.orientation = .horizontal
		transportStack.alignment = .centerY
		transportStack.spacing = 6

		let sliderStack = NSStackView(views: [elapsedLabel, positionSlider, durationLabel])
		sliderStack.orientation = .horizontal
		sliderStack.alignment = .centerY
		sliderStack.spacing = 8
		positionSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
		positionSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

		let statusStack = NSStackView(views: [progressIndicator, statusLabel])
		statusStack.orientation = .horizontal
		statusStack.alignment = .centerY
		statusStack.spacing = 6

		let stack = NSStackView(views: [transportStack, sliderStack, statusStack])
		stack.orientation = .horizontal
		stack.alignment = .centerY
		stack.spacing = 12
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)

		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
			stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
		])
	}

	func symbol(_ name: String, description: String) -> NSImage? {
		NSImage(systemSymbolName: name, accessibilityDescription: description)
	}

	@objc func playPause(_ sender: Any?) {
		playPauseAction?()
	}

	@objc func rewind(_ sender: Any?) {
		rewindAction?()
	}

	@objc func forward(_ sender: Any?) {
		forwardAction?()
	}

	@objc func sync(_ sender: Any?) {
		syncAction?()
	}

	@objc func sliderChanged(_ sender: Any?) {
		guard !isUpdatingSlider else {
			return
		}
		scrubAction?(positionSlider.doubleValue)
	}

	func installMouseEventMonitor() {
		guard mouseEventMonitor == nil else {
			return
		}

		mouseEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]) { [weak self] event in
			MainActor.assumeIsolated {
				self?.handlePointerEvent(event)
			}
			return event
		}
	}

	func removeMouseEventMonitor() {
		if let mouseEventMonitor {
			NSEvent.removeMonitor(mouseEventMonitor)
			self.mouseEventMonitor = nil
		}
	}

	func handlePointerEvent(_ event: NSEvent) {
		guard let eventWindow = event.window, isPlaybackActive, eventWindow === window else {
			return
		}

		if containsPointerInPanel(event.locationInWindow) {
			NSCursor.arrow.set()
		}

		if containsPointerInExpandedHitbox(event.locationInWindow) {
			cancelFadeTask()
			showPanel(animated: true)
		} else {
			scheduleFadeIfPointerOutside()
		}
	}

	func scheduleFadeIfPointerOutside() {
		guard isPlaybackActive, fadeTask == nil, !isPointerInsideExpandedHitbox() else {
			return
		}

		fadeTask = Task { @MainActor [weak self] in
			try? await Task.sleep(for: Self.fadeDelay)
			guard let self, !Task.isCancelled else {
				return
			}
			self.fadeTask = nil
			guard self.isPlaybackActive, !self.isPointerInsideExpandedHitbox() else {
				return
			}
			self.hidePanel(animated: true)
		}
	}

	func cancelFadeTask() {
		fadeTask?.cancel()
		fadeTask = nil
	}

	func isPointerInsideExpandedHitbox() -> Bool {
		guard let window else {
			return false
		}
		return containsPointerInExpandedHitbox(window.mouseLocationOutsideOfEventStream)
	}

	func containsPointerInPanel(_ locationInWindow: NSPoint) -> Bool {
		let point = convert(locationInWindow, from: nil)
		return bounds.contains(point)
	}

	func containsPointerInExpandedHitbox(_ locationInWindow: NSPoint) -> Bool {
		let point = convert(locationInWindow, from: nil)
		return bounds.insetBy(dx: -bounds.width / 2, dy: -bounds.height / 2).contains(point)
	}

	func showPanel(animated: Bool) {
		isHidden = false
		animateAlpha(to: 1, animated: animated)
	}

	func hidePanel(animated: Bool) {
		cancelFadeTask()
		hidePanelTask?.cancel()
		hidePanelTask = nil
		animateAlpha(to: 0, animated: animated)
		guard animated else {
			isHidden = true
			return
		}

		hidePanelTask = Task { @MainActor [weak self] in
			try? await Task.sleep(for: .milliseconds(220))
			guard let self, !Task.isCancelled, self.alphaValue == 0 else {
				return
			}
			self.hidePanelTask = nil
			self.isHidden = true
		}
	}

	func animateAlpha(to alpha: CGFloat, animated: Bool) {
		guard animated else {
			alphaValue = alpha
			return
		}

		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.18
			context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
			animator().alphaValue = alpha
		}
	}

	static func formattedTime(_ time: TimeInterval) -> String {
		guard time.isFinite, time > 0 else {
			return "0:00"
		}

		let seconds = Int(time.rounded())
		let hours = seconds / 3600
		let minutes = (seconds % 3600) / 60
		let remainingSeconds = seconds % 60

		if hours > 0 {
			return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
		}
		return String(format: "%d:%02d", minutes, remainingSeconds)
	}
}

@MainActor private final class ArticleSpeechButton: NSButton {

	private var trackingArea: NSTrackingArea?
	private var isHovering = false {
		didSet {
			updateAppearance()
		}
	}
	private var isPressing = false {
		didSet {
			updateAppearance()
		}
	}

	override var isEnabled: Bool {
		didSet {
			updateAppearance()
		}
	}

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		configureAppearance()
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		configureAppearance()
	}

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let trackingArea {
			removeTrackingArea(trackingArea)
		}

		let trackingArea = NSTrackingArea(
			rect: bounds,
			options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
			owner: self,
			userInfo: nil)
		addTrackingArea(trackingArea)
		self.trackingArea = trackingArea
	}

	override func resetCursorRects() {
		super.resetCursorRects()
		addCursorRect(bounds, cursor: .arrow)
	}

	override func cursorUpdate(with event: NSEvent) {
		NSCursor.arrow.set()
	}

	override func mouseEntered(with event: NSEvent) {
		isHovering = true
		NSCursor.arrow.set()
	}

	override func mouseExited(with event: NSEvent) {
		isHovering = false
	}

	override func mouseDown(with event: NSEvent) {
		isPressing = true
		super.mouseDown(with: event)
		isPressing = false
	}

	private func configureAppearance() {
		wantsLayer = true
		layer?.cornerRadius = 7
		layer?.masksToBounds = true
		focusRingType = .none
		imagePosition = .imageOnly
		updateAppearance()
	}

	private func updateAppearance() {
		let alpha: CGFloat
		if !isEnabled {
			alpha = 0
		} else if isPressing {
			alpha = 0.22
		} else if isHovering {
			alpha = 0.12
		} else {
			alpha = 0
		}
		layer?.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
	}
}

@MainActor private final class ArticleSpeechLabel: NSTextField {

	init(_ string: String) {
		super.init(frame: .zero)
		stringValue = string
		configure()
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		configure()
	}

	override func resetCursorRects() {
		super.resetCursorRects()
		addCursorRect(bounds, cursor: .arrow)
	}

	override func cursorUpdate(with event: NSEvent) {
		NSCursor.arrow.set()
	}

	private func configure() {
		isEditable = false
		isSelectable = false
		isBordered = false
		drawsBackground = false
		focusRingType = .none
	}
}
