import AppKit
import QuickLook
import SwiftUI
import ApplePiCore
import ApplePiRemote

struct ChatFileReference: Identifiable, Hashable, Sendable {
    let path: String
    let attachmentID: String?
    let attachmentName: String?
    let mimeType: String?

    init(path: String, attachmentID: String? = nil, attachmentName: String? = nil, mimeType: String? = nil) {
        self.path = path
        self.attachmentID = attachmentID
        self.attachmentName = attachmentName
        self.mimeType = mimeType
    }

    var id: String { attachmentID ?? path }

    var displayName: String {
        if let attachmentName, !attachmentName.isEmpty { return attachmentName }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    var fileExtension: String {
        URL(fileURLWithPath: path).pathExtension.lowercased()
    }

    var iconName: String {
        switch fileExtension {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif": return "photo"
        case "pdf": return "doc.richtext"
        case "md", "markdown", "txt", "log", "json", "yaml", "yml", "csv": return "doc.text"
        case "zip", "tar", "gz", "tgz": return "archivebox"
        default: return "doc"
        }
    }

    var isImage: Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif"].contains(fileExtension)
    }
}

struct FileReferenceExtraction: Sendable {
    let text: String
    let references: [ChatFileReference]
}

enum ChatFileReferenceExtractor {
    private static let referenceRegex = try? NSRegularExpression(pattern: #"@([^\s<>()\[\]{}\"'`]+)"#)
    private static let attachmentTagRegex = try? NSRegularExpression(pattern: #"<file\s+name=\"([^\"]+)\"([^>]*)>[\s\S]*?</file>"#)

    static func extract(from rawText: String) -> FileReferenceExtraction {
        FileReferenceExtractionCache.shared.extraction(for: rawText) {
            extractUncached(from: rawText)
        }
    }

    private static func extractUncached(from rawText: String) -> FileReferenceExtraction {
        var cleaned = rawText
        var references: [ChatFileReference] = []

        // Parse ordinary @paths first. Replacing a later <file> tag first
        // would invalidate the match offsets for a preceding @path.
        if let referenceRegex {
            let matches = referenceRegex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range(at: 0), in: cleaned),
                      let pathRange = Range(match.range(at: 1), in: cleaned) else { continue }
                let rawPath = String(cleaned[pathRange])
                let trimmedPath = trimTrailingPunctuation(rawPath)
                guard isLikelyFileReference(trimmedPath) else { continue }

                let reference = ChatFileReference(path: trimmedPath)
                references.append(reference)
                let consumedEnd = cleaned.index(fullRange.lowerBound, offsetBy: 1 + trimmedPath.count)
                cleaned.replaceSubrange(fullRange.lowerBound..<consumedEnd, with: reference.displayName)
            }
        }

        if let attachmentTagRegex {
            let tagMatches = attachmentTagRegex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
            for match in tagMatches.reversed() {
                guard let fullRange = Range(match.range(at: 0), in: cleaned),
                      let pathRange = Range(match.range(at: 1), in: cleaned),
                      let attributesRange = Range(match.range(at: 2), in: cleaned) else { continue }
                let path = String(cleaned[pathRange])
                let attributes = String(cleaned[attributesRange])
                guard let attachmentID = attribute("attachment-id", in: attributes) else { continue }
                let reference = ChatFileReference(
                    path: path,
                    attachmentID: attachmentID,
                    attachmentName: attribute("attachment-name", in: attributes),
                    mimeType: attribute("attachment-mime", in: attributes)
                )
                references.append(reference)
                cleaned.replaceSubrange(fullRange, with: reference.displayName)
            }
        }

        references.reverse()
        return FileReferenceExtraction(
            text: normalize(cleaned),
            references: deduplicate(references)
        )
    }

