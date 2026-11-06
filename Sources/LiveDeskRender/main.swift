import Foundation
import LiveDeskKit

// livedesk-render <scene-folder> <output.mov> [--width N] [--height N] [--fps N] [--duration S] [--crossfade S] [--bitrate BPS]

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: livedesk-render <scene-folder> <output.mov> [--width 3840] [--height 2160] [--fps 30]
                           [--duration 20] [--crossfade 3] [--bitrate 18000000]

    """.utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { usage() }
let folder = URL(fileURLWithPath: args.removeFirst())
let output = URL(fileURLWithPath: args.removeFirst())
var options = OfflineRenderOptions()

while !args.isEmpty {
    let flag = args.removeFirst()
    guard !args.isEmpty else { usage() }
    let value = args.removeFirst()
    switch flag {
    case "--width": options.width = Int(value) ?? options.width
    case "--height": options.height = Int(value) ?? options.height
    case "--fps": options.fps = Int(value) ?? options.fps
    case "--duration": options.duration = Double(value) ?? options.duration
    case "--crossfade": options.crossfade = Double(value) ?? options.crossfade
    case "--bitrate": options.bitrate = Int(value) ?? options.bitrate
    default: usage()
    }
}

let start = Date()
var lastPrinted = -1
do {
    try OfflineSceneRenderer.render(folder: folder, to: output, options: options) { fraction in
        let pct = Int(fraction * 100)
        if pct / 10 != lastPrinted / 10 {
            lastPrinted = pct
            FileHandle.standardError.write(Data("\r\(folder.lastPathComponent): \(pct)%".utf8))
        }
    }
    print("\n\(output.path) (\(options.width)x\(options.height), \(options.frameCount) frames) in \(Int(Date().timeIntervalSince(start)))s")
} catch {
    FileHandle.standardError.write(Data("\nerror: \(error.localizedDescription)\n".utf8))
    exit(1)
}
