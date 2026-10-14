import AppKit

/// Persisted coordinates are image pixels, measured from the upper-left.
enum EditorTool: String, Codable, CaseIterable {
    case select, arrow, text, rectangle, roundedRectangle, ellipse, line, pen, highlight, pixelate, stamp, crop
}

struct RGBA: Codable, Equatable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat = 1
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var cgColor: CGColor { nsColor.cgColor }
    var isValid: Bool { [r, g, b, a].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    /// Skitch's presets were authored in calibrated RGB. Store their sRGB equivalents
    /// so a saved document keeps the same color on screen and in an exported image.
    private static func preset(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> RGBA {
        let color = NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1).usingColorSpace(.sRGB)!
        return RGBA(r: color.redComponent, g: color.greenComponent, b: color.blueComponent)
    }
    static let palette: [RGBA] = [
        preset(1, 0, 0), preset(1, 128.0 / 255, 23.0 / 255),
        preset(1, 247.0 / 255, 0), preset(0, 232.0 / 255, 0),
        preset(25.0 / 255, 119.0 / 255, 1), preset(252.0 / 255, 12.0 / 255, 89.0 / 255),
        .init(r: 1, g: 1, b: 1), .init(r: 0, g: 0, b: 0),
    ]
}

struct PixelTransform: Codable, Equatable {
    var a: CGFloat = 1
    var b: CGFloat = 0
    var c: CGFloat = 0
    var d: CGFloat = 1
    var tx: CGFloat = 0
    var ty: CGFloat = 0
    init() {}
    init(_ t: CGAffineTransform) {
        a = t.a
        b = t.b
        c = t.c
        d = t.d
        tx = t.tx
        ty = t.ty
    }
    var cgAffineTransform: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}

struct Markup: Codable, Equatable, Identifiable {
    var id = UUID()
    var tool: EditorTool
    var points: [CGPoint] = []
    var color: RGBA = .palette[0]
    var size: CGFloat = 5
    var text = ""
    var stamp = 0
    var tail = false
    /// Clockwise octants in local coordinates: east, southeast, south ... northeast.
    /// Missing in older packages; their enabled pointer defaults to southeast.
    var tailDirection: Int?
    /// Nil when decoded from packages predating independent left-side stamp labels.
    var stampLayoutVersion: Int? = 1
    var quarterTurns = 0
    var mirrored = false
    init(
        tool: EditorTool, points: [CGPoint] = [], color: RGBA = .palette[0], size: CGFloat = 5,
        text: String = "", stamp: Int = 0, tail: Bool = false, tailDirection: Int? = nil
    ) {
        self.tool = tool
        self.points = points
        self.color = color
        self.size = size
        self.text = text
        self.stamp = stamp
        self.tail = tail
        self.tailDirection = tailDirection
    }
}

struct EditorDocument: Codable, Equatable {
    var version = 1
    var id = UUID()
    var title: String
    var imageData: Data
    var imageSize: CGSize
    var canvas: CGRect
    var imageTransform = PixelTransform()
    var annotations: [Markup] = []

