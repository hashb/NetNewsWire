//
//  TTSManager+MediaControls.swift
//  NetNewsWire
//
//  Media key controls for TTS playback.
//

import Foundation
import MediaPlayer

// MARK: - Media Controls

extension TTSManager {

	/// Sets up the remote command center to handle media keys.
	func setupRemoteCommandCenter() {
		let commandCenter = MPRemoteCommandCenter.shared()

		commandCenter.playCommand.isEnabled = true
		commandCenter.playCommand.addTarget { [weak self] _ in
			guard let self, self.hasAudio else { return .commandFailed }
			DispatchQueue.main.async {
				self.resume()
			}
			return .success
		}

		commandCenter.pauseCommand.isEnabled = true
		commandCenter.pauseCommand.addTarget { [weak self] _ in
			guard let self else { return .commandFailed }
			DispatchQueue.main.async {
				self.pause()
			}
			return .success
		}

		commandCenter.togglePlayPauseCommand.isEnabled = true
		commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
			guard let self else { return .commandFailed }
			DispatchQueue.main.async {
				self.togglePlayPause()
			}
			return .success
		}

		commandCenter.skipForwardCommand.isEnabled = true
		commandCenter.skipForwardCommand.preferredIntervals = [10]
		commandCenter.skipForwardCommand.addTarget { [weak self] _ in
			guard let self, self.hasAudio else { return .commandFailed }
			DispatchQueue.main.async {
				self.seekForward10s()
			}
			return .success
		}

		commandCenter.skipBackwardCommand.isEnabled = true
		commandCenter.skipBackwardCommand.preferredIntervals = [10]
		commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
			guard let self, self.hasAudio else { return .commandFailed }
			DispatchQueue.main.async {
				self.seekBackward10s()
			}
			return .success
		}

		commandCenter.changePlaybackPositionCommand.isEnabled = true
		commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
			guard let self,
				  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
				return .commandFailed
			}
			DispatchQueue.main.async {
				self.seek(to: positionEvent.positionTime)
			}
			return .success
		}
	}

	/// Updates the Now Playing info center.
	func updateNowPlayingInfo() {
		let infoCenter = MPNowPlayingInfoCenter.default()

		if isPlaying {
			infoCenter.playbackState = .playing
		} else if hasAudio {
			infoCenter.playbackState = .paused
		} else {
			infoCenter.playbackState = .stopped
		}

		var nowPlayingInfo = [String: Any]()

		nowPlayingInfo[MPMediaItemPropertyTitle] = "NetNewsWire TTS"
		nowPlayingInfo[MPMediaItemPropertyArtist] = displayNameForVoice(selectedVoice)
		nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
		nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = totalDuration
		nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

		infoCenter.nowPlayingInfo = nowPlayingInfo
	}
}
