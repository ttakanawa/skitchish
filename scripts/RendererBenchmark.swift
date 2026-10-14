import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct RendererBenchmark {
    static let loops = 60
    static let warmups = 10
    static let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
        ".build/performance")

    static func bitmap(_ width: Int, _ height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    static func encode(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
    static func fixture(mixed: Bool) -> EditorDocument {
        let width = 3840
        let height = 2160
        let context = bitmap(3840, 2160)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width * 4 + x * 4
                bytes[index] = UInt8((x / 16 + y / 24) % 256)
                bytes[index + 1] = UInt8((x / 32 + y / 8) % 256)
                bytes[index + 2] = UInt8((x / 8 + y / 16) % 256)
                bytes[index + 3] = 255
            }
        }
        var document = EditorDocument(
            imageData: encode(context.makeImage()!), imageSize: CGSize(width: width, height: height))
        let tools: [EditorTool] = [
            .rectangle, .roundedRectangle, .ellipse, .line, .pen, .highlight, .text, .stamp, .pixelate, .arrow,
        ]
        document.annotations = (0..<100).map { index in
            let x = CGFloat(index % 10) * 360 + 20
            let y = CGFloat(index / 10) * 190 + 20
            let tool = mixed ? tools[index % tools.count] : (index % 2 == 0 ? .arrow : .rectangle)
            var points = [CGPoint(x: x, y: y), CGPoint(x: x + 200, y: y + 120)]
            if tool == .pen || tool == .highlight {
                points = (0..<20).map { offset in
                    CGPoint(x: x + CGFloat(offset) * 10, y: y + 60 + sin(CGFloat(offset) / 2) * 40)
                }
            }
            return Markup(
                tool: tool, points: points, color: .palette[index % RGBA.palette.count], size: 6,
                text: tool == .stamp ? "Note" : "日本語 ABC\nAnnotation", stamp: index % 5, tail: true)
        }
        return document
    }
    static func measure(
        document initial: EditorDocument, mixed: Bool, width: Int, height: Int, varyingZoom: Bool,
        interactiveZoom: Bool = false
    ) throws -> [String: Any] {
        var document = initial
        let renderer = EditorRenderer()
        let context = bitmap(width, height)
        context.interpolationQuality = interactiveZoom ? .low : .default
        let viewport = width == 2088
        let backing: CGFloat = viewport ? 2 : 1
        let logicalWidth = CGFloat(width) / backing
        let logicalHeight = CGFloat(height) / backing
        let fit: CGFloat = viewport ? min((logicalWidth - 96) / 3840, (logicalHeight - 96) / 2160) : 1
        let moving = document.annotations[99]
        var samples: [Double] = []
        for frame in (-warmups)..<loops {
            let tick = max(0, frame)
            let zoom = fit * (varyingZoom ? 0.75 + CGFloat(tick % 30) / 29 * 0.75 : 1)
            let start = DispatchTime.now().uptimeNanoseconds
            document.annotations[99] = moving.translated(dx: CGFloat(tick % 30), dy: sin(CGFloat(tick) / 5) * 8)
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: backing, y: -backing)
            if viewport {
                context.translateBy(
                    x: max(48, (logicalWidth - 3840 * zoom) / 2),
                    y: max(48, (logicalHeight - 2160 * zoom) / 2))
            }
            context.scaleBy(x: zoom, y: zoom)
            renderer.draw(document: document, in: context)
            context.restoreGState()
            context.flush()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if frame >= 0 { samples.append(elapsed) }
        }
        let ordered = samples.sorted()
        let median = (ordered[loops / 2 - 1] + ordered[loops / 2]) / 2
        let p95 = ordered[Int(ceil(Double(loops) * 0.95)) - 1]
        let mode = interactiveZoom ? "interactive_zoom" : (varyingZoom ? "zoom" : "drag")
        let name = "\(mixed ? "mixed" : "shapes")_\(viewport ? "viewport" : "full4k")_\(mode)"
        try encode(context.makeImage()!).write(to: root.appendingPathComponent(name + ".png"))
        return [
            "name": name, "annotation_count": 100, "source_pixels": [3840, 2160],
            "surface_pixels": [width, height], "backing_scale": Double(backing),
            "fit_zoom": Double(fit), "zoom_multiplier_range": varyingZoom ? [0.75, 1.5] : [1.0, 1.0],
            "display_interpolation": interactiveZoom ? "low (transient pinch display only)" : "default",
            "samples": loops, "warmups": warmups, "median_ms": median, "p95_ms": p95,
            "min_ms": ordered.first!, "max_ms": ordered.last!, "raw_ms": samples,
        ]
    }
    static func main() throws {
        var results: [[String: Any]] = []
        for mixed in [false, true] {
            let document = fixture(mixed: mixed)
            results.append(try measure(document: document, mixed: mixed, width: 3840, height: 2160, varyingZoom: false))
            results.append(try measure(document: document, mixed: mixed, width: 2088, height: 1404, varyingZoom: false))
            results.append(try measure(document: document, mixed: mixed, width: 2088, height: 1404, varyingZoom: true))
            results.append(
                try measure(
                    document: document, mixed: mixed, width: 2088, height: 1404, varyingZoom: true,
                    interactiveZoom: true))
        }
        let report: [String: Any] = [
            "compiler": ProcessInfo.processInfo.environment["SKITCHISH_BENCHMARK_COMPILER"]
                ?? "swiftc -O -whole-module-optimization",
            "hardware": ProcessInfo.processInfo.environment["SKITCHISH_BENCHMARK_HARDWARE"] ?? "Unreported",
            "operating_system": ProcessInfo.processInfo.operatingSystemVersionString,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "method":
                "CG bitmap only; no NSApplication/NSWindow, event loop, compositor, GPU timing, UI automation, or application launch. Timed region includes one annotation mutation, clearing reused surface, transforms, renderer.draw and CGContext.flush. Source decoding, contexts, caches, document construction and PNG encoding are outside timed region. Ten warmups precede60 samples. Viewport fits3840x2160 into1044x702 logical points minus48-point margins per side, rendered at2x backing. Zoom workload varies fit multiplier.75...1.5 while also dragging the last annotation. interactive_zoom uses low interpolation, matching transient Canvas pinch display; other workloads use default quality. Full4K is a reused export-sized draw surface, not an end-to-end export allocation/encoding measurement.",
            "fixtures": [
                "shapes": "50 arrows,50 rectangles",
                "mixed":
                    "10 each rectangle, roundedRectangle, ellipse, line,20-point pen,20-point highlighter, Japanese multiline text, stamp+label+tail, pixelation, arrow; last arrow moves after redactions so mosaic caches stay valid",
            ],
            "results": results,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("results.json"))
        for result in results {
            print(
                String(
                    format: "%@: median %.3f ms, p95 %.3f ms", result["name"] as! String,
                    result["median_ms"] as! Double, result["p95_ms"] as! Double))
        }
    }
}
