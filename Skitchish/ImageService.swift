import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageService {
    static let maximumEncodedBytes = 256_000_000
    static let maximumPixelCount = 150_000_000.0

    static func image(from url: URL) throws -> CGImage {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard try (url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= maximumEncodedBytes else {
            throw EditorServiceError.invalidImage
        }
        return try image(from: Data(contentsOf: url))
    }

    /// Image I/O applies EXIF orientation at the original pixel size, independently of NSImage points.
    static func image(from data: Data) throws -> CGImage {
        let (source, size) = try validatedSource(data)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw EditorServiceError.invalidImage
        }
        return image
    }

    /// Inspect the encoded header before asking Image I/O to allocate a decoded bitmap.
    static func validatedSource(_ data: Data) throws -> (CGImageSource, CGSize) {
        guard data.count <= maximumEncodedBytes,
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
            width.doubleValue.isFinite, height.doubleValue.isFinite,
            width.doubleValue >= 1, height.doubleValue >= 1,
            width.doubleValue <= 65536, height.doubleValue <= 65536,
            width.doubleValue * height.doubleValue <= maximumPixelCount
        else {
            throw EditorServiceError.invalidImage
        }
        return (source, CGSize(width: width.doubleValue, height: height.doubleValue))
    }

    @MainActor static func image(from pasteboard: NSPasteboard) throws -> CGImage? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return try image(from: data) }
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL],
            let url = urls.first
        {
            return try image(from: url)
        }
        // Some applications publish only another Image I/O format, such as public.jpeg.
        for type in pasteboard.types ?? [] {
            if let uniformType = UTType(type.rawValue), uniformType.conforms(to: .image),
                let data = pasteboard.data(forType: type)
            {
                return try image(from: data)
            }
        }
        return nil
    }

    static func pngData(_ image: CGImage) throws -> Data { try data(image, format: .png) }

    static func data(_ image: CGImage, format: ExportFormat) throws -> Data {
        var output = image
        if format == .jpeg {
            guard
                let context = CGContext(
                    data: nil, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else {
                throw EditorServiceError.encodingFailed
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flattened = context.makeImage() else { throw EditorServiceError.encodingFailed }
            output = flattened
        }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(data, format.contentType.identifier as CFString, 1, nil)
        else {
            throw EditorServiceError.encodingFailed
        }
        // Encode only the rendered pixels. No source image, document, or source metadata is copied.
        let properties: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.95] : [:]
        CGImageDestinationAddImage(destination, output, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EditorServiceError.encodingFailed }
        return data as Data
    }

    static func write(_ image: CGImage, to url: URL, format: ExportFormat) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try data(image, format: format).write(to: url, options: .atomic)
    }

    @MainActor static func copy(_ image: CGImage, to pasteboard: NSPasteboard = .general) throws {
        let png = try data(image, format: .png)
        let tiff = try data(image, format: .tiff)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        guard pasteboard.writeObjects([item]) else { throw EditorServiceError.encodingFailed }
    }
}
