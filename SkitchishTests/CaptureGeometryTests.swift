import CoreGraphics
import Testing

@testable import Skitchish

struct CaptureGeometryTests {
    @Test func retinaDisplayUsesPhysicalPixelsWithoutChangingPointOrigin() throws {
        let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let layout = try CaptureLayout(regions: [(display, 2)])
        #expect(layout.pixelWidth == 5120 && layout.pixelHeight == 2880)
        #expect(layout.scale == 2)
        #expect(layout.destinationRect(for: display) == CGRect(x: 0, y: 0, width: 5120, height: 2880))
        let area = CGRect(x: 320, y: 200, width: 640, height: 480)
        #expect(CaptureLayout.sourceRect(for: area, on: display) == area)
    }

    @Test func mixedDensityRegionAcrossNegativeXHasNoSeamOffset() throws {
        let leftDisplay = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let rightDisplay = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let selection = CGRect(x: -100, y: 100, width: 300, height: 200)
        let left = selection.intersection(leftDisplay)
        let right = selection.intersection(rightDisplay)
        let layout = try CaptureLayout(regions: [(left, 1), (right, 2)])
        #expect(layout.bounds == selection)
        #expect(layout.scale == 2 && layout.pixelWidth == 600 && layout.pixelHeight == 400)
        let leftDestination = layout.destinationRect(for: left)
        let rightDestination = layout.destinationRect(for: right)
        #expect(leftDestination == CGRect(x: 0, y: 0, width: 200, height: 400))
        #expect(rightDestination == CGRect(x: 200, y: 0, width: 400, height: 400))
        #expect(leftDestination.maxX == rightDestination.minX)
        #expect(
            CaptureLayout.sourceRect(for: selection, on: leftDisplay)
                == CGRect(x: 1340, y: 100, width: 100, height: 200))
        #expect(
            CaptureLayout.sourceRect(for: selection, on: rightDisplay) == CGRect(x: 0, y: 100, width: 200, height: 200))
    }

    @Test func mixedDensityScreensAbovePrimaryRespectQuartzAndBitmapYDirections() throws {
        let upperDisplay = CGRect(x: -1200, y: -900, width: 1200, height: 900)
        let primaryDisplay = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let selection = CGRect(x: -200, y: -300, width: 500, height: 500)
        let upper = selection.intersection(upperDisplay)
        let lower = selection.intersection(primaryDisplay)
        let layout = try CaptureLayout(regions: [(upper, 1), (lower, 2)])
        #expect(layout.pixelWidth == 1000 && layout.pixelHeight == 1000)
        #expect(layout.destinationRect(for: upper) == CGRect(x: 0, y: 400, width: 400, height: 600))
        #expect(layout.destinationRect(for: lower) == CGRect(x: 400, y: 0, width: 600, height: 400))
        #expect(
            CaptureLayout.sourceRect(for: selection, on: upperDisplay)
                == CGRect(x: 1000, y: 600, width: 200, height: 300))
        #expect(
            CaptureLayout.sourceRect(for: selection, on: primaryDisplay) == CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    @Test func displayGapsStayInTheirCorrectBitmapPosition() throws {
        let left = CGRect(x: -300, y: 20, width: 100, height: 200)
        let right = CGRect(x: 0, y: 20, width: 100, height: 200)
        let layout = try CaptureLayout(regions: [(left, 2), (right, 1)])
        #expect(layout.pixelWidth == 800)
        #expect(layout.destinationRect(for: left).maxX == 200)
        #expect(layout.destinationRect(for: right).minX == 600)
        #expect(CaptureLayout.sourceRect(for: left, on: right).isNull)
    }

    @Test func appKitScreenCoordinatesFlipAroundPrimaryDisplayTop() {
        #expect(
            CaptureLayout.quartzPoint(CGPoint(x: -100, y: 1540), primaryDisplayTop: 1440) == CGPoint(x: -100, y: -100))
        let rect = CGRect(x: -200, y: 1440, width: 400, height: 300)
        let quartz = CaptureLayout.quartzRect(rect, primaryDisplayTop: 1440)
        #expect(quartz == CGRect(x: -200, y: -300, width: 400, height: 300))
        #expect(CaptureLayout.quartzRect(quartz, primaryDisplayTop: 1440) == rect)
    }

    @Test func rejectsEmptyInvalidAndOversizedCaptureLayouts() {
        #expect(throws: (any Error).self) { try CaptureLayout(regions: []) }
        #expect(throws: (any Error).self) { try CaptureLayout(regions: [(.zero, 2)]) }
        #expect(throws: (any Error).self) {
            try CaptureLayout(regions: [(CGRect(x: 0, y: 0, width: 10, height: 10), 0)])
        }
        #expect(throws: (any Error).self) {
            try CaptureLayout(regions: [(CGRect(x: 0, y: 0, width: 10000, height: 10000), 2)])
        }
    }
}
