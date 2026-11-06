import AVFoundation
import CoreVideo
import Metal

public struct OfflineRenderOptions: Sendable, Equatable {
    public var width = 3840
    public var height = 2160
    public var fps = 30
    public var duration: Double = 20
    /// Seconds of the scene after `duration` blended into the start so the video loops without a cut.
    public var crossfade: Double = 3
    public var bitrate = 18_000_000

    public init() {}

    public var frameCount: Int { max(1, Int((duration * Double(fps)).rounded())) }
    public var crossfadeFrames: Int { min(frameCount / 2, max(0, Int((crossfade * Double(fps)).rounded()))) }

    /// Weight of the scene at time i/fps; the rest comes from time (frameCount + i)/fps.
    /// Frame 0 equals the scene at `duration`, which continues the last frame: a seamless loop.
    public func blendWeight(frame i: Int) -> Double {
        let f = crossfadeFrames
        guard f > 0, i < f else { return 1 }
        return Double(i) / Double(f)
    }
}

public enum OfflineRenderError: Error, LocalizedError {
    case metal(String)
    case writer(String)

    public var errorDescription: String? {
        switch self {
        case .metal(let s): return "Metal: \(s)"
        case .writer(let s): return "Scrittura video: \(s)"
        }
    }
}

/// Renders a scene to a looping HEVC QuickTime movie. Meant for stateless scenes:
/// feedback scenes (that read their own previous frame) do not survive the crossfade time jump.
public enum OfflineSceneRenderer {
    public static func render(folder: URL, to output: URL, options: OfflineRenderOptions,
                              progress: ((Double) -> Void)? = nil) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw SceneRendererError.noDevice }
        let manifest = try SceneManifest.load(from: folder)
        let renderer = try SceneRenderer(folder: folder, manifest: manifest, device: device, viewPixelFormat: .bgra8Unorm)

        let library = try device.makeLibrary(source: SceneShaderHeader.source, options: nil)
        func pipeline(_ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "ld_vertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: d)
        }
        let copyPipeline = try pipeline("ld_present", SceneRenderer.textureFormat)
        let blendPipeline = try pipeline("ld_blend", .bgra8Unorm)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { throw OfflineRenderError.metal("sampler") }

        func texture(_ format: MTLPixelFormat, _ storage: MTLStorageMode) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: options.width, height: options.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = storage
            guard let t = device.makeTexture(descriptor: d) else { throw OfflineRenderError.metal("texture") }
            return t
        }
        let texA = try texture(SceneRenderer.textureFormat, .private)
        let texB = try texture(SceneRenderer.textureFormat, .private)
        let unified = device.hasUnifiedMemory
        let readback = try texture(.bgra8Unorm, unified ? .shared : .managed)

        // Writer
        try? FileManager.default.removeItem(at: output)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: output, fileType: .mov) } catch { throw OfflineRenderError.writer(error.localizedDescription) }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: options.width,
            AVVideoHeightKey: options.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: options.bitrate,
                AVVideoExpectedSourceFrameRateKey: options.fps,
                AVVideoMaxKeyFrameIntervalKey: options.fps * 2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: options.width,
            kCVPixelBufferHeightKey as String: options.height,
        ])
        guard writer.canAdd(input) else { throw OfflineRenderError.writer("input non accettato") }
        writer.add(input)
        guard writer.startWriting() else { throw OfflineRenderError.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        let size = CGSize(width: options.width, height: options.height)
        let n = options.frameCount
        let dt = 1.0 / Double(options.fps)

        func draw(_ cb: MTLCommandBuffer, _ pipeline: MTLRenderPipelineState, into target: MTLTexture,
                  textures: [MTLTexture], weight: Float? = nil) {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = target
            rp.colorAttachments[0].loadAction = .dontCare
            rp.colorAttachments[0].storeAction = .store
            guard let e = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
            e.setRenderPipelineState(pipeline)
            for (i, t) in textures.enumerated() { e.setFragmentTexture(t, index: i) }
            if var w = weight { e.setFragmentBytes(&w, length: MemoryLayout<Float>.size, index: 0) }
            e.setFragmentSamplerState(sampler, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }

        for i in 0..<n {
            try autoreleasepool {
                guard let cb = renderer.makeCommandBuffer() else { throw OfflineRenderError.metal("command buffer") }
                let w = options.blendWeight(frame: i)
                guard let a = renderer.encodePasses(cb, drawableSize: size, time: Double(i) * dt, dt: dt, frameIndex: i) else {
                    throw OfflineRenderError.metal("render")
                }
                draw(cb, copyPipeline, into: texA, textures: [a])
                if w < 1, let b = renderer.encodePasses(cb, drawableSize: size, time: Double(n + i) * dt, dt: dt, frameIndex: n + i) {
                    draw(cb, copyPipeline, into: texB, textures: [b])
                    draw(cb, blendPipeline, into: readback, textures: [texA, texB], weight: Float(w))
                } else {
                    draw(cb, blendPipeline, into: readback, textures: [texA, texA], weight: 1)
                }
                if !unified, let blit = cb.makeBlitCommandEncoder() {
                    blit.synchronize(resource: readback)
                    blit.endEncoding()
                }
                cb.commit()
                cb.waitUntilCompleted()
                if let error = cb.error { throw OfflineRenderError.metal(error.localizedDescription) }

                while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
                guard let pool = adaptor.pixelBufferPool else { throw OfflineRenderError.writer("pixel buffer pool") }
                var pixelBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                guard let pb = pixelBuffer else { throw OfflineRenderError.writer("pixel buffer") }
                CVPixelBufferLockBaseAddress(pb, [])
                if let base = CVPixelBufferGetBaseAddress(pb) {
                    readback.getBytes(base, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                      from: MTLRegionMake2D(0, 0, options.width, options.height), mipmapLevel: 0)
                }
                CVPixelBufferUnlockBaseAddress(pb, [])
                guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(options.fps))) else {
                    throw OfflineRenderError.writer(writer.error?.localizedDescription ?? "append")
                }
                progress?(Double(i + 1) / Double(n))
            }
        }

        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw OfflineRenderError.writer(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }
}
