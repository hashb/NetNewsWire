//
//  TTSManager+AudioHelpers.swift
//  NetNewsWire
//
//  Audio buffer creation helpers for TTS.
//

import AVFoundation
import Foundation

// MARK: - Audio Helpers

extension TTSManager {

	/// Creates an audio buffer from audio samples.
	func createBuffer(from audio: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
		guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count)) else {
			print("TTS: Couldn't create buffer")
			return nil
		}

		buffer.frameLength = buffer.frameCapacity
		let channels = buffer.floatChannelData!
		let dst: UnsafeMutablePointer<Float> = channels[0]

		audio.withUnsafeBufferPointer { buf in
			precondition(buf.baseAddress != nil)
			let byteCount = buf.count * MemoryLayout<Float>.stride
			UnsafeMutableRawPointer(dst)
				.copyMemory(from: UnsafeRawPointer(buf.baseAddress!), byteCount: byteCount)
		}

		return buffer
	}
}
