import AppKit
import Metal
import MetalKit
import QuartzCore
import simd

public enum SceneRendererError: Error, LocalizedError {
    case noDevice
    case compile(pass: String, message: String)
    case missingFunction(String)

    public var errorDescription: String? {
        switch self {
        case .noDevice: return "Metal non disponibile"
        case .compile(let pass, let message): return "Errore shader in \(pass): \(message)"
        case .missingFunction(let name): return "Funzione \(name) non trovata nello shader"
        }
    }
}

struct SceneUniforms {
    var timeInfo: SIMD4<Float>
    var resolution: SIMD4<Float>
    var mouse: SIMD4<Float>
    var audio: SIMD4<Float>
}

/// Renders a multi-pass scene into an MTKView. Each pass writes an rgba16Float texture (double buffered).
public final class SceneRenderer: NSObject, MTKViewDelegate {
    public let manifest: SceneManifest
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipelines: [MTLRenderPipelineState] = []
    private let presentPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let dummy: MTLTexture
    private var targets: [[MTLTexture]] = []
    private var current: [Int] = []
    private var targetSize = CGSize.zero

    public var renderScale: Double = 1.0 { didSet { targetSize = .zero } }
    public var speed: Double = 1.0
    public var audioProvider: () -> AudioBands = { .zero }

    private var time: Double = 0
    private var frame: Int = 0
    private var lastTimestamp: CFTimeInterval?

    public static let textureFormat: MTLPixelFormat = .rgba16Float

    public init(folder: URL, manifest: SceneManifest, device: MTLDevice, viewPixelFormat: MTLPixelFormat) throws {
        self.manifest = manifest
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw SceneRendererError.noDevice }
        self.queue = queue

        let header = SceneShaderHeader.source
        let headerLibrary = try Self.compile(header, name: "header", device: device)
        guard let vertex = headerLibrary.makeFunction(name: "ld_vertex"),
              let present = headerLibrary.makeFunction(name: "ld_present") else {
            throw SceneRendererError.missingFunction("ld_vertex")
        }
        let presentDescriptor = MTLRenderPipelineDescriptor()
        presentDescriptor.vertexFunction = vertex
        presentDescriptor.fragmentFunction = present
        presentDescriptor.colorAttachments[0].pixelFormat = viewPixelFormat
        presentPipeline = try device.makeRenderPipelineState(descriptor: presentDescriptor)

        for pass in manifest.passes {
            let source = try String(contentsOf: folder.appendingPathComponent(pass.source), encoding: .utf8)
            let library = try Self.compile(header + "\n#line 1\n" + source, name: pass.source, device: device)
            guard let fragment = library.makeFunction(name: pass.function),
                  let passVertex = library.makeFunction(name: "ld_vertex") else {
                throw SceneRendererError.missingFunction(pass.function)
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = passVertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = Self.textureFormat
            pipelines.append(try device.makeRenderPipelineState(descriptor: descriptor))
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)!

        let dummyDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.textureFormat, width: 1, height: 1, mipmapped: false)
        dummyDescriptor.usage = [.shaderRead]
        dummy = device.makeTexture(descriptor: dummyDescriptor)!
        super.init()
    }

    private static func compile(_ source: String, name: String, device: MTLDevice) throws -> MTLLibrary {
        do {
            let options = MTLCompileOptions()
            options.mathMode = .fast
            return try device.makeLibrary(source: source, options: options)
        } catch {
            throw SceneRendererError.compile(pass: name, message: error.localizedDescription)
        }
    }

    public func resetClock() { lastTimestamp = nil }

    // MARK: Targets

    private func ensureTargets(for drawableSize: CGSize, commandBuffer: MTLCommandBuffer) {
        let scale = min(1, max(0.25, renderScale))
        let size = CGSize(width: max(1, (drawableSize.width * scale).rounded()),
                          height: max(1, (drawableSize.height * scale).rounded()))
        guard size != targetSize else { return }
        targetSize = size
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.textureFormat,
                                                                  width: Int(size.width), height: Int(size.height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        targets = manifest.passes.map { _ in [device.makeTexture(descriptor: descriptor)!, device.makeTexture(descriptor: descriptor)!] }
        current = Array(repeating: 0, count: manifest.passes.count)
        for pair in targets {
            for texture in pair {
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = texture
                rp.colorAttachments[0].loadAction = .clear
                rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                rp.colorAttachments[0].storeAction = .store
                commandBuffer.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
            }
        }
    }

    // MARK: MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        targetSize = .zero
    }

    public func draw(in view: MTKView) {
        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        ensureTargets(for: view.drawableSize, commandBuffer: commandBuffer)

        let now = CACurrentMediaTime()
        let dt = lastTimestamp.map { min(0.1, now - $0) } ?? 0
        lastTimestamp = now
        time += dt * speed
        frame += 1

        var uniforms = SceneUniforms(
            timeInfo: SIMD4(Float(time), Float(frame), Float(dt), 0),
            resolution: SIMD4(Float(targetSize.width), Float(targetSize.height),
                              Float(1 / targetSize.width), Float(1 / targetSize.height)),
            mouse: Self.mouse(for: view),
            audio: {
                let a = audioProvider()
                return SIMD4(a.bass, a.mid, a.treble, a.level)
            }()
        )

        for (index, pipeline) in pipelines.enumerated() {
            let target = targets[index][1 - current[index]]
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = target
            rp.colorAttachments[0].loadAction = .dontCare
            rp.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { continue }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 0)
            for slot in 0..<SceneManifest.maxPasses {
                let texture = slot < targets.count ? targets[slot][current[slot]] : dummy
                encoder.setFragmentTexture(texture, index: slot)
            }
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            current[index] = 1 - current[index]
        }

        if let rp = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
           let last = targets.indices.last,
           let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rp) {
            encoder.setRenderPipelineState(presentPipeline)
            encoder.setFragmentTexture(targets[last][current[last]], index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    private static func mouse(for view: MTKView) -> SIMD4<Float> {
        guard let frame = view.window?.screen?.frame, frame.width > 0, frame.height > 0 else { return .zero }
        let m = NSEvent.mouseLocation
        let inside: Float = frame.contains(m) ? 1 : 0
        return SIMD4(Float((m.x - frame.minX) / frame.width), Float((m.y - frame.minY) / frame.height), inside, 0)
    }
}
