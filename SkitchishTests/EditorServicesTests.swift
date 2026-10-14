import AppKit
import ImageIO
import Testing

@testable import Skitchish

struct EditorServicesTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func image(width: Int = 20, height: Int = 12) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return try #require(context.makeImage())
    }

    private func document() throws -> EditorDocument {
        let source = try image()
        var document = EditorDocument(
            imageData: try ImageService.pngData(source),
            imageSize: CGSize(width: source.width, height: source.height), title: "日本語の下書き")
        document.annotations = [Markup(tool: .arrow, points: [CGPoint(x: 2, y: 3), CGPoint(x: 15, y: 9)])]
        return document
    }

    private func stampDocument() throws -> EditorDocument {
        let source = try image(width: 400, height: 200)
        var document = EditorDocument(
            imageData: try ImageService.pngData(source),
            imageSize: CGSize(width: 400, height: 200), title: "Legacy stamp")
        document.annotations = [
            .init(
                tool: .stamp, points: [CGPoint(x: 10, y: 40), CGPoint(x: 180, y: 80)],
                text: "Previously visible label", stamp: 2)
        ]
        return document
    }

    private func removeStampLayoutVersions(from package: URL) throws {
        let manifest = package.appendingPathComponent("document.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        var document = try #require(json["document"] as? [String: Any])
        var annotations = try #require(document["annotations"] as? [[String: Any]])
        for index in annotations.indices { annotations[index].removeValue(forKey: "stampLayoutVersion") }
        document["annotations"] = annotations
        json["document"] = document
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
    }

    @Test func legacyVisibleStampMigrationExpandsLeftOnceWithoutMovingOriginalContent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(baseURL: root)
        let url = root.appendingPathComponent("Legacy.skitchish")
        var original = try stampDocument()
        // This second mark is deliberately cropped. The first mark's expansion must
        // not make it eligible by changing the canvas used for the migration decision.
        original.annotations.append(
            .init(
                tool: .stamp,
                points: [CGPoint(x: -20, y: 120), CGPoint(x: 100, y: 150)],
                text: "A deliberately cropped and substantially longer old label"))
        try store.save(document: original, to: url)
        try removeStampLayoutVersions(from: url)
        let beforeManifest = try Data(contentsOf: url.appendingPathComponent("document.json"))
        let migrated = try store.load(from: url)
        var expected = original
        expected.expandCanvas(toInclude: original.annotations[0].visualBounds)
        #expect(migrated == expected)
        #expect(migrated.canvas.minX < original.canvas.minX)
        #expect(migrated.canvas.contains(migrated.annotations[0].visualBounds))
        #expect(migrated.annotations.map(\.points) == original.annotations.map(\.points))
        #expect(migrated.imageData == original.imageData && migrated.id == original.id)
        #expect(try Data(contentsOf: url.appendingPathComponent("document.json")) == beforeManifest)
        try store.save(document: migrated, to: url)
        #expect(try store.load(from: url) == migrated)
    }

    @Test func legacyStampMigrationPreservesCropsAndInterimSquareStampLayouts() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(baseURL: root)
        let url = root.appendingPathComponent("Cropped.skitchish")
        var cropped = try stampDocument()
        cropped.canvas = CGRect(x: 30, y: 0, width: 250, height: 200)
        try store.save(document: cropped, to: url)
        try removeStampLayoutVersions(from: url)
        #expect(try store.load(from: url) == cropped)

        var interim = try stampDocument()
        interim.annotations[0].points = [CGPoint(x: 10, y: 40), CGPoint(x: 50, y: 80)]
        #expect(!interim.canvas.contains(interim.annotations[0].stampLabelBounds))
        try store.save(document: interim, to: url)
        try removeStampLayoutVersions(from: url)
        #expect(try store.load(from: url) == interim)

        var empty = try stampDocument()
        empty.annotations[0].text = ""
        try store.save(document: empty, to: url)
        try removeStampLayoutVersions(from: url)
        #expect(try store.load(from: url) == empty)
    }

    @Test func currentStampCropSurvivesReloadAndRotatedLegacyLabelIsMigrated() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(baseURL: root)
        let url = root.appendingPathComponent("Current.skitchish")
        let current = try stampDocument()
        #expect(current.annotations[0].stampLayoutVersion == 1)
        #expect(!current.canvas.contains(current.annotations[0].stampLabelBounds))
        try store.save(document: current, to: url)
        #expect(try store.load(from: url) == current)

        var rotated = current
        rotated.rotateClockwise()
        try store.save(document: rotated, to: url)
        try removeStampLayoutVersions(from: url)
        let migrated = try store.load(from: url)
        #expect(migrated.canvas.contains(migrated.annotations[0].visualBounds))
        #expect(migrated.annotations[0].points == rotated.annotations[0].points)
        #expect(migrated.annotations[0].stampCircleBounds == rotated.annotations[0].stampCircleBounds)
    }

    @Test func packageRoundTripAndAtomicReplacement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Example.skitchish")
        let store = DocumentStore(baseURL: root)
        var expected = try document()
        try store.save(document: expected, to: url)
        #expect(try store.load(from: url) == expected)
        expected.title = "Edited"
        expected.rotateClockwise()
        try store.save(document: expected, to: url)
        #expect(try store.load(from: url) == expected)
        let children = try FileManager.default.contentsOfDirectory(atPath: url.path)
        #expect(Set(children) == Set(["document.json", "source.png"]))
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("document.json")))
                as? [String: Any])
        #expect((json["document"] as? [String: Any])?["imageData"] as? String == "")
    }

    @Test func openingSavedCopyPreservesNewerUnsavedDraft() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(baseURL: root.appendingPathComponent("Drafts"))
        let savedURL = root.appendingPathComponent("Saved.skitchish")
        var original = try document()
        try store.save(document: original, to: savedURL)
        original.title = "Newer unsaved work"
        try store.saveDraft(original)
        let reopened = try store.loadForEditing(from: savedURL)
        #expect(reopened.id != original.id)
        #expect(reopened.title != original.title)
        try store.saveDraft(reopened)
        let originalURL = store.baseURL.appendingPathComponent(original.id.uuidString + ".skitchish")
        #expect(try store.load(from: originalURL) == original)
        #expect(try store.loadForEditing(from: originalURL).id == original.id)
        #expect(try store.drafts().count == 2)
    }

    @Test func failedSaveKeepsPreviousDraftAndLatestPointer() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(baseURL: root)
        let good = try document()
        try store.saveDraft(good)
        var invalid = good
        invalid.canvas.size.width = 0
        #expect(throws: (any Error).self) { try store.saveDraft(invalid) }
        #expect(try store.latestDraft() == good)
        var second = try document()
        second.title = "Second"
        try store.saveDraft(second)
        #expect(try store.latestDraft() == second)
        let drafts = try store.drafts()
        #expect(drafts.count == 2)
        #expect(try drafts.map { try store.load(from: $0.url).id }.contains(good.id))
    }

    @Test func writePermissionFailurePreservesExistingDraft() throws {
        let root = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let store = DocumentStore(baseURL: root)
        let original = try document()
        try store.saveDraft(original)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        var changed = original
        changed.title = "Keep this edit in memory after failure"
        #expect(throws: (any Error).self) { try store.saveDraft(changed) }
        #expect(changed.title == "Keep this edit in memory after failure")
        #expect(try store.latestDraft() == original)
    }

    @Test func rejectsUnsupportedPackagesAndDamagedSource() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(baseURL: root)
        let url = root.appendingPathComponent("Example.skitchish")
        let original = try document()
        try store.save(document: original, to: url)
        let manifest = url.appendingPathComponent("document.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        json["formatVersion"] = 999
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        #expect(throws: (any Error).self) { try store.load(from: url) }
        try store.save(document: original, to: url)
        try Data("invalid image".utf8).write(to: url.appendingPathComponent("source.png"))
        #expect(throws: (any Error).self) { try store.load(from: url) }
    }

    @Test func pointerWriteFailureLeavesSavedPackagesRecoverable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(baseURL: root)
        let original = try document()
        try store.saveDraft(original)
        let pointer = root.appendingPathComponent("latest.json")
        try FileManager.default.removeItem(at: pointer)
        try FileManager.default.createDirectory(at: pointer, withIntermediateDirectories: false)
        let next = try document()
        #expect(throws: (any Error).self) { try store.saveDraft(next) }
        let drafts = try store.drafts()
        #expect(drafts.count == 2)
        #expect(try store.load(from: root.appendingPathComponent(original.id.uuidString + ".skitchish")) == original)
        #expect(try store.load(from: root.appendingPathComponent(next.id.uuidString + ".skitchish")) == next)
    }

    @Test func draftListingReadsOnlyManifestAndKeepsBrokenPackagesVisible() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(baseURL: root)
        let original = try document()
        try store.saveDraft(original)
        let package = root.appendingPathComponent(original.id.uuidString + ".skitchish")
        try FileManager.default.removeItem(at: package.appendingPathComponent("source.png"))
        let drafts = try store.drafts()
        #expect(drafts.count == 1 && drafts.first?.title == original.title)
        #expect(throws: (any Error).self) { try store.load(from: package) }
    }

    @Test func sourceValidationCacheDoesNotTrustChangedSourceOrDimensions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(baseURL: root)
        var modified = try document()
        try store.saveDraft(modified)
        let original = modified
        modified.imageSize.width += 1
        #expect(throws: (any Error).self) { try store.saveDraft(modified) }
        modified = original
        modified.imageData = Data("not an image".utf8)
        #expect(throws: (any Error).self) { try store.saveDraft(modified) }
        #expect(try store.latestDraft() == original)
    }

    @Test func rejectsOversizedSourceFileBeforeReading() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(baseURL: root)
        let original = try document()
        let package = root.appendingPathComponent("Large.skitchish")
        try store.save(document: original, to: package)
        let image = package.appendingPathComponent("source.png")
        let file = try FileHandle(forWritingTo: image)
        try file.truncate(atOffset: UInt64(ImageService.maximumEncodedBytes + 1))
        try file.close()
        #expect(throws: (any Error).self) { try store.load(from: package) }
        #expect(throws: (any Error).self) { try ImageService.image(from: image) }
    }

    @Test func encodedFormatsKeepPixelDimensionsAndFlattenJPEG() throws {
        let source = try image()
        for format in ExportFormat.allCases {
            let data = try ImageService.data(source, format: format)
            let decoded = try ImageService.image(from: data)
            #expect(decoded.width == 20)
            #expect(decoded.height == 12)
            let imageSource = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            #expect(CGImageSourceGetCount(imageSource) == 1)
            if format == .jpeg {
                var bytes = [UInt8](repeating: 0, count: 4)
                try bytes.withUnsafeMutableBytes { buffer in
                    let context = try #require(
                        CGContext(
                            data: buffer.baseAddress, width: 1, height: 1,
                            bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(decoded, in: CGRect(x: -18, y: 0, width: 20, height: 12))
                }
                #expect(bytes[0] > 245 && bytes[1] > 245 && bytes[2] > 245 && bytes[3] == 255)
            }
        }
    }

    @Test func importsEXIFOrientationAtFullResolution() throws {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination, try image(width: 80, height: 40), [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let result = try ImageService.image(from: data as Data)
        #expect(result.width == 40 && result.height == 80)
    }

    @Test @MainActor func clipboardContainsOnlyFlattenedImageTypes() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try ImageService.copy(try image(), to: pasteboard)
        let types = Set(pasteboard.types ?? [])
        #expect(types.contains(.png) && types.contains(.tiff))
        // AppKit also advertises the legacy aliases for PNG and TIFF to older applications.
        let imageTypes = Set([
            NSPasteboard.PasteboardType.png, .tiff,
            NSPasteboard.PasteboardType("Apple PNG pasteboard type"),
            NSPasteboard.PasteboardType("NeXT TIFF v4.0 pasteboard type"),
        ])
        #expect(types.isSubset(of: imageTypes))
        let imported = try #require(try ImageService.image(from: pasteboard))
        #expect(imported.width == 20 && imported.height == 12)
    }
}
