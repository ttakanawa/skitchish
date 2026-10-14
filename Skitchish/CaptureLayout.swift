import CoreGraphics

/// Pure coordinate arithmetic shared by capture and geometry regression tests.
/// Input rectangles use Quartz global points; output destinations use bitmap pixels, bottom-up.
struct CaptureLayout {
    let bounds: CGRect
    let scale: CGFloat
    let pixelWidth: Int
    let pixelHeight: Int

    init(regions: [(rect: CGRect, scale: CGFloat)]) throws {
        guard !regions.isEmpty,
            regions.allSatisfy({ region in
                [region.rect.minX, region.rect.minY, region.rect.width, region.rect.height, region.scale].allSatisfy(
                    \.isFinite) && region.rect.width > 0 && region.rect.height > 0 && region.scale > 0
            })
        else { throw EditorServiceError.captureUnavailable }
        bounds = regions.reduce(CGRect.null) { $0.union($1.rect) }
        scale = regions.map(\.scale).max()!
        let width = (bounds.width * scale).rounded()
        let height = (bounds.height * scale).rounded()
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
            width <= 65536, height <= 65536, width * height <= ImageService.maximumPixelCount
        else {
            throw EditorServiceError.captureUnavailable
        }
        pixelWidth = Int(width)
        pixelHeight = Int(height)
    }

    func destinationRect(for globalRect: CGRect) -> CGRect {
        CGRect(
            x: (globalRect.minX - bounds.minX) * scale,
            y: CGFloat(pixelHeight) - (globalRect.maxY - bounds.minY) * scale,
            width: globalRect.width * scale, height: globalRect.height * scale)
    }

    static func sourceRect(for region: CGRect, on display: CGRect) -> CGRect {
        let intersection = region.intersection(display)
        guard !intersection.isNull else { return .null }
        return CGRect(
            x: intersection.minX - display.minX, y: intersection.minY - display.minY,
            width: intersection.width, height: intersection.height)
    }

    static func quartzPoint(_ appKitPoint: CGPoint, primaryDisplayTop: CGFloat) -> CGPoint {
        CGPoint(x: appKitPoint.x, y: primaryDisplayTop - appKitPoint.y)
    }

    static func quartzRect(_ appKitRect: CGRect, primaryDisplayTop: CGFloat) -> CGRect {
        CGRect(
            x: appKitRect.minX, y: primaryDisplayTop - appKitRect.maxY,
            width: appKitRect.width, height: appKitRect.height)
    }
}
