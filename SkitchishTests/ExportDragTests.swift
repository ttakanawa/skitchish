import AppKit
import Testing

@testable import Skitchish

struct ExportDragTests {
    private func rootDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func payload(red: CGFloat = 1, title: String = "Chat Image", format: ExportFormat = .png) throws
        -> ExportPayload
    {
        let context = try #require(
            CGContext(
                data: nil, width: 24, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 16))
        return ExportPayload(image: try #require(context.makeImage()), title: title, format: format)
    }

    @Test func snapshotMaterializesTheSelectedFormatAndImageRepresentations() throws {
        let root = try rootDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for format in ExportFormat.allCases {
            let snapshot = try ExportDragSnapshot(payload: payload(format: format), temporaryRoot: root)
            #expect(snapshot.fileURL.pathExtension == format.fileExtension)
            #expect(try Data(contentsOf: snapshot.fileURL) == snapshot.fileData)
            for data in [snapshot.fileData, snapshot.pngData, snapshot.tiffData] {
                let image = try ImageService.image(from: data)
                #expect(image.width == 24 && image.height == 16)
            }
        }
    }

    @Test func filenamesAreSafeAndBoundedWithoutLosingJapaneseText() {
        let name = ExportDragSnapshot.filename(title: "../日本語/画像:\\\n.png", format: .png)
        #expect(
            !name.hasPrefix(".") && !name.contains("/") && !name.contains(":") && !name.contains("\\")
                && !name.contains("\n"))
        #expect(name.contains("日本語") && name.hasSuffix(".png") && !name.hasSuffix(".png.png"))
        #expect(ExportDragSnapshot.filename(title: "...", format: .jpeg) == "Image.jpg")
        let longName = ExportDragSnapshot.filename(title: String(repeating: "注釈", count: 1000), format: .tiff)
        #expect(longName.utf8.count <= 185 && longName.hasSuffix(".tiff"))
    }

    @Test @MainActor func onePasteboardItemOffersPromiseFileURLAndFlattenedImages() throws {
        let root = try rootDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try ExportDragSnapshot(payload: payload(), temporaryRoot: root)
        let provider = ExportImageDragProvider(snapshot: snapshot)
        let pasteboard = NSPasteboard.withUniqueName()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let types = provider.writableTypes(for: pasteboard)
        #expect(types.contains(.fileURL) && types.contains(.png) && types.contains(.tiff))
        #expect(!Set(types.map(\.rawValue)).intersection(NSFilePromiseReceiver.readableDraggedTypes).isEmpty)
        #expect(pasteboard.writeObjects([provider]))
        #expect(pasteboard.pasteboardItems?.count == 1)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(urls == [snapshot.fileURL])
        #expect(pasteboard.data(forType: .png) == snapshot.pngData)
        #expect(pasteboard.data(forType: .tiff) == snapshot.tiffData)
        #expect(!types.contains(NSPasteboard.PasteboardType("com.skitchish.annotations.v1")))
    }

    @Test @MainActor func delayedPromisesKeepTheirOwnBytesAndCanBeReadMoreThanOnce() throws {
        let root = try rootDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try ExportDragSnapshot(payload: payload(red: 1), temporaryRoot: root)
        let second = try ExportDragSnapshot(payload: payload(red: 0), temporaryRoot: root)
        #expect(first.fileURL != second.fileURL && first.fileData != second.fileData)
        let firstProvider = ExportImageDragProvider(snapshot: first)
        let secondProvider = ExportImageDragProvider(snapshot: second)
        for (provider, expected, filename) in [
            (secondProvider, second, "second.png"), (firstProvider, first, "first.png"),
            (firstProvider, first, "first-again.png"),
        ] {
            let destination = root.appendingPathComponent(filename)
            let delegate = try #require(provider.delegate)
            #expect(
                delegate.filePromiseProvider(provider, fileNameForType: provider.fileType)
                    == expected.fileURL.lastPathComponent)
            var completions = 0
            delegate.filePromiseProvider(provider, writePromiseTo: destination) { error in
                #expect(error == nil)
                completions += 1
            }
            #expect(completions == 1)
            #expect(try Data(contentsOf: destination) == expected.fileData)
        }
    }

    @Test func materializedFileOutlivesTheDragWriterForAsynchronousReaders() throws {
        let root = try rootDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url: URL
        let bytes: Data
        do {
            let provider = ExportImageDragProvider(
                snapshot: try ExportDragSnapshot(payload: payload(), temporaryRoot: root))
            url = provider.snapshot.fileURL
            bytes = provider.snapshot.fileData
        }
        #expect(try Data(contentsOf: url) == bytes)
    }
}
