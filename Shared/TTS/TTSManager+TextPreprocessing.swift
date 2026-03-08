//
//  TTSManager+TextPreprocessing.swift
//  NetNewsWire
//
//  Text preprocessing for TTS input.
//

import Foundation

// MARK: - Text Preprocessing

extension TTSManager {

	/// Converts slashes between words to dashes for better speech flow.
	nonisolated func convertSlashesToDashes(_ text: String) -> String {
		let pattern = "(?<=\\p{L})/(?=\\p{L})"
		guard let regex = try? NSRegularExpression(pattern: pattern) else {
			return text
		}
		let range = NSRange(text.startIndex..., in: text)
		return regex.stringByReplacingMatches(in: text, range: range, withTemplate: " - ")
	}

	/// Removes hyphens from compound words to improve speech synthesis.
	nonisolated func removeHyphensFromCompoundWords(_ text: String) -> String {
		let pattern = "(?<=\\p{L})-(?=\\p{L})"
		guard let regex = try? NSRegularExpression(pattern: pattern) else {
			return text
		}
		let range = NSRange(text.startIndex..., in: text)
		return regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
	}

	/// Converts parenthetical phrases to use dashes for better speech flow.
	nonisolated func convertParentheticalsToDashes(_ text: String) -> String {
		var result = text
		let pattern = "\\(([^)]+)\\)([.,;:!?]?)(?=(\\s+\\w|\\s*$))"
		guard let regex = try? NSRegularExpression(pattern: pattern) else {
			return text
		}

		let range = NSRange(result.startIndex..., in: result)
		let matches = regex.matches(in: result, range: range)

		for match in matches.reversed() {
			guard let contentRange = Range(match.range(at: 1), in: result),
				  let fullRange = Range(match.range, in: result) else {
				continue
			}

			let content = String(result[contentRange])
			let punctuation = match.range(at: 2).length > 0
				? String(result[Range(match.range(at: 2), in: result)!])
				: ""

			let followedByMoreText = match.range(at: 3).length > 0 &&
				Range(match.range(at: 3), in: result).map { !result[$0].trimmingCharacters(in: .whitespaces).isEmpty } ?? false

			let replacement: String
			if punctuation.isEmpty && followedByMoreText {
				replacement = "- \(content) -"
			} else {
				replacement = "- \(content)\(punctuation)"
			}

			result.replaceSubrange(fullRange, with: replacement)
		}

		return result
	}

	private nonisolated static let maxChunkCharacterLength = 450

	/// Splits text into chunks of sentences for processing within token limits.
	nonisolated func splitIntoChunks(_ text: String, sentencesPerChunk: Int = 2) -> [String] {
		let paragraphs = text.components(separatedBy: .newlines)

		var sections: [String] = []
		var currentSection: [String] = []
		var previousLineEmpty = false

		for line in paragraphs {
			let trimmedLine = line.trimmingCharacters(in: .whitespaces)

			if trimmedLine.isEmpty {
				if !currentSection.isEmpty {
					if currentSection.count == 1 && !previousLineEmpty {
						sections.append(currentSection[0])
						currentSection = []
					}
				}
				previousLineEmpty = true
			} else {
				if previousLineEmpty && !currentSection.isEmpty {
					sections.append(currentSection.joined(separator: " "))
					currentSection = []
				}
				currentSection.append(trimmedLine)
				previousLineEmpty = false
			}
		}

		if !currentSection.isEmpty {
			sections.append(currentSection.joined(separator: " "))
		}

		var chunks: [String] = []

		for section in sections {
			// ICU lookbehinds require fixed length — use alternation instead of `?`
			let pattern = "(?<=[.!?]|[.!?][\"\\u{201C}\\u{201D}])\\s+"
			guard let regex = try? NSRegularExpression(pattern: pattern) else {
				chunks.append(section)
				continue
			}
			let range = NSRange(section.startIndex..., in: section)

			var sentences: [String] = []
			var lastEnd = section.startIndex

			regex.enumerateMatches(in: section, range: range) { match, _, _ in
				if let match {
					let matchRange = Range(match.range, in: section)!
					let sentence = String(section[lastEnd..<matchRange.lowerBound])
					let trimmed = sentence.trimmingCharacters(in: .whitespaces)
					if !trimmed.isEmpty {
						sentences.append(trimmed)
					}
					lastEnd = matchRange.upperBound
				}
			}

			let remaining = String(section[lastEnd...]).trimmingCharacters(in: .whitespaces)
			if !remaining.isEmpty {
				sentences.append(remaining)
			}

			for i in stride(from: 0, to: sentences.count, by: sentencesPerChunk) {
				let end = min(i + sentencesPerChunk, sentences.count)
				let chunk = sentences[i..<end].joined(separator: " ")
				if !chunk.isEmpty {
					if chunk.count > Self.maxChunkCharacterLength {
						for j in i..<end {
							let subChunks = splitLongSentence(sentences[j])
							chunks.append(contentsOf: subChunks)
						}
					} else {
						chunks.append(chunk)
					}
				}
			}
		}

		return chunks.isEmpty ? [text.replacingOccurrences(of: "\n", with: " ")] : chunks
	}

