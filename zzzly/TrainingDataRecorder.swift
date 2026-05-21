import Foundation

final class TrainingDataRecorder: @unchecked Sendable {
    struct Segment {
        var probability: Float
        var nonSnoreProbability: Float
        var snoreProbability: Float
        var probabilitySum: Float
        var isSnoring: Bool
        var db: Float
        var dbRelative: Float
        var noiseFloorDb: Float
        var zeroCrossingRate: Double
        var sourceSampleRate: Double
        var windowIndex: Int
        var secondsFromStart: Double
        var snoreIndexUsed: Int
        var candidateRuleVersion: String
        var normalizedSamples: [Float]
    }

    static let shared = TrainingDataRecorder()

    private let queue = DispatchQueue(label: "zzzly.training-recorder")
    private let rootDirectoryName = "zzzly-training"
    private let maximumSavedSegments = 60_000
    private let maximumSavedAudioSegments = 900

    private var sessionDirectory: URL?
    private var manifestURL: URL?
    private var audioDirectory: URL?
    private var sessionStartedAt: Date?
    private var savedSegments = 0
    private var savedAudioSegments = 0

    var isEnabled: Bool {
        true
    }

    func beginNight(startedAt: Date) {
        guard isEnabled else { return }

        queue.async {
            do {
                let documents = try FileManager.default.url(
                    for: .documentDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let root = documents.appendingPathComponent(self.rootDirectoryName, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

                let directory = root.appendingPathComponent(Self.sessionName(for: startedAt), isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let audioDirectory = directory.appendingPathComponent("segments", isDirectory: true)
                try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

                let manifest = directory.appendingPathComponent("manifest.csv")
                let header = "session_start,window_index,seconds_from_start,probability,p_non_snore,p_snore,p_sum,is_snore,db,db_relative,noise_floor_db,zero_crossing_rate,source_sample_rate,snore_index_used,candidate_rule_version,audio_file\n"
                try header.write(to: manifest, atomically: true, encoding: .utf8)

                let info = """
                {
                  "purpose": "zzzly local inference capture",
                  "format": "csv inference rows plus suspicious 1-second wav clips",
                  "policy": "save every 1-second inference row; save wav only when snore or near-threshold audio is detected",
                  "audio_policy": "wav saved when is_snore=1 or p_snore>=0.35 and db_relative>=8, capped at 900 clips per night",
                  "snore_index_used": 1,
                  "candidate_rule_version": "p1-relative-db-v1",
                  "session_start": "\(Self.isoString(startedAt))"
                }
                """
                try info.write(to: directory.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)

                self.sessionDirectory = directory
                self.manifestURL = manifest
                self.audioDirectory = audioDirectory
                self.sessionStartedAt = startedAt
                self.savedSegments = 0
                self.savedAudioSegments = 0
            } catch {
                self.sessionDirectory = nil
                self.manifestURL = nil
                self.audioDirectory = nil
                self.sessionStartedAt = nil
                self.savedSegments = 0
                self.savedAudioSegments = 0
            }
        }
    }

    func record(_ segment: Segment) {
        guard isEnabled else { return }

        queue.async {
            guard self.savedSegments < self.maximumSavedSegments,
                  let manifestURL = self.manifestURL,
                  let sessionStartedAt = self.sessionStartedAt else {
                return
            }

            do {
                let audioFilename = self.saveAudioIfNeeded(segment)
                let line = [
                    Self.isoString(sessionStartedAt),
                    "\(segment.windowIndex)",
                    String(format: "%.3f", segment.secondsFromStart),
                    String(format: "%.5f", segment.probability),
                    String(format: "%.5f", segment.nonSnoreProbability),
                    String(format: "%.5f", segment.snoreProbability),
                    String(format: "%.5f", segment.probabilitySum),
                    segment.isSnoring ? "1" : "0",
                    String(format: "%.2f", segment.db),
                    String(format: "%.2f", segment.dbRelative),
                    String(format: "%.2f", segment.noiseFloorDb),
                    String(format: "%.5f", segment.zeroCrossingRate),
                    String(format: "%.1f", segment.sourceSampleRate),
                    "\(segment.snoreIndexUsed)",
                    segment.candidateRuleVersion,
                    audioFilename
                ].joined(separator: ",") + "\n"

                if let data = line.data(using: .utf8),
                   let handle = try? FileHandle(forWritingTo: manifestURL) {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                }

                self.savedSegments += 1
            } catch {
                return
            }
        }
    }

    func finishNight(result: SnoreResult) {
        guard isEnabled else { return }

        queue.async {
            guard let sessionDirectory = self.sessionDirectory else { return }

            let summary = """
            {
              "checked_at": "\(Self.isoString(result.checkedAt))",
              "verdict": "\(result.verdict.rawValue)",
              "snore_ratio": \(result.snoreRatio),
              "estimated_snore_seconds": \(result.estimatedSnoreSeconds ?? 0),
              "recorded_seconds": \(result.recordedSeconds ?? 0),
              "saved_segments": \(self.savedSegments),
              "saved_audio_segments": \(self.savedAudioSegments)
            }
            """
            try? summary.write(to: sessionDirectory.appendingPathComponent("result.json"), atomically: true, encoding: .utf8)
            self.sessionDirectory = nil
            self.manifestURL = nil
            self.audioDirectory = nil
            self.sessionStartedAt = nil
        }
    }

    private func saveAudioIfNeeded(_ segment: Segment) -> String {
        guard savedAudioSegments < maximumSavedAudioSegments,
              shouldSaveAudio(segment),
              let audioDirectory,
              !segment.normalizedSamples.isEmpty else {
            return ""
        }

        let filename = String(
            format: "w_%06d_p%03d_db%04d.wav",
            segment.windowIndex,
            Int((segment.probability * 100).rounded()),
            Int(abs(segment.db).rounded())
        )
        let url = audioDirectory.appendingPathComponent(filename)

        do {
            let data = Self.wavData(samples: segment.normalizedSamples, sampleRate: 16_000)
            try data.write(to: url, options: .atomic)
            savedAudioSegments += 1
            return "segments/\(filename)"
        } catch {
            return ""
        }
    }

    private func shouldSaveAudio(_ segment: Segment) -> Bool {
        segment.isSnoring || (segment.snoreProbability >= 0.35 && segment.dbRelative >= 8 && segment.db > -72)
    }

    private static func sessionName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func wavData(samples: [Float], sampleRate: Int) -> Data {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = Int(bitsPerSample / 8)
        let byteRate = UInt32(sampleRate * Int(channelCount) * bytesPerSample)
        let blockAlign = UInt16(Int(channelCount) * bytesPerSample)
        let dataByteCount = UInt32(samples.count * bytesPerSample)

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(UInt32(36) + dataByteCount)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channelCount)
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(dataByteCount)

        for sample in samples {
            let clipped = min(max(sample, -1), 1)
            let pcm = Int16(clipped * Float(Int16.max))
            data.appendLittleEndian(UInt16(bitPattern: pcm))
        }

        return data
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
