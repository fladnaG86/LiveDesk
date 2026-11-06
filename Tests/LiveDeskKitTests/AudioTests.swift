import Foundation
import Testing
@testable import LiveDeskKit

struct AudioSpectrumTests {
    let sampleRate = 48_000.0

    func sine(_ hz: Double, count: Int = 2048, amplitude: Float = 0.5) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / sampleRate)) }
    }

    @Test func bassToneLandsInBass() {
        let b = SpectrumAnalyzer(size: 2048).bands(sine(100), sampleRate: sampleRate)
        #expect(b.bass > b.mid * 5)
        #expect(b.bass > b.treble * 5)
    }

    @Test func trebleToneLandsInTreble() {
        let b = SpectrumAnalyzer(size: 2048).bands(sine(8000), sampleRate: sampleRate)
        #expect(b.treble > b.bass * 5)
        #expect(b.treble > b.mid)
    }

    @Test func midTone() {
        let b = SpectrumAnalyzer(size: 2048).bands(sine(1000), sampleRate: sampleRate)
        #expect(b.mid > b.bass * 5)
        #expect(b.mid > b.treble * 5)
    }

    @Test func peakMagnitudeMatchesAmplitude() {
        let analyzer = SpectrumAnalyzer(size: 2048)
        let hz = sampleRate / 2048 * 20 // exactly bin 20
        let mags = analyzer.magnitudes(sine(hz, amplitude: 0.5))
        let peak = mags.indices.max { mags[$0] < mags[$1] }!
        #expect(peak == 20)
        #expect(abs(mags[peak] - 0.5) < 0.05, "peak=\(mags[peak])")
    }

    @Test func shortInputIsPadded() {
        let mags = SpectrumAnalyzer(size: 1024).magnitudes([1, 2, 3])
        #expect(mags.count == 512)
    }

    @Test func smootherNormalizesAndDecays() {
        var smoother = BandSmoother()
        let loud = AudioBands(bass: 0.4, mid: 0.1, treble: 0.05, level: 0.3)
        var out = AudioBands.zero
        for _ in 0..<20 { out = smoother.process(loud) }
        #expect(out.bass > 0.95 && out.bass <= 1)
        for _ in 0..<200 { out = smoother.process(.zero) }
        #expect(out.bass < 0.01)
        #expect(out.level >= 0)
    }
}
