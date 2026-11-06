import Accelerate
import Foundation

public struct AudioBands: Equatable, Sendable {
    public var bass: Float
    public var mid: Float
    public var treble: Float
    public var level: Float

    public init(bass: Float, mid: Float, treble: Float, level: Float) {
        self.bass = bass
        self.mid = mid
        self.treble = treble
        self.level = level
    }

    public static let zero = AudioBands(bass: 0, mid: 0, treble: 0, level: 0)
}

/// FFT magnitude analysis of mono sample blocks.
public final class SpectrumAnalyzer {
    public static let bassRange: ClosedRange<Double> = 20...250
    public static let midRange: ClosedRange<Double> = 250...4000
    public static let trebleRange: ClosedRange<Double> = 4000...16000

    public let size: Int
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]

    /// - Parameter size: power of two.
    public init(size: Int = 2048) {
        precondition(size >= 64 && size & (size - 1) == 0, "size must be a power of two")
        self.size = size
        let log2n = vDSP_Length(log2(Double(size)))
        fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
    }

    /// Magnitudes of bins 0..<size/2 (bin k = k * sampleRate / size Hz). Input shorter than `size` is zero padded.
    public func magnitudes(_ samples: [Float]) -> [Float] {
        var input = [Float](repeating: 0, count: size)
        let n = min(samples.count, size)
        input.replaceSubrange(0..<n, with: samples[(samples.count - n)...])
        let windowed = vDSP.multiply(input, window)

        let half = size / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                fft.forward(input: split, output: &split)
                mags.withUnsafeMutableBufferPointer { mp in
                    vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }
        mags[0] = 0 // DC and packed Nyquist
        // vDSP's real FFT is scaled by 2; with N/4 from one-sided Hann (coherent gain 0.5) this gives peak == sine amplitude.
        let scale = 2 / Float(size)
        return vDSP.multiply(scale, mags)
    }

    public func bandEnergy(_ mags: [Float], sampleRate: Double, range: ClosedRange<Double>) -> Float {
        let binWidth = sampleRate / Double(size)
        let lo = max(1, Int((range.lowerBound / binWidth).rounded(.down)))
        let hi = min(mags.count - 1, Int((range.upperBound / binWidth).rounded(.up)))
        guard hi >= lo else { return 0 }
        return vDSP.mean(mags[lo...hi])
    }

    /// Raw (unnormalized) band energies.
    public func bands(_ samples: [Float], sampleRate: Double) -> AudioBands {
        let mags = magnitudes(samples)
        let bass = bandEnergy(mags, sampleRate: sampleRate, range: Self.bassRange)
        let mid = bandEnergy(mags, sampleRate: sampleRate, range: Self.midRange)
        let treble = bandEnergy(mags, sampleRate: sampleRate, range: Self.trebleRange)
        let n = min(samples.count, size)
        let rms = n > 0 ? vDSP.rootMeanSquare(samples[(samples.count - n)...]) : 0
        return AudioBands(bass: bass, mid: mid, treble: treble, level: rms)
    }
}

/// Turns raw energies into 0...1 values: adaptive peak normalization plus fast attack / slow decay.
public struct BandSmoother: Sendable {
    public var attack: Float = 0.6
    public var decay: Float = 0.12
    public var peakDecay: Float = 0.997
    /// Values below this are treated as silence.
    public var floor: Float = 1e-4

    private var peaks: [Float] = [0, 0, 0, 0]
    private var values: [Float] = [0, 0, 0, 0]

    public init() {}

    public mutating func process(_ raw: AudioBands) -> AudioBands {
        let input = [raw.bass, raw.mid, raw.treble, raw.level]
        for i in 0..<4 {
            peaks[i] = max(input[i], peaks[i] * peakDecay)
            let target: Float = input[i] < floor ? 0 : min(1, input[i] / max(peaks[i], floor * 10))
            let k = target > values[i] ? attack : decay
            values[i] += (target - values[i]) * k
            values[i] = min(1, max(0, values[i]))
        }
        return AudioBands(bass: values[0], mid: values[1], treble: values[2], level: values[3])
    }
}
