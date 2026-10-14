import AppKit
import Darwin
import ImageIO

final class DocumentStore {
    private struct Manifest: Codable {
        var formatVersion: Int
        var document: EditorDocument
    }
    private struct Summary: Decodable {
        struct Metadata: Decodable { var title: String }
        var document: Metadata
    }
    private struct Latest: Codable { var filename: String }
    let baseURL: URL
    private let fileManager = FileManager.default
    private var validatedImage: (data: Data, size: CGSize)?

    init(baseURL: URL? = nil) {
        self.baseURL =
            baseURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skitchish/Drafts", isDirectory: true)
    }

    func save(document: EditorDocument, to url: URL) throws {
        try validate(document)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var metadata = document
        metadata.imageData = Data()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = try encoder.encode(Manifest(formatVersion: 1, document: metadata))
        // Obtain a sandbox-compatible staging directory on the destination's volume. Never
        // ask FileWrapper to replace a package: it can remove old children before a failed move.
        let replacement = try fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: url, create: true)
        defer { try? fileManager.removeItem(at: replacement) }
        let stagedPackage = replacement.appendingPathComponent("document.skitchish", isDirectory: true)
        try fileManager.createDirectory(
            at: stagedPackage, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try writeStaged(manifest, to: stagedPackage.appendingPathComponent("document.json"))
        try writeStaged(document.imageData, to: stagedPackage.appendingPathComponent("source.png"))
        let flags = fileManager.fileExists(atPath: url.path) ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
        let installError: Int32? = stagedPackage.withUnsafeFileSystemRepresentation { stagedPath in
            url.withUnsafeFileSystemRepresentation { destinationPath in
                guard let stagedPath, let destinationPath else { return EINVAL }
                if renameatx_np(AT_FDCWD, stagedPath, AT_FDCWD, destinationPath, flags) == 0 { return nil }
                return errno
            }
        }
        if let installError {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(installError), userInfo: [NSFilePathErrorKey: url.path])
        }
        // On a successful swap only, staging now contains the old package. The defer removes it.
        // Unsupported-volume and permission errors leave the original package intact.
    }

    private func writeStaged(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    func load(from url: URL) throws -> EditorDocument {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let metadataURL = url.appendingPathComponent("document.json")
        let sourceURL = url.appendingPathComponent("source.png")
        guard (try metadataURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 < 32_000_000 else {
            throw EditorServiceError.invalidDocument
        }
        let data = try Data(contentsOf: metadataURL)
        let header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let version = header?["formatVersion"] as? Int else { throw EditorServiceError.invalidDocument }
        guard version == 1 else { throw EditorServiceError.unsupportedVersion(version) }
        var document = try JSONDecoder().decode(Manifest.self, from: data).document
        guard (try sourceURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= ImageService.maximumEncodedBytes
        else {
            throw EditorServiceError.invalidDocument
        }
        document.imageData = try Data(contentsOf: sourceURL)
        try validate(document)
        migrateLegacyStampLayouts(in: &document)
        try validate(document)
        return document
    }

    private func migrateLegacyStampLayouts(in document: inout EditorDocument) {
        let originalCanvas = document.canvas
        for index in document.annotations.indices {
            let old = document.annotations[index]
            guard old.tool == .stamp, old.stampLayoutVersion == nil else { continue }
            document.annotations[index].stampLayoutVersion = 1
            let localSize = old.localSize
            // Old labels occupied the right part of a wide persisted rectangle. New
            // labels extend left of the unchanged circle. Preserve an intentional crop,
            // including square stamps from the interim build without a layout marker.
            if !old.text.isEmpty, localSize.width > localSize.height + 0.001,
                originalCanvas.contains(old.bounds)
            {
                document.expandCanvas(toInclude: document.annotations[index].visualBounds)
            }
        }
    }

    /// Opening a saved copy starts a separate working draft; restoring a draft retains its identity.
    func loadForEditing(from url: URL) throws -> EditorDocument {
        var document = try load(from: url)
        if url.deletingLastPathComponent().standardizedFileURL != baseURL.standardizedFileURL {
            document.id = UUID()
        }
        return document
    }

    func saveDraft(_ document: EditorDocument) throws {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let filename = document.id.uuidString + ".skitchish"
        try save(document: document, to: baseURL.appendingPathComponent(filename, isDirectory: true))
        // The latest pointer advances only after a successful package save.
        try JSONEncoder().encode(Latest(filename: filename)).write(
            to: baseURL.appendingPathComponent("latest.json"), options: .atomic)
    }

    func latestDraft() throws -> EditorDocument? {
        let pointer = baseURL.appendingPathComponent("latest.json")
        guard fileManager.fileExists(atPath: pointer.path) else { return nil }
        guard (try pointer.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= 4096 else {
            throw EditorServiceError.invalidDocument
        }
        let latest = try JSONDecoder().decode(Latest.self, from: Data(contentsOf: pointer))
        guard latest.filename == URL(fileURLWithPath: latest.filename).lastPathComponent,
            latest.filename.hasSuffix(".skitchish")
        else { throw EditorServiceError.invalidDocument }
        return try load(from: baseURL.appendingPathComponent(latest.filename))
    }

    /// Explicitly discard only this working copy, never an externally saved document.
    func discardDraft(id: UUID) throws {
        let filename = id.uuidString + ".skitchish"
        let package = baseURL.appendingPathComponent(filename, isDirectory: true)
        let pointer = baseURL.appendingPathComponent("latest.json")
        var removedPointer: Data?
        if fileManager.fileExists(atPath: pointer.path) {
            let data = try Data(contentsOf: pointer)
            let latest = try JSONDecoder().decode(Latest.self, from: data)
            if latest.filename == filename {
                try fileManager.removeItem(at: pointer)
                removedPointer = data
            }
        }
        do {
            if fileManager.fileExists(atPath: package.path) {
                try fileManager.removeItem(at: package)
            }
        } catch {
            if let removedPointer { try removedPointer.write(to: pointer, options: .atomic) }
            throw error
        }
    }

    func drafts() throws -> [(title: String, url: URL)] {
        guard fileManager.fileExists(atPath: baseURL.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(
            at: baseURL, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
        )
        .filter { $0.pathExtension == "skitchish" }
        .sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast)
        }
        return files.map { url in
            // Keep even damaged packages visible so a failed draft is never silently discarded.
            let title =
                (try? draftTitle(at: url)) ?? "Unreadable draft — \(url.deletingPathExtension().lastPathComponent)"
            return (title, url)
        }
    }

    private func draftTitle(at url: URL) throws -> String {
        let manifest = url.appendingPathComponent("document.json")
        guard (try manifest.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 < 32_000_000 else {
            throw EditorServiceError.invalidDocument
        }
        let title = try JSONDecoder().decode(Summary.self, from: Data(contentsOf: manifest)).document.title
        return String(title.prefix(200))
    }

    private func validate(_ document: EditorDocument) throws {
        try document.validate()
        let rect = document.canvas
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
            rect.width > 0, rect.height > 0, rect.width <= 65536, rect.height <= 65536,
            rect.width * rect.height <= 268_435_456,
            document.imageSize.width > 0, document.imageSize.height > 0
        else {
            throw EditorServiceError.invalidDocument
        }
        if let validatedImage, validatedImage.size == document.imageSize, validatedImage.data == document.imageData {
            return
        }
        let (source, size) = try ImageService.validatedSource(document.imageData)
        guard size == document.imageSize,
            let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
            image.width == Int(size.width), image.height == Int(size.height)
        else {
            throw EditorServiceError.invalidDocument
        }
        validatedImage = (document.imageData, document.imageSize)
    }
}
