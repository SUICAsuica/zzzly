import AVFoundation
import Foundation
import Observation

enum SnoreVerdict: String, Codable {
    case safe
    case borderline
    case snoring

    var label: String {
        switch self {
        case .safe: "SAFE"
        case .borderline: "BORDER"
        case .snoring: "SNORE"
        }
    }
}

struct SnoreResult: Codable, Equatable {
    var verdict: SnoreVerdict
    var snoreRatio: Double
    var peakDecibels: Float
    var checkedAt: Date
    var recordedSeconds: Double?
    var estimatedSnoreSeconds: Double?
    var loudRatio: Double?
    var snoreWindowCount: Int?
    var totalWindowCount: Int?
    var usedMachineLearning: Bool?
    var averageSnoreProbability: Double?
    var maximumSnoreProbability: Double?
    var snoreEventCount: Int?
    var longestSnoreRunSeconds: Double?
    var savedTrainingSegmentCount: Int?
    var firstSnoreSecondsFromStart: Double?
    var lastSnoreSecondsFromStart: Double?
    var timeline: [SnoreTimelinePoint]?
}

struct SnoreTimelinePoint: Codable, Equatable {
    var minuteIndex: Int
    var snoreRatio: Double
    var averageProbability: Double
    var peakDecibels: Float
}

@Observable
final class SnoreMonitor: @unchecked Sendable {
    private struct TimelineBucket {
        var totalCount = 0
        var snoreCount = 0
        var probabilitySum: Double = 0
        var peakDecibels: Float = -160
    }

    private let engine = AVAudioEngine()
    private let classifier = SnoreAudioClassifier.shared
    private let trainingRecorder = TrainingDataRecorder.shared
    private var sampleCount = 0
    private var loudFrameCount = 0
    private var possibleSnoreFrameCount = 0
    private var mlWindowCount = 0
    private var mlSnoreWindowCount = 0
    private var mlProbabilitySum: Double = 0
    private var mlMaximumProbability: Float = 0
    private var snoreEventCount = 0
    private var currentSnoreRunSeconds = 0
    private var longestSnoreRunSeconds = 0
    private var savedTrainingSegmentCount = 0
    private var firstSnoreSecondsFromStart: Double?
    private var lastSnoreSecondsFromStart: Double?
    private var peakDecibels: Float = -160
    private var timelineBuckets: [Int: TimelineBucket] = [:]
    private let snoreDecibelGate: Float = -55
    private var pendingAudioSamples: [Float] = []
    private var pendingSampleRate: Double = 16_000
    private let resultKey = "latestSnoreResult"
    private let historyKey = "snoreResultHistory"
    private let startedAtKey = "nightStartedAt"
    private let minimumNightDuration: TimeInterval = 20 * 60
    private let resultResetInterval: TimeInterval = 12 * 60 * 60

    var isMonitoring = false
    var latestResult: SnoreResult?
    var resultHistory: [SnoreResult] = []
    var permissionDenied = false
    var errorMessage: String?
    var startedAt: Date?

    init() {
        latestResult = Self.loadSavedResult(key: resultKey)
        resultHistory = Self.loadSavedResults(key: historyKey)
        if let latestResult, resultHistory.isEmpty {
            resultHistory = [latestResult]
        }
        seedDemoDataIfNeeded()
        startedAt = UserDefaults.standard.object(forKey: startedAtKey) as? Date
    }

    @MainActor
    func startNightIfNeeded() async {
        if let latestResult,
           Date().timeIntervalSince(latestResult.checkedAt) < resultResetInterval {
            return
        }

        if latestResult != nil {
            reset()
        }

        guard !isMonitoring else { return }
        await startNight()
    }

    @MainActor
    func startNight() async {
        errorMessage = nil

        let granted = await Self.requestMicrophoneAccess()
        guard granted else {
            permissionDenied = true
            return
        }

        do {
            resetCounters()
            try configureAudioSession()
            installTap()
            try engine.start()
            isMonitoring = true
            latestResult = nil
            startedAt = Date()
            UserDefaults.standard.set(startedAt, forKey: startedAtKey)
            if let startedAt {
                trainingRecorder.beginNight(startedAt: startedAt)
            }
        } catch {
            errorMessage = error.localizedDescription
            stopAudio()
        }
    }

    @MainActor
    func wakeUpIfReady() {
        guard isMonitoring,
              let startedAt,
              Date().timeIntervalSince(startedAt) >= minimumNightDuration else {
            return
        }

        wakeUp()
    }

