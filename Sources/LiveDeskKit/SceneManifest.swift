import Foundation

/// Description of an interactive scene: a folder with `manifest.json` plus up to 8 Metal shader passes.
///
/// Each pass is a fragment function compiled together with `SceneShaderHeader.source`.
/// Pass `i` can sample the latest output of every pass via `passes[k]`
/// (passes before `i` from this frame, the others — itself included — from the previous frame).
public struct SceneManifest: Codable, Equatable, Sendable {
    public static let maxPasses = 8
    public static let fileName = "manifest.json"

    public struct Pass: Codable, Equatable, Sendable {
        public var source: String
        public var function: String

        public init(source: String, function: String) {
            self.source = source
            self.function = function
        }
    }

    public var id: UUID?
    public var name: String
    public var passes: [Pass]
    public var usesAudio: Bool?
    public var usesMouse: Bool?

    public init(id: UUID? = nil, name: String, passes: [Pass], usesAudio: Bool? = nil, usesMouse: Bool? = nil) {
        self.id = id
        self.name = name
        self.passes = passes
        self.usesAudio = usesAudio
        self.usesMouse = usesMouse
    }

    public var needsAudio: Bool { usesAudio ?? false }

    /// Loads and validates a scene folder.
    public static func load(from folder: URL) throws -> SceneManifest {
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { throw SceneManifestError.missingManifest }
        let manifest: SceneManifest
        do {
            manifest = try JSONDecoder().decode(SceneManifest.self, from: data)
        } catch {
            throw SceneManifestError.invalidJSON(String(describing: error))
        }
        try manifest.validate(in: folder)
        return manifest
    }

    public func validate(in folder: URL) throws {
        guard !passes.isEmpty else { throw SceneManifestError.noPasses }
        guard passes.count <= Self.maxPasses else { throw SceneManifestError.tooManyPasses(passes.count) }
        for pass in passes {
            let name = pass.source
            if name.contains("/") || name.contains("\\") || name.hasPrefix(".") {
                throw SceneManifestError.invalidPath(name)
            }
            guard (name as NSString).pathExtension.lowercased() == "metal" else {
                throw SceneManifestError.notMetal(name)
            }
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) else {
                throw SceneManifestError.missingSource(name)
            }
            guard !pass.function.isEmpty, pass.function.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                throw SceneManifestError.invalidFunction(pass.function)
            }
        }
    }
}

public enum SceneManifestError: Error, Equatable, LocalizedError {
    case missingManifest
    case invalidJSON(String)
    case noPasses
    case tooManyPasses(Int)
    case notMetal(String)
    case missingSource(String)
    case invalidPath(String)
    case invalidFunction(String)

    public var errorDescription: String? {
        switch self {
        case .missingManifest: return "manifest.json mancante"
        case .invalidJSON(let e): return "manifest.json non valido: \(e)"
        case .noPasses: return "la scena non ha pass"
        case .tooManyPasses(let n): return "troppi pass (\(n)), massimo \(SceneManifest.maxPasses)"
        case .notMetal(let s): return "\(s) non è un file .metal"
        case .missingSource(let s): return "file \(s) mancante"
        case .invalidPath(let s): return "percorso non valido: \(s)"
        case .invalidFunction(let s): return "nome funzione non valido: \(s)"
        }
    }
}

/// Metal source prepended to every scene pass.
public enum SceneShaderHeader {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct LDVertexOut {
        float4 position [[position]];
        float2 uv;   // 0...1, origin bottom-left (y up)
    };

    struct LDUniforms {
        float4 timeInfo;    // x: seconds, y: frame index, z: delta seconds
        float4 resolution;  // xy: pixels, zw: 1/pixels
        float4 mouse;       // xy: cursor 0...1 (y up), z: 1 if cursor is on this screen
        float4 audio;       // x: bass, y: mid, z: treble, w: overall level (0...1)
    };

    // Texture coordinate for sampling a pass output at uv.
    inline float2 ld_tc(float2 uv) { return float2(uv.x, 1.0 - uv.y); }

    vertex LDVertexOut ld_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        LDVertexOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = p;
        return o;
    }

    fragment float4 ld_present(LDVertexOut in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               sampler smp [[sampler(0)]]) {
        return float4(src.sample(smp, ld_tc(in.uv)).rgb, 1.0);
    }

    """
}