    init(imageData: Data, imageSize: CGSize, title: String = "Untitled") {
        self.imageData = imageData
        self.imageSize = imageSize
        self.title = title
        canvas = CGRect(origin: .zero, size: imageSize)
    }
    var outputSize: CGSize { canvas.integral.size }
    mutating func crop(to rect: CGRect) {
        let intersection = canvas.intersection(rect.standardized).integral
        if !intersection.isNull && intersection.width >= 1 && intersection.height >= 1 { canvas = intersection }
    }
    mutating func expandCanvas(toInclude rect: CGRect, padding: CGFloat = 16) {
        guard !canvas.contains(rect) else { return }
        canvas = canvas.union(rect.insetBy(dx: -padding, dy: -padding)).integral
    }
    mutating func resize(to size: CGSize) {
        guard size.width >= 1, size.height >= 1, canvas.width > 0, canvas.height > 0 else { return }
        let sx = size.width / canvas.width
        let sy = size.height / canvas.height
        let t = CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: -canvas.minX * sx, ty: -canvas.minY * sy)
        apply(t, strokeScale: sqrt(sx * sy))
        canvas = CGRect(origin: .zero, size: size).integral
    }
    mutating func rotateClockwise() {
        let t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: canvas.maxY, ty: -canvas.minX)
        let old = canvas
        apply(t)
        for index in annotations.indices { annotations[index].quarterTurns = (annotations[index].quarterTurns + 1) % 4 }
        canvas = CGRect(x: 0, y: 0, width: old.height, height: old.width)
    }
    mutating func flip(horizontal: Bool) {
        let t =
            horizontal
            ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: canvas.minX + canvas.maxX, ty: 0)
            : CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: canvas.minY + canvas.maxY)
        apply(t)
        for index in annotations.indices {
            annotations[index].mirrored.toggle()
            annotations[index].quarterTurns = (4 - annotations[index].quarterTurns + (horizontal ? 0 : 2)) % 4
        }
    }
    private mutating func apply(_ transform: CGAffineTransform, strokeScale: CGFloat = 1) {
        imageTransform = PixelTransform(imageTransform.cgAffineTransform.concatenating(transform))
        for index in annotations.indices {
            annotations[index].points = annotations[index].points.map { $0.applying(transform) }
            annotations[index].size *= strokeScale
        }
    }
    func validate() throws {
        guard version == 1 else { throw EditorRenderError.unsupportedVersion }
        guard hasValidContent else { throw EditorRenderError.invalidDocument }
        guard hasValidDimensions, annotations.allSatisfy(\.hasValidGeometry) else {
            throw EditorRenderError.invalidDimensions
        }
    }

    private var hasValidContent: Bool {
        imageData.count <= DocumentLimits.encodedBytes && title.utf8.count <= DocumentLimits.titleBytes
            && annotations.count <= DocumentLimits.annotations
            && annotations.lazy.filter { $0.tool == .pixelate }.count <= DocumentLimits.pixelations
            && annotations.reduce(0) { $0 + $1.points.count } <= DocumentLimits.points
            && annotations.reduce(0) { $0 + $1.text.utf8.count } <= DocumentLimits.textBytes
            && Set(annotations.map(\.id)).count == annotations.count
    }

    private var hasValidDimensions: Bool {
        imageSize.width > 0 && imageSize.height > 0
            && [
                imageSize.width, imageSize.height, canvas.minX, canvas.minY, canvas.width, canvas.height,
                imageTransform.a, imageTransform.b, imageTransform.c, imageTransform.d,
                imageTransform.tx, imageTransform.ty,
            ].allSatisfy(DocumentLimits.containsCoordinate) && canvas.width >= 1 && canvas.height >= 1
            && canvas.width * canvas.height <= DocumentLimits.pixels
            && imageSize.width * imageSize.height <= DocumentLimits.pixels
            && abs(imageTransform.a * imageTransform.d - imageTransform.b * imageTransform.c)
                > DocumentLimits.minimumDeterminant
    }
}

extension Markup {
    fileprivate var hasValidGeometry: Bool {
        size > 0 && DocumentLimits.containsCoordinate(size) && !points.isEmpty
            && ([EditorTool.pen, .highlight].contains(tool) || points.count >= 2)
            && ![EditorTool.select, .crop].contains(tool) && (0...4).contains(stamp) && (0...3).contains(quarterTurns)
            && (tailDirection.map { (0...7).contains($0) } ?? true)
            && (stampLayoutVersion == nil || stampLayoutVersion == 1) && color.isValid
            && points.allSatisfy { DocumentLimits.containsCoordinate($0.x) && DocumentLimits.containsCoordinate($0.y) }
    }
}

private enum DocumentLimits {
    static let encodedBytes = 256_000_000
    static let titleBytes = 16_384
    static let annotations = 10_000
    static let pixelations = 128
    static let points = 1_000_000
    static let textBytes = 1_000_000
    static let pixels: CGFloat = 150_000_000
    static let minimumDeterminant: CGFloat = 0.000_000_001

    static func containsCoordinate(_ value: CGFloat) -> Bool {
        value.isFinite && abs(value) < 1_000_000
    }
}

enum EditorRenderError: LocalizedError {
    case invalidImage, invalidDimensions, invalidDocument, unsupportedVersion, allocationFailed
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "The image could not be decoded."
        case .invalidDimensions: return "The image dimensions or annotation coordinates are invalid or too large."
        case .invalidDocument:
            return "The document contains invalid annotations or exceeds the supported editing limits."
        case .unsupportedVersion: return "This document was saved by an unsupported version of Skitchish."
        case .allocationFailed: return "There is not enough memory to render this image."
        }
    }
}