    @MainActor
    func wakeUp() {
        let checkedAt = Date()
        let recordedSeconds = startedAt.map { checkedAt.timeIntervalSince($0) } ?? 0
        stopAudio()

        let heuristicRatio = sampleCount == 0 ? 0 : Double(possibleSnoreFrameCount) / Double(sampleCount)
        let loudRatio = sampleCount == 0 ? 0 : Double(loudFrameCount) / Double(sampleCount)
        let mlRatio = mlWindowCount == 0 ? 0 : Double(mlSnoreWindowCount) / Double(mlWindowCount)
        let usedMachineLearning = mlWindowCount > 0
        let ratio = usedMachineLearning ? mlRatio : heuristicRatio
        let snoreWindowCount = usedMachineLearning ? mlSnoreWindowCount : possibleSnoreFrameCount
        let totalWindowCount = usedMachineLearning ? mlWindowCount : sampleCount
        let estimatedSnoreSeconds = usedMachineLearning ? Double(mlSnoreWindowCount) : max(0, recordedSeconds * ratio)
        let averageSnoreProbability = usedMachineLearning ? mlProbabilitySum / Double(max(mlWindowCount, 1)) : nil
        let verdict: SnoreVerdict

        if ratio >= 0.16 || (!usedMachineLearning && (loudRatio >= 0.28 || peakDecibels > -14)) {
            verdict = .snoring
        } else if ratio >= 0.07 || (!usedMachineLearning && (loudRatio >= 0.14 || peakDecibels > -24)) {
            verdict = .borderline
        } else {
            verdict = .safe
        }

        let result = SnoreResult(
            verdict: verdict,
            snoreRatio: ratio,
            peakDecibels: peakDecibels,
            checkedAt: checkedAt,
            recordedSeconds: recordedSeconds,
            estimatedSnoreSeconds: estimatedSnoreSeconds,
            loudRatio: loudRatio,
            snoreWindowCount: snoreWindowCount,
            totalWindowCount: totalWindowCount,
            usedMachineLearning: usedMachineLearning,
            averageSnoreProbability: averageSnoreProbability,
            maximumSnoreProbability: usedMachineLearning ? Double(mlMaximumProbability) : nil,
            snoreEventCount: usedMachineLearning ? snoreEventCount : nil,
            longestSnoreRunSeconds: usedMachineLearning ? Double(longestSnoreRunSeconds) : nil,
            savedTrainingSegmentCount: trainingRecorder.isEnabled ? savedTrainingSegmentCount : nil,
            firstSnoreSecondsFromStart: usedMachineLearning ? firstSnoreSecondsFromStart : nil,
            lastSnoreSecondsFromStart: usedMachineLearning ? lastSnoreSecondsFromStart : nil,
            timeline: usedMachineLearning ? timelinePoints() : nil
        )
        latestResult = result
        appendHistory(result)
        startedAt = nil
        UserDefaults.standard.removeObject(forKey: startedAtKey)
        save(result)
        trainingRecorder.finishNight(result: result)
    }

    @MainActor
    func reset() {
        latestResult = nil
        startedAt = nil
        errorMessage = nil
        UserDefaults.standard.removeObject(forKey: resultKey)
        UserDefaults.standard.removeObject(forKey: startedAtKey)
    }

    @MainActor
    func cancelNight() {
        stopAudio()
        startedAt = nil
        errorMessage = nil
        resetCounters()
        UserDefaults.standard.removeObject(forKey: startedAtKey)
    }

