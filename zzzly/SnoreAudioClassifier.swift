import Accelerate
import CoreML
import Foundation

final class SnoreAudioClassifier: @unchecked Sendable {
    static let shared = SnoreAudioClassifier()

    private let sampleRate = 16_000
    private let windowSamples = 16_000
    private let nMels = 64
    private let targetFrames = 96
    private let fftSize = 512
    private let hopLength = 160
    private let threshold: Float = 0.75
    private let model: MLModel?
    private let fftSetup: FFTSetup?

    private init() {
        fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Float(fftSize))), FFTRadix(kFFTRadix2))

        guard let url = Bundle.main.url(forResource: "SnoreCNN", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "SnoreCNN", withExtension: "mlpackage") else {
            model = nil
            return
        }

        model = try? MLModel(contentsOf: url)
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    var isAvailable: Bool {
        model != nil
    }

    var snoreThreshold: Float {
        threshold
    }

    func normalizedOneSecondSamples(samples: [Float], sourceSampleRate: Double) -> [Float] {
        resample(samples: samples, sourceRate: sourceSampleRate)
    }

    func predictSnoreProbability(samples: [Float], sourceSampleRate: Double) -> Float? {
        guard let model else { return nil }

        let resampled = resample(samples: samples, sourceRate: sourceSampleRate)
        guard resampled.count == windowSamples else { return nil }

        let features = makeLogMel(samples: resampled)
        guard let input = try? MLMultiArray(shape: [1, 1, NSNumber(value: nMels), NSNumber(value: targetFrames)], dataType: .float32) else {
            return nil
        }

        for index in features.indices {
            input[index] = NSNumber(value: features[index])
        }

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["logmel": input]),
              let output = try? model.prediction(from: provider),
              let values = output.featureValue(for: "var_80")?.multiArrayValue,
              values.count >= 2 else {
            return nil
        }

        let raw0 = values[0].floatValue
        let raw1 = values[1].floatValue
        if raw0 >= 0, raw1 >= 0, raw0 <= 1, raw1 <= 1 {
            return raw0
        }

        let maxRaw = max(raw0, raw1)
        let exp0 = Foundation.exp(Double(raw0 - maxRaw))
        let exp1 = Foundation.exp(Double(raw1 - maxRaw))
        return Float(exp0 / (exp0 + exp1))
    }

    func isSnoring(samples: [Float], sourceSampleRate: Double) -> Bool? {
        guard let probability = predictSnoreProbability(samples: samples, sourceSampleRate: sourceSampleRate) else {
            return nil
        }

        return probability >= threshold
    }

    private func resample(samples: [Float], sourceRate: Double) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0 else { return [] }

        if abs(sourceRate - Double(sampleRate)) < 1 {
            if samples.count >= windowSamples {
                return Array(samples.prefix(windowSamples))
            }
            return samples + Array(repeating: 0, count: windowSamples - samples.count)
        }

        let sourceCount = samples.count
        let duration = Double(sourceCount) / sourceRate
        let outputCount = min(windowSamples, max(1, Int(duration * Double(sampleRate))))
        var output = Array(repeating: Float(0), count: outputCount)

        for index in 0..<outputCount {
            let sourcePosition = Double(index) * sourceRate / Double(sampleRate)
            let lower = min(Int(sourcePosition), sourceCount - 1)
            let upper = min(lower + 1, sourceCount - 1)
            let fraction = Float(sourcePosition - Double(lower))
            output[index] = samples[lower] * (1 - fraction) + samples[upper] * fraction
        }

        if output.count < windowSamples {
            output += Array(repeating: 0, count: windowSamples - output.count)
        }

        return output
    }

    private func makeLogMel(samples: [Float]) -> [Float] {
        let melFilters = makeMelFilters(fftBins: fftSize / 2 + 1)
        var result = Array(repeating: Float(0), count: nMels * targetFrames)
        var allDb = Array(repeating: Float(0), count: nMels * targetFrames)
        var maxPower = Float.leastNonzeroMagnitude

        for frame in 0..<targetFrames {
            let start = frame * hopLength
            var windowed = Array(repeating: Float(0), count: fftSize)
            for i in 0..<fftSize {
                let sampleIndex = start + i
                let sample = sampleIndex < samples.count ? samples[sampleIndex] : 0
                let hann = 0.5 - 0.5 * Foundation.cos(2 * .pi * Double(i) / Double(fftSize - 1))
                windowed[i] = sample * Float(hann)
            }

            let spectrum = powerSpectrum(frame: windowed)
            for mel in 0..<nMels {
                var power: Float = 0
                let filter = melFilters[mel]
                for bin in spectrum.indices {
                    power += spectrum[bin] * filter[bin]
                }
                let clamped = max(power, 1e-10)
                maxPower = max(maxPower, clamped)
                allDb[mel * targetFrames + frame] = clamped
            }
        }

        let refDb = 10 * log10(maxPower)
        for index in allDb.indices {
            let db = 10 * log10(max(allDb[index], 1e-10)) - refDb
            result[index] = min(max((db + 80) / 80, 0), 1)
        }

        return result
    }

    private func powerSpectrum(frame: [Float]) -> [Float] {
        guard let fftSetup else {
            return slowPowerSpectrum(frame: frame)
        }

        let n = frame.count
        let half = n / 2
        var spectrum = Array(repeating: Float(0), count: half + 1)
        var real = frame
        var imaginary = Array(repeating: Float(0), count: n)
        let log2n = vDSP_Length(log2(Float(n)))

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                guard let realBase = realPointer.baseAddress,
                      let imaginaryBase = imaginaryPointer.baseAddress else {
                    return
                }

                var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
                vDSP_fft_zip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                for index in 0...half {
                    spectrum[index] = split.realp[index] * split.realp[index] + split.imagp[index] * split.imagp[index]
                }
            }
        }

        return spectrum
    }

    private func slowPowerSpectrum(frame: [Float]) -> [Float] {
        let n = frame.count
        let half = n / 2
        var spectrum = Array(repeating: Float(0), count: half + 1)
        for k in 0...half {
            var real: Float = 0
            var imaginary: Float = 0
            for t in 0..<n {
                let angle = -2 * Float.pi * Float(k * t) / Float(n)
                real += frame[t] * cos(angle)
                imaginary += frame[t] * sin(angle)
            }
            spectrum[k] = real * real + imaginary * imaginary
        }

        return spectrum
    }

    private func makeMelFilters(fftBins: Int) -> [[Float]] {
        let minHz: Float = 40
        let maxHz: Float = 4_000
        let minMel = hzToSlaneyMel(minHz)
        let maxMel = hzToSlaneyMel(maxHz)
        let melPoints = (0..<(nMels + 2)).map { index in
            minMel + (maxMel - minMel) * Float(index) / Float(nMels + 1)
        }
        let hzPoints = melPoints.map(slaneyMelToHz)
        let fftFrequencies = (0..<fftBins).map { bin in
            Float(sampleRate) * Float(bin) / Float(fftSize)
        }

        var filters = Array(repeating: Array(repeating: Float(0), count: fftBins), count: nMels)
        for mel in 0..<nMels {
            let lower = hzPoints[mel]
            let center = hzPoints[mel + 1]
            let upper = hzPoints[mel + 2]
            let enorm = 2 / max(upper - lower, Float.leastNonzeroMagnitude)

            for bin in 0..<fftBins {
                let frequency = fftFrequencies[bin]
                let lowerSlope = (frequency - lower) / max(center - lower, Float.leastNonzeroMagnitude)
                let upperSlope = (upper - frequency) / max(upper - center, Float.leastNonzeroMagnitude)
                filters[mel][bin] = max(0, min(lowerSlope, upperSlope)) * enorm
            }
        }

        return filters
    }

    private func hzToSlaneyMel(_ hz: Float) -> Float {
        let minLogHz: Float = 1_000
        let minLogMel: Float = 15
        let logStep = log(Float(6.4)) / 27

        if hz < minLogHz {
            return hz / (200 / 3)
        }

        return minLogMel + log(hz / minLogHz) / logStep
    }

    private func slaneyMelToHz(_ mel: Float) -> Float {
        let minLogHz: Float = 1_000
        let minLogMel: Float = 15
        let logStep = log(Float(6.4)) / 27

        if mel < minLogMel {
            return mel * (200 / 3)
        }

        return minLogHz * exp(logStep * (mel - minLogMel))
    }
}
