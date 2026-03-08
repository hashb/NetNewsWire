//
//  DetailContainerView.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 2/12/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import AppKit

final class DetailContainerView: NSView {

	@IBOutlet var detailStatusBarView: DetailStatusBarView!

	var contentViewConstraints: [NSLayoutConstraint]?

	// MARK: - TTS Controls

	private(set) var ttsControlsView: TTSControlsView?
	private var ttsControlsConstraints: [NSLayoutConstraint]?

	var isTTSControlsVisible: Bool {
		return ttsControlsView != nil
	}

	func showTTSControls() {
		guard ttsControlsView == nil else { return }

		let controls = TTSControlsView()
		controls.translatesAutoresizingMaskIntoConstraints = false
		addSubview(controls, positioned: .below, relativeTo: detailStatusBarView)
		ttsControlsView = controls

		let constraints = [
			controls.bottomAnchor.constraint(equalTo: bottomAnchor),
			controls.leadingAnchor.constraint(equalTo: leadingAnchor),
			controls.trailingAnchor.constraint(equalTo: trailingAnchor)
		]
		NSLayoutConstraint.activate(constraints)
		ttsControlsConstraints = constraints

		relayoutContentView()
	}

	func hideTTSControls() {
		guard let controls = ttsControlsView else { return }

		if let constraints = ttsControlsConstraints {
			NSLayoutConstraint.deactivate(constraints)
		}
		ttsControlsConstraints = nil
		controls.removeFromSuperview()
		ttsControlsView = nil

		relayoutContentView()
	}

	// MARK: - Content View

	var contentView: NSView? {
		didSet {
			if contentView == oldValue {
				return
			}

			if let currentConstraints = contentViewConstraints {
				NSLayoutConstraint.deactivate(currentConstraints)
			}
			contentViewConstraints = nil
			oldValue?.removeFromSuperviewWithoutNeedingDisplay()

			if let contentView {
				contentView.translatesAutoresizingMaskIntoConstraints = false
				addSubview(contentView, positioned: .below, relativeTo: detailStatusBarView)
				relayoutContentView()
			}
		}
	}

	private func relayoutContentView() {
		guard let contentView else { return }

		if let currentConstraints = contentViewConstraints {
			NSLayoutConstraint.deactivate(currentConstraints)
		}

		var constraints: [NSLayoutConstraint]

		if let ttsControlsView {
			constraints = [
				contentView.topAnchor.constraint(equalTo: topAnchor),
				contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
				contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
				contentView.bottomAnchor.constraint(equalTo: ttsControlsView.topAnchor)
			]
		} else {
			constraints = constraintsToMakeSubViewFullSize(contentView)
		}

		NSLayoutConstraint.activate(constraints)
		contentViewConstraints = constraints
	}

	override func draw(_ dirtyRect: NSRect) {
		NSColor.controlBackgroundColor.set()
		let r = dirtyRect.intersection(bounds)
		r.fill()
	}
}