    private static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        try session.setActive(true)
    }

    private func installTap() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        pendingSampleRate = format.sampleRate
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            let audio = Self.copySamples(buffer: buffer)
            guard let metrics = Self.analyze(buffer: buffer) else { return }
            Task { @MainActor in
                self?.record(metrics, audio: audio)
            }
        }
    }

    private nonisolated static func copySamples(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: frameLength))
    }

    private nonisolated static func analyze(buffer: AVAudioPCMBuffer) -> (db: Float, zeroCrossingRate: Double)? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        return analyze(samples: UnsafeBufferPointer(start: channel, count: frameLength))
    }

    private nonisolated static func analyze(samples: [Float]) -> (db: Float, zeroCrossingRate: Double)? {
        samples.withUnsafeBufferPointer { buffer in
            analyze(samples: buffer)
        }
    }

    private nonisolated static func analyze(samples: UnsafeBufferPointer<Float>) -> (db: Float, zeroCrossingRate: Double)? {
        let frameLength = samples.count
        guard frameLength > 0 else { return nil }

        var sumSquares: Float = 0
        var zeroCrossings = 0
        var lastSample = samples[0]

        for index in 0..<frameLength {
            let sample = samples[index]
            sumSquares += sample * sample
            if (sample >= 0 && lastSample < 0) || (sample < 0 && lastSample >= 0) {
                zeroCrossings += 1
            }
            lastSample = sample
        }

        let rms = sqrt(sumSquares / Float(frameLength))
        let db = 20 * log10(max(rms, 0.000_001))
        let zeroCrossingRate = Double(zeroCrossings) / Double(frameLength)

        return (db, zeroCrossingRate)
    }

    @MainActor
    private func record(_ metrics: (db: Float, zeroCrossingRate: Double), audio: [Float]) {
        sampleCount += 1
        peakDecibels = max(peakDecibels, metrics.db)

        if metrics.db > -34 {
            loudFrameCount += 1
        }

        if metrics.db > -31 && metrics.zeroCrossingRate < 0.13 {
            possibleSnoreFrameCount += 1
        }

        appendAudioForClassification(audio)
    }

    @MainActor
    private func stopAudio() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isMonitoring = false

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func resetCounters() {
        sampleCount = 0
        loudFrameCount = 0
        possibleSnoreFrameCount = 0
        mlWindowCount = 0
        mlSnoreWindowCount = 0
        mlProbabilitySum = 0
        mlMaximumProbability = 0
        snoreEventCount = 0
        currentSnoreRunSeconds = 0
        longestSnoreRunSeconds = 0
        savedTrainingSegmentCount = 0
        firstSnoreSecondsFromStart = nil
        lastSnoreSecondsFromStart = nil
        peakDecibels = -160
        timelineBuckets = [:]
        pendingAudioSamples = []
    }

    @MainActor
    private func appendAudioForClassification(_ audio: [Float]) {
        guard classifier.isAvailable, !audio.isEmpty else { return }

        pendingAudioSamples.append(contentsOf: audio)
        let windowSize = max(1, Int(pendingSampleRate))

        while pendingAudioSamples.count >= windowSize {
            let window = Array(pendingAudioSamples.prefix(windowSize))
            pendingAudioSamples.removeFirst(windowSize)

            let sourceRate = pendingSampleRate
            Task.detached(priority: .utility) { [classifier] in
                let probability = classifier.predictSnoreProbability(samples: window, sourceSampleRate: sourceRate)
                let normalizedSamples = classifier.normalizedOneSecondSamples(samples: window, sourceSampleRate: sourceRate)
                let metrics = Self.analyze(samples: normalizedSamples)
                await MainActor.run {
                    self.recordClassification(
                        probability: probability,
                        normalizedSamples: normalizedSamples,
                        metrics: metrics,
                        sourceRate: sourceRate
                    )
                }
            }
        }
    }

    @MainActor
    private func recordClassification(
        probability: Float?,
        normalizedSamples: [Float],
        metrics: (db: Float, zeroCrossingRate: Double)?,
        sourceRate: Double
    ) {
        guard let probability else { return }

        let windowIndex = mlWindowCount
        let isLoudEnough = (metrics?.db ?? -160) > snoreDecibelGate
        let isSnoring = probability >= classifier.snoreThreshold && isLoudEnough
        mlWindowCount += 1
        mlProbabilitySum += Double(probability)
        mlMaximumProbability = max(mlMaximumProbability, probability)
        recordTimelineBucket(
            windowIndex: windowIndex,
            probability: probability,
            isSnoring: isSnoring,
            decibels: metrics?.db
        )

        if isSnoring {
            mlSnoreWindowCount += 1
            if firstSnoreSecondsFromStart == nil {
                firstSnoreSecondsFromStart = Double(windowIndex)
            }
            lastSnoreSecondsFromStart = Double(windowIndex + 1)
            currentSnoreRunSeconds += 1
            if currentSnoreRunSeconds == 1 {
                snoreEventCount += 1
            }
            longestSnoreRunSeconds = max(longestSnoreRunSeconds, currentSnoreRunSeconds)
        } else {
            currentSnoreRunSeconds = 0
        }

        guard trainingRecorder.isEnabled,
              let metrics,
              !normalizedSamples.isEmpty else {
            return
        }

        savedTrainingSegmentCount += 1

        trainingRecorder.record(
            TrainingDataRecorder.Segment(
                probability: probability,
                isSnoring: isSnoring,
                db: metrics.db,
                zeroCrossingRate: metrics.zeroCrossingRate,
                sourceSampleRate: sourceRate,
                windowIndex: windowIndex,
                secondsFromStart: Double(windowIndex),
                normalizedSamples: normalizedSamples
            )
        )
    }

    private func recordTimelineBucket(
        windowIndex: Int,
        probability: Float,
        isSnoring: Bool,
        decibels: Float?
    ) {
        let minuteIndex = max(0, windowIndex / 60)
        var bucket = timelineBuckets[minuteIndex] ?? TimelineBucket()
        bucket.totalCount += 1
        bucket.probabilitySum += Double(probability)
        bucket.peakDecibels = max(bucket.peakDecibels, decibels ?? -160)
        if isSnoring {
            bucket.snoreCount += 1
        }
        timelineBuckets[minuteIndex] = bucket
    }

    private func timelinePoints() -> [SnoreTimelinePoint] {
        timelineBuckets.keys.sorted().compactMap { minuteIndex in
            guard let bucket = timelineBuckets[minuteIndex], bucket.totalCount > 0 else { return nil }
            return SnoreTimelinePoint(
                minuteIndex: minuteIndex,
                snoreRatio: Double(bucket.snoreCount) / Double(bucket.totalCount),
                averageProbability: bucket.probabilitySum / Double(bucket.totalCount),
                peakDecibels: bucket.peakDecibels
            )
        }
    }

    private func save(_ result: SnoreResult) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        UserDefaults.standard.set(data, forKey: resultKey)
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(resultHistory) else { return }
        UserDefaults.standard.set(data, forKey: historyKey)
    }

    private func appendHistory(_ result: SnoreResult) {
        let calendar = Calendar.current
        if let index = resultHistory.firstIndex(where: {
            calendar.isDate($0.checkedAt, inSameDayAs: result.checkedAt)
        }) {
            resultHistory[index] = result
        } else {
            resultHistory.append(result)
        }

        resultHistory.sort { $0.checkedAt < $1.checkedAt }
        if resultHistory.count > 60 {
            resultHistory.removeFirst(resultHistory.count - 60)
        }
        saveHistory()
    }

    private static func loadSavedResult(key: String) -> SnoreResult? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SnoreResult.self, from: data)
    }

    private static func loadSavedResults(key: String) -> [SnoreResult] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SnoreResult].self, from: data)) ?? []
    }

    private func seedDemoDataIfNeeded() {
        guard resultHistory.isEmpty else { return }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let demo: [(daysAgo: Int, ratio: Double, verdict: SnoreVerdict, peak: Float, events: Int)] = [
            (6, 0.04, .safe, -48, 3),
            (5, 0.11, .borderline, -42, 9),
            (4, 0.23, .snoring, -34, 18),
            (3, 0.08, .borderline, -45, 7),
            (2, 0.02, .safe, -53, 2),
            (1, 0.17, .snoring, -38, 13),
            (0, 0.06, .safe, -49, 4)
        ]

        resultHistory = demo.compactMap { item in
            guard let checkedAt = calendar.date(byAdding: .day, value: -item.daysAgo, to: today)?
                .addingTimeInterval(7 * 60 * 60 + 24 * 60) else {
                return nil
            }

            let recordedSeconds = 7.2 * 60 * 60
            let snoreSeconds = recordedSeconds * item.ratio
            return SnoreResult(
                verdict: item.verdict,
                snoreRatio: item.ratio,
                peakDecibels: item.peak,
                checkedAt: checkedAt,
                recordedSeconds: recordedSeconds,
                estimatedSnoreSeconds: snoreSeconds,
                loudRatio: item.ratio,
                snoreWindowCount: Int(snoreSeconds),
                totalWindowCount: Int(recordedSeconds),
                usedMachineLearning: true,
                averageSnoreProbability: 0.62 + item.ratio * 0.9,
                maximumSnoreProbability: min(0.96, 0.76 + item.ratio),
                snoreEventCount: item.events,
                longestSnoreRunSeconds: max(12, snoreSeconds / Double(max(item.events, 1))),
                savedTrainingSegmentCount: Int(recordedSeconds),
                firstSnoreSecondsFromStart: item.ratio > 0.03 ? 28 * 60 : nil,
                lastSnoreSecondsFromStart: item.ratio > 0.03 ? recordedSeconds - 42 * 60 : nil,
                timeline: Self.demoTimeline(ratio: item.ratio)
            )
        }
        latestResult = resultHistory.last
        if let latestResult {
            save(latestResult)
        }
        saveHistory()
    }

    private static func demoTimeline(ratio: Double) -> [SnoreTimelinePoint] {
        let minutes = 7 * 60
        return stride(from: 0, to: minutes, by: 6).map { minute in
            let phase = Double(minute) / 38
            let wave = (sin(phase) + 1) / 2
            let lateNightBoost = minute > 240 && minute < 360 ? 0.16 : 0
            let value = min(1, max(0, ratio * (0.45 + wave * 1.35) + lateNightBoost * ratio))
            let probability = min(0.98, 0.62 + value * 0.55)
            let peak = Float(-58 + value * 28)
            return SnoreTimelinePoint(
                minuteIndex: minute,
                snoreRatio: value,
                averageProbability: probability,
                peakDecibels: peak
            )
        }
    }
}
