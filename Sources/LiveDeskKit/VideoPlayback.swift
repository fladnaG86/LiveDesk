import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

// MARK: Shared players

/// One looping AVQueuePlayer per video file, shared by every screen showing it,
/// so a wallpaper on N screens is decoded once instead of N times.
@MainActor
public final class SharedVideoPlayer {
    public let url: URL
    public let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    fileprivate var refs = 0
    private var wanting: Set<ObjectIdentifier> = []
    private var rate: Float = 1

    init(url: URL) {
        self.url = url
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 2
        looper = AVPlayerLooper(player: player, templateItem: item)
    }

    /// True when at least one owner wants playback.
    public var wantsPlay: Bool { !wanting.isEmpty }

    public func setPlaying(_ playing: Bool, owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        if playing { wanting.insert(key) } else { wanting.remove(key) }
        update()
    }

    public func setRate(_ rate: Float) {
        self.rate = rate
        player.defaultRate = rate
        if wantsPlay { player.rate = rate }
    }

    private func update() {
        if wantsPlay {
            player.defaultRate = rate
            if player.rate == 0 { player.play() }
        } else if player.rate != 0 {
            player.pause()
        }
    }

    fileprivate func forget(owner: AnyObject) {
        wanting.remove(ObjectIdentifier(owner))
        update()
    }

    fileprivate func shutdown() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }
}

@MainActor
public final class VideoPlayerPool {
    private var players: [URL: SharedVideoPlayer] = [:]

    public init() {}

    public var count: Int { players.count }

    public func acquire(_ url: URL) -> SharedVideoPlayer {
        let shared = players[url] ?? SharedVideoPlayer(url: url)
        players[url] = shared
        shared.refs += 1
        return shared
    }

    public func release(_ shared: SharedVideoPlayer, owner: AnyObject) {
        shared.forget(owner: owner)
        shared.refs -= 1
        guard shared.refs <= 0, players[shared.url] === shared else { return }
        players[shared.url] = nil
        shared.shutdown()
    }
}

// MARK: Frame-rate limiting

/// Makes a lower-frame-rate playback copy of high-frame-rate videos (e.g. 240 fps Aerial-style
/// assets). Displays refresh at 60–120 Hz, so the extra frames only cost decode and I/O.
public enum FrameRateLimiter {
    public enum Failure: Error, LocalizedError {
        case noVideoTrack, reader(String), writer(String)
        public var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "Nessuna traccia video"
            case .reader(let s): return "Lettura video: \(s)"
            case .writer(let s): return "Scrittura video: \(s)"
            }
        }
    }

    public static func needsLimiting(_ url: URL, maxFPS: Double) async throws -> Bool {
        guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else { return false }
        return Double(try await track.load(.nominalFrameRate)) > maxFPS + 1
    }

    /// Re-encodes `source` to HEVC Main10 keeping at most `maxFPS` frames per second.
    /// Original timestamps, size, transform and color tags are kept.
    public static func transcode(source: URL, to output: URL, maxFPS: Double,
                                 progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideoTrack }
        let duration = try await asset.load(.duration)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let dataRate = try await track.load(.estimatedDataRate)
        let formats = try await track.load(.formatDescriptions)
        let ext = formats.first.flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] } ?? [:]

        var color: [String: Any] = [:]
        if let p = ext[kCVImageBufferColorPrimariesKey as String] { color[AVVideoColorPrimariesKey] = p }
        if let t = ext[kCVImageBufferTransferFunctionKey as String] { color[AVVideoTransferFunctionKey] = t }
        if let m = ext[kCVImageBufferYCbCrMatrixKey as String] { color[AVVideoYCbCrMatrixKey] = m }
        if color.count != 3 {
            color = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                     AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                     AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        }
        // Fewer frames need fewer bits; 75% of the source rate, at least 6 Mb/s.
        let bitrate = max(6_000_000, Int(Double(dataRate) * 0.75))

        try await Task.detached(priority: .utility) {
            try run(asset: asset, track: track, output: output, size: size, transform: transform, color: color,
                    bitrate: bitrate, maxFPS: maxFPS, duration: duration, progress: progress)
        }.value
    }

    private static func run(asset: AVAsset, track: AVAssetTrack, output: URL, size: CGSize,
                            transform: CGAffineTransform, color: [String: Any], bitrate: Int,
                            maxFPS: Double, duration: CMTime, progress: (@Sendable (Double) -> Void)?) throws {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw Failure.reader(error.localizedDescription) }
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        ])
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw Failure.reader("output") }
        reader.add(readerOutput)

        try? FileManager.default.removeItem(at: output)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: output, fileType: .mov) } catch { throw Failure.writer(error.localizedDescription) }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: color,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: Int(maxFPS),
                AVVideoMaxKeyFrameIntervalKey: Int(maxFPS * 2),
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            ],
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw Failure.writer("input") }
        writer.add(input)

        guard reader.startReading() else { throw Failure.reader(reader.error?.localizedDescription ?? "start") }
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        let interval = 1 / maxFPS
        let total = max(duration.seconds, 0.001)
        var nextKeep = 0.0
        var lastReport = 0.0
        while let sample = readerOutput.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // Keep the first frame at or after each 1/maxFPS boundary (small tolerance for rounding).
            guard t + interval * 0.05 >= nextKeep else { continue }
            while nextKeep <= t + interval * 0.05 { nextKeep += interval }
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard input.append(sample) else { throw Failure.writer(writer.error?.localizedDescription ?? "append") }
            if let progress, t - lastReport > total / 100 {
                lastReport = t
                progress(min(1, t / total))
            }
        }
        if reader.status == .failed { throw Failure.reader(reader.error?.localizedDescription ?? "read") }
        input.markAsFinished()
        writer.endSession(atSourceTime: duration)
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw Failure.writer(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        progress?(1)
    }
}