	/// Splits a long sentence at clause boundaries.
	nonisolated func splitLongSentence(_ sentence: String) -> [String] {
		let maxLen = Self.maxChunkCharacterLength
		if sentence.count <= maxLen {
			return [sentence]
		}

		let clauseDelimiters = [
			"(?<=;)\\s+",
			"(?<=,)\\s+",
			"(?<=:)\\s+",
			"\\s+(?=\\b(?:and|but|or|yet|so|which|that|because|although|while|when|where|if)\\b)"
		]

		for pattern in clauseDelimiters {
			let parts = splitByPattern(sentence, pattern: pattern)
			if parts.count > 1 {
				let subChunks = recombineParts(parts, maxLength: maxLen)
				return subChunks.flatMap { splitLongSentence($0) }
			}
		}

		let mid = sentence.index(sentence.startIndex, offsetBy: sentence.count / 2)
		if let spaceRange = sentence.rangeOfCharacter(from: .whitespaces, range: mid..<sentence.endIndex) ??
			sentence.rangeOfCharacter(from: .whitespaces, options: .backwards, range: sentence.startIndex..<mid) {
			let first = String(sentence[sentence.startIndex..<spaceRange.lowerBound]).trimmingCharacters(in: .whitespaces)
			let second = String(sentence[spaceRange.upperBound...]).trimmingCharacters(in: .whitespaces)
			var result: [String] = []
			if !first.isEmpty { result.append(contentsOf: splitLongSentence(first)) }
			if !second.isEmpty { result.append(contentsOf: splitLongSentence(second)) }
			return result
		}

		return [sentence]
	}

	private nonisolated func splitByPattern(_ text: String, pattern: String) -> [String] {
		guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
		let range = NSRange(text.startIndex..., in: text)
		var parts: [String] = []
		var lastEnd = text.startIndex

		regex.enumerateMatches(in: text, range: range) { match, _, _ in
			if let match, let matchRange = Range(match.range, in: text) {
				let part = String(text[lastEnd..<matchRange.lowerBound]).trimmingCharacters(in: .whitespaces)
				if !part.isEmpty {
					parts.append(part)
				}
				lastEnd = matchRange.upperBound
			}
		}

		let remaining = String(text[lastEnd...]).trimmingCharacters(in: .whitespaces)
		if !remaining.isEmpty {
			parts.append(remaining)
		}
		return parts
	}

	private nonisolated func recombineParts(_ parts: [String], maxLength: Int) -> [String] {
		var chunks: [String] = []
		var current = ""
		for part in parts {
			let combined = current.isEmpty ? part : current + " " + part
			if combined.count > maxLength && !current.isEmpty {
				chunks.append(current)
				current = part
			} else {
				current = combined
			}
		}
		if !current.isEmpty {
			chunks.append(current)
		}
		return chunks
	}
}
