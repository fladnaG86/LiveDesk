import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import LiveDeskKit

/// Writes a tiny synthetic H.264 movie at `fps` for `seconds`.
func makeMovie(fps: Int, seconds: Double, size: CGSize = CGSize(width: 128, height: 72)) async throws -> URL {
    let url = makeTempDir().appendingPathComponent("src-\(fps).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height),
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
    ])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let frames = Int(Double(fps) * seconds)
    for i in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(i * 7 % 255), CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
    return url
}

struct FrameRateLimiterTests {
    @Test func detectsHighFrameRate() async throws {
        let fast = try await makeMovie(fps: 240, seconds: 0.5)
        let slow = try await makeMovie(fps: 30, seconds: 0.5)
        #expect(try await FrameRateLimiter.needsLimiting(fast, maxFPS: 60))
        #expect(try await !FrameRateLimiter.needsLimiting(slow, maxFPS: 60))
    }

    @Test func transcodesTo60fpsKeepingDurationAndSize() async throws {
        let src = try await makeMovie(fps: 240, seconds: 1)
        let out = makeTempDir().appendingPathComponent("out.mov")
        try await FrameRateLimiter.transcode(source: src, to: out, maxFPS: 60)
        let asset = AVURLAsset(url: out)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let fps = try await track.load(.nominalFrameRate)
        #expect(fps > 55 && fps < 65, "fps \(fps)")
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1) < 0.1, "duration \(duration)")
        #expect(try await track.load(.naturalSize) == CGSize(width: 128, height: 72))
    }

    @Test func playbackCopyNaming() {
        let media = URL(fileURLWithPath: "/tmp/Media")
        let id = UUID(uuidString: "35506C59-979F-4F5A-BBFE-F8641B18FAA2")!
        #expect(LibraryStore.playbackCopyURL(id: id, mediaFolder: media).lastPathComponent
                == "35506C59-979F-4F5A-BBFE-F8641B18FAA2.playback.mov")
    }
}

@MainActor
struct VideoPlayerPoolTests {
    @Test func sameURLSharesOnePlayerUntilLastRelease() {
        let pool = VideoPlayerPool()
        let url = URL(fileURLWithPath: "/tmp/none.mov")
        let a = pool.acquire(url)
        let b = pool.acquire(url)
        #expect(a === b)
        #expect(pool.count == 1)
        let owner1 = NSObject(), owner2 = NSObject()
        a.setPlaying(true, owner: owner1)
        b.setPlaying(false, owner: owner2)
        #expect(a.wantsPlay)              // any owner wanting play keeps it running
        a.setPlaying(false, owner: owner1)
        #expect(!a.wantsPlay)
        pool.release(a, owner: owner1)
        #expect(pool.count == 1)
        pool.release(b, owner: owner2)
        #expect(pool.count == 0)
        #expect(pool.acquire(url) !== a)  // fresh player after full release
    }
}
