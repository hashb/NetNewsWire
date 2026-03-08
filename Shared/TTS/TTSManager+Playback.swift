//
//  TTSManager+Playback.swift
//  NetNewsWire
//
//  Playback controls for the TTS manager.
//

import AVFoundation
import Foundation

// MARK: - Playback Controls

extension TTSManager {

	/// Pauses playback.
	func pause() {
		guard isPlaying else { return }
		playerNode?.pause()
		isPlaying = false
		if let startTime = playbackStartTime {
			playbackStartPosition += Date().timeIntervalSince(startTime)
		}
		playbackStartTime = nil
		updateNowPlayingInfo()
	}

	/// Resumes playback from current position, or restarts if at the end.
	func resume() {
		guard hasAudio, !isPlaying, !audioSamples.isEmpty, let format = audioFormat, let playerNode else { return }

		let position = currentTime >= totalDuration ? 0.0 : currentTime

		let sampleRate = format.sampleRate
		let targetSample = Int(position * sampleRate)
		let clampedSample = max(0, min(targetSample, audioSamples.count))

		playerNode.stop()
		timer?.invalidate()

		let remainingSamples = Array(audioSamples[clampedSample...])
		guard let buffer = createBuffer(from: remainingSamples, format: format) else { return }

		playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
		playerNode.play()

		currentTime = Double(clampedSample) / sampleRate
		playbackStartPosition = currentTime
		playbackStartTime = Date()
		isPlaying = true

		updateNowPlayingInfo()
		startPlaybackTimer()
	}

	/// Toggles between play and pause.
	func togglePlayPause() {
		if isPlaying {
			pause()
		} else {
			resume()
		}
	}

	/// Stops playback and resets all state.
	func stop() {
		timer?.invalidate()
		timer = nil
		playerNode?.stop()
		audioEngine?.stop()
		isPlaying = false
		hasAudio = false
		currentTime = 0.0
		totalDuration = 0.0
		playbackStartPosition = 0.0
		playbackStartTime = nil
		audioSamples = []
		allTokens = []
		currentTokenIndex = -1
		shouldCancelGeneration = true
		isGeneratingAudio = false
		updateNowPlayingInfo()
		delegate?.ttsDidStopPlaying()
	}

	/// Seeks forward by 10 seconds.
	func seekForward10s() {
		seek(to: min(currentTime + 10, totalDuration))
	}

	/// Seeks backward by 10 seconds.
	func seekBackward10s() {
		seek(to: max(currentTime - 10, 0))
	}

	/// Seeks to a specific position in seconds.
	func seek(to time: Double) {
		guard hasAudio, !audioSamples.isEmpty, let format = audioFormat, let playerNode else { return }

		let wasPlaying = isPlaying

		let sampleRate = format.sampleRate
		let targetSample = Int(time * sampleRate)
		let clampedSample = max(0, min(targetSample, audioSamples.count))

		playerNode.stop()
		timer?.invalidate()

		let remainingSamples = Array(audioSamples[clampedSample...])
		guard let buffer = createBuffer(from: remainingSamples, format: format) else { return }

		playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)

		currentTime = Double(clampedSample) / sampleRate
		playbackStartPosition = currentTime

		if wasPlaying {
			playerNode.play()
			playbackStartTime = Date()
			isPlaying = true
			startPlaybackTimer()
		} else {
			playbackStartTime = nil
			isPlaying = false
		}

		updateNowPlayingInfo()
	}

	/// Starts the timer that updates playback position and follow-along text.
	func startPlaybackTimer() {
		timer?.invalidate()

		timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }

				if self.isPlaying, let startTime = self.playbackStartTime {
					self.currentTime = self.playbackStartPosition + Date().timeIntervalSince(startTime)
				}

				if self.currentTime >= self.totalDuration && !self.isGeneratingAudio {
					self.currentTime = self.totalDuration
					self.isPlaying = false
					self.playbackStartTime = nil
					self.updateNowPlayingInfo()
					self.timer?.invalidate()
					return
				}

				self.updateFollowAlongText()
			}
		}
	}

	/// Updates the current word-span index based on playback position.
	/// Only counts tokens that contain at least one letter so the index aligns
	/// with the word spans created by ttsPrepareHighlighting() in the web view.
	func updateFollowAlongText() {
		var newWordIndex = -1
		var wordSpanIdx = 0

		for token in allTokens {
			guard token.text.contains(where: { $0.isLetter }) else {
				continue
			}

			if let start = token.start_ts, start <= currentTime {
				newWordIndex = wordSpanIdx
			}

			wordSpanIdx += 1
		}

		currentTokenIndex = newWordIndex
	}
}
