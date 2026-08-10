import Foundation

enum WhisperTranscriptDecoder {
    private struct Output: Decodable {
        struct Segment: Decodable {
            struct Offsets: Decodable {
                var from: Int
                var to: Int
            }

            struct Token: Decodable {
                var p: Double?
            }

            var offsets: Offsets?
            var text: String
            var tokens: [Token]?
        }

        var transcription: [Segment]
    }

    static func decodeRichJSON(_ data: Data) -> RawTranscript? {
        guard let output = try? JSONDecoder().decode(Output.self, from: data) else {
            return nil
        }

        var segments: [TranscriptSegment] = []
        var transcriptParts: [String] = []
        var tokenConfidences: [Double] = []

        for item in output.transcription {
            let segmentText = WhisperCLITranscriptionEngine.stripArtifacts(item.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let confidences = item.tokens?.compactMap(\.p) ?? []
            let segmentConfidence = confidences.isEmpty
                ? nil
                : confidences.reduce(0, +) / Double(confidences.count)
            tokenConfidences.append(contentsOf: confidences)

            let startMS = item.offsets?.from ?? 0
            let endMS = item.offsets?.to ?? startMS

            if !segmentText.isEmpty {
                transcriptParts.append(segmentText)
                segments.append(
                    TranscriptSegment(
                        startMS: startMS,
                        endMS: endMS,
                        text: segmentText,
                        confidence: segmentConfidence
                    )
                )
            }
        }

        let text = transcriptParts.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let durationMS = segments.map(\.endMS).max() ?? 0
        let avgConfidence = tokenConfidences.isEmpty
            ? nil
            : tokenConfidences.reduce(0, +) / Double(tokenConfidences.count)

        return RawTranscript(
            text: text,
            segments: segments,
            avgConfidence: avgConfidence,
            durationMS: durationMS
        )
    }
}