    private static func attribute(_ name: String, in value: String) -> String? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"=\"([^\"]+)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range]).nilIfBlank
    }

    private static func trimTrailingPunctuation(_ value: String) -> String {
        var trimmed = value
        while let last = trimmed.last, ".,;:!?»”’`*_~".contains(last) {
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func isLikelyFileReference(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        guard value.contains("/") || value.hasPrefix("~/") || value.hasPrefix("/") else { return false }
        let ext = URL(fileURLWithPath: value).pathExtension
        return !ext.isEmpty || value.hasPrefix("~/") || value.hasPrefix("/")
    }

    private static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deduplicate(_ references: [ChatFileReference]) -> [ChatFileReference] {
        var seen: Set<String> = []
        var unique: [ChatFileReference] = []
        for reference in references where seen.insert(reference.id).inserted {
            unique.append(reference)
        }
        return unique
    }
}

private final class FileReferenceExtractionCache: @unchecked Sendable {
    static let shared = FileReferenceExtractionCache()

    private final class Box {
        let extraction: FileReferenceExtraction

        init(_ extraction: FileReferenceExtraction) {
            self.extraction = extraction
        }
    }

    private let cache = NSCache<NSString, Box>()

    private init() {
        cache.countLimit = 2_000
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func extraction(for key: String, build: () -> FileReferenceExtraction) -> FileReferenceExtraction {
        let cacheKey = key as NSString
        if let box = cache.object(forKey: cacheKey) {
            return box.extraction
        }
        let extraction = build()
        cache.setObject(Box(extraction), forKey: cacheKey, cost: max(1, key.utf8.count))
        return extraction
    }
}

struct ChatFileReferenceCard: View {
    @EnvironmentObject private var appState: PiAppState

    let reference: ChatFileReference
    let baseDirectory: String?

    @State private var previewURL: URL?
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: reference.iconName)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(appState.appearance.accentColor)
                    .frame(width: 28)

                Button(action: preview) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reference.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(reference.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .buttonStyle(.plain)
                .help("Preview")

                Spacer(minLength: 8)

                Button("Preview") { preview() }
                    .buttonStyle(.borderless)
                Button("Download") { download() }
                    .buttonStyle(.borderless)
            }

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(status.hasPrefix("Error") ? .red : .secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .quickLookPreview($previewURL)
    }

    private func preview() {
        Task {
            do {
                let localURL = try await materializeFileForPreview()
                await MainActor.run {
                    previewURL = localURL
                    status = nil
                }
            } catch {
                await MainActor.run { status = "Error: \(error.localizedDescription)" }
            }
        }
    }

    private func download() {
        Task {
            do {
                let file = try await fetchFile()
                await MainActor.run {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = resolvedFileName(for: file)
                    panel.canCreateDirectories = true
                    panel.begin { response in
                        guard response == .OK, let url = panel.url else { return }
                        do {
                            try file.data.write(to: url, options: .atomic)
                            status = "Saved to \(url.path)."
                        } catch {
                            status = "Error: \(error.localizedDescription)"
                        }
                    }
                }
            } catch {
                await MainActor.run { status = "Error: \(error.localizedDescription)" }
            }
        }
    }

    private func materializeFileForPreview() async throws -> URL {
        let file = try await fetchFile()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-app-file-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = resolvedFileName(for: file)
        let url = directory.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
        try file.data.write(to: url, options: .atomic)
        return url
    }

    private func fetchFile() async throws -> RemoteFileDownload {
        if let attachmentID = reference.attachmentID {
            return try await RemoteDaemonClient().downloadAttachment(host: appState.host, id: attachmentID)
        }
        return try await RemoteDaemonClient().downloadFile(
            host: appState.host,
            path: reference.path,
            baseDirectory: baseDirectory
        )
    }

    private func resolvedFileName(for file: RemoteFileDownload) -> String {
        AttachmentPreviewFilename.resolve(
            downloadedName: file.fileName,
            displayName: reference.displayName,
            mimeType: file.mimeType ?? reference.mimeType
        )
    }
}
