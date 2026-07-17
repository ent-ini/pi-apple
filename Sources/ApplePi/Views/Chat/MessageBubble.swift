import AppKit
import QuickLook
import SwiftUI
import ApplePiCore
import ApplePiRemote

private let messageBubbleMaxWidth: CGFloat = 420
// A bubble must be wide enough for its HH:mm timestamp and horizontal inset.
// This also prevents one-character messages from collapsing into a narrow pill.
private let messageBubbleMinWidth: CGFloat = 72

private struct BubbleWidthModifier: ViewModifier {
    let prefersCompactWidth: Bool
    let alignment: Alignment

    func body(content: Content) -> some View {
        if prefersCompactWidth {
            content
                .frame(minWidth: messageBubbleMinWidth, alignment: alignment)
                .fixedSize(horizontal: true, vertical: false)
        } else {
            content
                .frame(minWidth: messageBubbleMinWidth, maxWidth: messageBubbleMaxWidth, alignment: alignment)
        }
    }
}

private struct UserVisibleAttachment: Identifiable, Hashable {
    enum Kind: Hashable {
        case image(path: String, mime: String?, attachmentID: String?, displayName: String)
        case file(path: String, displayName: String, isAudio: Bool, attachmentID: String?, mime: String?)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .image(let path, _, let attachmentID, _):
            return "image:\(attachmentID ?? path)"
        case .file(let path, _, let isAudio, let attachmentID, _):
            return "file:\(attachmentID ?? path):\(isAudio)"
        }
    }

    var attachmentID: String? {
        switch kind {
        case .image(_, _, let id, _), .file(_, _, _, let id, _): return id
        }
    }
}

private struct UserMessagePresentation {
    let attachments: [UserVisibleAttachment]
    let text: String

    var hasAttachments: Bool {
        !attachments.isEmpty
    }

    var isAttachmentOnly: Bool {
        hasAttachments && text.isEmpty
    }

    var prefersCompactWidth: Bool {
        isAttachmentOnly && attachments.count == 1
    }

    static func cachedBuild(from blocks: [ContentBlock]) -> UserMessagePresentation {
        let key = cacheKey(for: blocks)
        return UserMessagePresentationCache.shared.presentation(for: key) {
            build(from: blocks)
        }
    }

    static func build(from blocks: [ContentBlock]) -> UserMessagePresentation {
        var explicitImages: [UserVisibleAttachment] = []
        var extractedAttachments: [UserVisibleAttachment] = []
        var textFragments: [String] = []

        for block in blocks {
            switch block {
            case .text(let rawText):
                // A persisted user message may contain both a generic image
                // block and an authoritative `<file attachment-id=...>` tag.
                // Always inspect the tag so its remote ID can replace the
                // non-downloadable generic block after the send completes.
                let extraction = extractAttachmentsAndText(
                    from: rawText,
                    includeImageTags: true
                )
                extractedAttachments.append(contentsOf: extraction.attachments)
                if !extraction.text.isEmpty {
                    textFragments.append(extraction.text)
                }
            case .image(let path, let mime):
                explicitImages.append(.init(kind: .image(path: path, mime: mime, attachmentID: nil, displayName: "Image")))
            case .thinking:
                continue
            }
        }

        let hasAuthoritativeImage = extractedAttachments.contains { attachment in
            if case .image(_, _, let attachmentID, _) = attachment.kind { return attachmentID != nil }
            return false
        }
        let hasEmbeddedExplicitImage = explicitImages.contains { attachment in
            if case .image(let path, _, _, _) = attachment.kind {
                return path.hasPrefix("data:")
            }
            return false
        }
        let attachments: [UserVisibleAttachment]
        if hasEmbeddedExplicitImage {
            // pi-appd persists a send as both an inline base64 image and a
            // `<file>` reference. The inline payload is immediately renderable,
            // so prefer it and retain only non-image file attachments.
            attachments = explicitImages + extractedAttachments.filter { attachment in
                if case .image = attachment.kind { return false }
                return true
            }
        } else {
            attachments = (hasAuthoritativeImage ? [] : explicitImages) + extractedAttachments
        }
        return UserMessagePresentation(
            attachments: deduplicate(attachments),
            text: normalizeVisibleText(textFragments.joined(separator: "\n\n"))
        )
    }

    static func sanitizeTextOnly(_ rawText: String) -> String {
        let visible = normalizeVisibleText(removeSourceTags(from: rawText))
        // When the user sends only attachments, the transport still needs a
        // tiny textual prompt for Pi. That fallback is not user-authored
        // content, so don't render it in the visible chat bubble.
        if visible == attachmentOnlyFallbackPrompt {
            return ""
        }
        return visible
    }

    private static let attachmentOnlyFallbackPrompt = "Please inspect the attached item(s)."

    private struct Extraction {
        let attachments: [UserVisibleAttachment]
        let text: String
    }

    private static func extractAttachmentsAndText(from rawText: String, includeImageTags: Bool) -> Extraction {
        let pattern = #"<file\s+name=\"([^\"]+)\"([^>]*)>([\s\S]*?)</file>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return Extraction(attachments: [], text: sanitizeTextOnly(rawText))
        }

        let nsRange = NSRange(rawText.startIndex..., in: rawText)
        let matches = regex.matches(in: rawText, options: [], range: nsRange)
        guard !matches.isEmpty else {
            return Extraction(attachments: [], text: sanitizeTextOnly(rawText))
        }

        var attachments: [UserVisibleAttachment] = []
        var cleaned = rawText

        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: cleaned) else { continue }

            let rawTag = String(cleaned[fullRange])
            let path = substring(in: cleaned, nsRange: match.range(at: 1)).map(xmlUnescape) ?? ""
            let attributes = substring(in: cleaned, nsRange: match.range(at: 2)) ?? ""
            let body = substring(in: cleaned, nsRange: match.range(at: 3)).map(xmlUnescape) ?? ""

            if let attachment = makeAttachment(path: path, attributes: attributes, rawTag: rawTag, body: body, includeImageTags: includeImageTags) {
                attachments.append(attachment)
            }

            cleaned.replaceSubrange(fullRange, with: "")
        }

        attachments.reverse()
        return Extraction(
            attachments: attachments,
            text: sanitizeTextOnly(cleaned)
        )
    }

    private static func makeAttachment(path: String, attributes: String, rawTag: String, body: String, includeImageTags: Bool) -> UserVisibleAttachment? {
        // Some pi clients serialize an upload as `name="/path attachment-id="id"…`
        // (the closing quote after the path is absent). Keep accepting that
        // historical wire shape: recover attributes from the complete tag and
        // strip the leaked attribute marker from the filesystem path.
        let trimmedPath = path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+attachment-id=$"#, with: "", options: .regularExpression)
        guard !trimmedPath.isEmpty else { return nil }
        let attachmentID = attribute("attachment-id", in: attributes) ?? attribute("attachment-id", in: rawTag)
        let mime = attribute("attachment-mime", in: attributes)
            ?? attribute("attachment-mime", in: rawTag)
            ?? guessImageMimeType(from: trimmedPath)
        let pathName = URL(fileURLWithPath: trimmedPath).lastPathComponent
        let displayName = attribute("attachment-name", in: attributes)
            ?? attribute("attachment-name", in: rawTag)
            ?? (pathName.isEmpty ? "Attachment" : pathName)
        let isImage = mime?.lowercased().hasPrefix("image/") == true || isImageAttachment(path: trimmedPath, body: body)
        if isImage {
            guard includeImageTags || attachmentID != nil else { return nil }
            return UserVisibleAttachment(kind: .image(path: trimmedPath, mime: mime, attachmentID: attachmentID, displayName: displayName))
        }
        let isAudio = mime?.lowercased().hasPrefix("audio/") == true || isAudioPath(trimmedPath)
        return UserVisibleAttachment(
            kind: .file(path: trimmedPath, displayName: displayName, isAudio: isAudio, attachmentID: attachmentID, mime: mime)
        )
    }

    private static func attribute(_ name: String, in value: String) -> String? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"=\"([^\"]+)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return xmlUnescape(String(value[range])).nilIfBlank
    }

    private static func isImageAttachment(path: String, body: String) -> Bool {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if isImagePath(path) {
            return true
        }
        return trimmedBody.isEmpty
            || trimmedBody.hasPrefix("[Image:")
            || trimmedBody.hasPrefix("[Image attachment:")
    }

    private static func isImagePath(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif"].contains(ext)
    }

    private static func isAudioPath(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["mp3", "wav", "m4a", "ogg", "oga", "aac", "flac"].contains(ext)
    }

    private static func guessImageMimeType(from path: String) -> String? {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        default: return nil
        }
    }

    private static func removeSourceTags(from text: String) -> String {
        let withoutSource = text.replacingOccurrences(
            of: #"(?:^|\n)\[source:[^\]]+\]\n?"#,
            with: "\n",
            options: .regularExpression
        )
        return withoutSource.replacingOccurrences(
            of: #"(?:^|\n)\[telegram_topic\][\s\S]*?\[/telegram_topic\]\n?"#,
            with: "\n",
            options: .regularExpression
        )
    }

    private static func normalizeVisibleText(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deduplicate(_ attachments: [UserVisibleAttachment]) -> [UserVisibleAttachment] {
        var seen: Set<String> = []
        var unique: [UserVisibleAttachment] = []
        for attachment in attachments {
            if seen.insert(attachment.id).inserted {
                unique.append(attachment)
            }
        }
        return unique
    }

    private static func substring(in text: String, nsRange: NSRange) -> String? {
        guard let range = Range(nsRange, in: text) else { return nil }
        return String(text[range])
    }

    private static func cacheKey(for blocks: [ContentBlock]) -> String {
        blocks.map { block in
            switch block {
            case .text(let text):
                return "text:\(text)"
            case .thinking(let text, let signature):
                return "thinking:\(text):\(signature ?? "")"
            case .image(let path, let mime):
                return "image:\(path):\(mime ?? "")"
            }
        }
        .joined(separator: "\u{1f}")
    }

    private static func xmlUnescape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

private final class UserMessagePresentationCache: @unchecked Sendable {
    static let shared = UserMessagePresentationCache()

    private final class Box {
        let presentation: UserMessagePresentation

        init(_ presentation: UserMessagePresentation) {
            self.presentation = presentation
        }
    }

    private let cache = NSCache<NSString, Box>()

    private init() {
        cache.countLimit = 2_000
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func presentation(for key: String, build: () -> UserMessagePresentation) -> UserMessagePresentation {
        let cacheKey = key as NSString
        if let box = cache.object(forKey: cacheKey) {
            return box.presentation
        }
        let presentation = build()
        cache.setObject(Box(presentation), forKey: cacheKey, cost: max(1, key.utf8.count))
        return presentation
    }
}

private final class ChatImageCache: @unchecked Sendable {
    static let shared = ChatImageCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for key: String, load: () -> NSImage?) -> NSImage? {
        let cacheKey = key as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        guard let image = load() else { return nil }
        cache.setObject(image, forKey: cacheKey, cost: imageCacheCost(image))
        return image
    }

    private func imageCacheCost(_ image: NSImage) -> Int {
        let size = image.size
        guard size.width.isFinite, size.height.isFinite else { return 1 }
        return max(1, Int(size.width * size.height * 4))
    }
}

private struct MacUserAttachmentView: View {
    @EnvironmentObject private var appState: PiAppState
    let attachment: UserVisibleAttachment
    let isUserMessage: Bool
    @State private var previewURL: URL?
    @State private var inlineImage: NSImage?
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        Group {
            if isImage {
                imageContent
            } else {
                fileContent
            }
        }
        .quickLookPreview($previewURL)
        .task(id: attachment.id) {
            await loadInlineImageIfNeeded()
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let resolvedInlineImage {
            Button(action: previewAttachment) {
                Image(nsImage: resolvedInlineImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Preview image")
        } else if isLoading {
            ProgressView().controlSize(.small)
        } else if let errorText {
            Text(errorText).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    private var fileContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: iconName).font(.system(size: 18, weight: .medium))
                Text(displayName)
                    .font(.subheadline)
                    .lineLimit(2)
                    .onTapGesture(perform: previewAttachment)
                if isLoading { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                if attachment.attachmentID != nil {
                    Button("Preview") { previewAttachment() }.buttonStyle(.borderless)
                    Button("Save") { saveAttachment() }.buttonStyle(.borderless)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(10)
        .background(Color.black.opacity(isUserMessage ? 0.12 : 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var isImage: Bool {
        if case .image = attachment.kind { return true }
        return false
    }

    private var resolvedInlineImage: NSImage? {
        if let inlineImage { return inlineImage }
        if let embeddedImageData {
            return ChatImageCache.shared.image(for: "user-inline:\(attachment.id)") {
                NSImage(data: embeddedImageData)
            }
        }
        if let localImagePath {
            return ChatImageCache.shared.image(for: "user-local:\(localImagePath)") {
                NSImage(contentsOfFile: localImagePath)
            }
        }
        return nil
    }

    private var embeddedImageData: Data? {
        guard case .image(let path, _, _, _) = attachment.kind,
              path.hasPrefix("data:"),
              let comma = path.firstIndex(of: ",") else {
            return nil
        }
        return Data(base64Encoded: String(path[path.index(after: comma)...]))
    }

    private var localImagePath: String? {
        guard case .image(let path, _, let attachmentID, _) = attachment.kind,
              attachmentID == nil,
              !path.hasPrefix("data:") else {
            return nil
        }
        return path
    }

    private var displayName: String {
        switch attachment.kind {
        case .image(_, _, _, let name), .file(_, let name, _, _, _): return name
        }
    }

    private var iconName: String {
        switch attachment.kind {
        case .image: return "photo"
        case .file(_, _, let isAudio, _, _): return isAudio ? "waveform" : "doc"
        }
    }

    @MainActor
    private func loadInlineImageIfNeeded() async {
        guard isImage, inlineImage == nil else { return }
        if embeddedImageData != nil || localImagePath != nil {
            // Embedded/local images are synchronously resolved and cached by
            // `resolvedInlineImage`, so no asynchronous fetch is needed.
            return
        }
        guard attachment.attachmentID != nil else { return }

        isLoading = true
        defer { isLoading = false }
        do {
            let file = try await fetch()
            guard let image = NSImage(data: file.data) else {
                errorText = "Unable to decode image preview."
                return
            }
            inlineImage = image
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func fetch() async throws -> RemoteFileDownload {
        guard let attachmentID = attachment.attachmentID else {
            throw RemoteDaemonError.requestFailed(status: 404, body: "Attachment is not available remotely.")
        }
        return try await RemoteDaemonClient().downloadAttachment(host: appState.host, id: attachmentID)
    }

    private func previewAttachment() {
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                if let embeddedImageData {
                    previewURL = try materializePreview(data: embeddedImageData, fileName: displayName)
                    return
                }
                if let localImagePath {
                    previewURL = URL(fileURLWithPath: localImagePath)
                    return
                }
                let file = try await fetch()
                previewURL = try materializePreview(data: file.data, fileName: resolvedFileName(for: file))
            } catch { errorText = error.localizedDescription }
        }
    }

    private func materializePreview(data: Data, fileName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-app-attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = AttachmentPreviewFilename.resolve(
            downloadedName: fileName,
            displayName: displayName,
            mimeType: attachmentMimeType
        )
        let url = directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func saveAttachment() {
        Task {
            do {
                let file = try await fetch()
                let panel = NSSavePanel()
                panel.nameFieldStringValue = resolvedFileName(for: file)
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try file.data.write(to: url, options: .atomic)
            } catch { errorText = error.localizedDescription }
        }
    }

    private func resolvedFileName(for file: RemoteFileDownload) -> String {
        AttachmentPreviewFilename.resolve(
            downloadedName: file.fileName,
            displayName: displayName,
            mimeType: file.mimeType ?? attachmentMimeType
        )
    }

    private var attachmentMimeType: String? {
        switch attachment.kind {
        case .image(_, let mime, _, _), .file(_, _, _, _, let mime): return mime
        }
    }
}

/// One chat bubble. User messages are right-aligned with the accent
/// background; assistant messages span almost the full width with a
/// neutral surface so long responses are easy to read.
struct MessageBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState
    let message: Message
    var fileReferenceBaseDirectory: String?
    @State private var previewURL: URL?

    @ViewBuilder
    var body: some View {
        if shouldRenderRow {
            HStack(alignment: .top, spacing: 0) {
                if message.role == .user {
                    Spacer(minLength: 90)
                    bubbleColumn(alignment: .trailing)
                } else {
                    bubbleColumn(alignment: .leading)
                    Spacer(minLength: 90)
                }
            }
            .contextMenu {
                Button("Copy message") {
                    copyMessageToPasteboard()
                }
            }
            .quickLookPreview($previewURL)
        }
    }

    @ViewBuilder
    private func bubbleColumn(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            if !thinkingText.isEmpty {
                ThinkingSummaryView(
                    thinkingText: thinkingText,
                    visibilityID: "visibility:thinking:\(message.id)"
                )
            }
            if let presentation = userPresentation {
                bubbleSurface(
                    isLastVisibleBlock: true,
                    prefersCompactWidth: presentation.prefersCompactWidth,
                    timestampOverlaysContent: presentation.isAttachmentOnly
                ) {
                    userPresentationView(presentation)
                }
            } else {
                ForEach(Array(visibleBlocks.enumerated()), id: \.offset) { index, block in
                    blockView(block, isLastVisibleBlock: index == visibleBlocks.count - 1)
                }
            }
        }
    }

    @ViewBuilder
    private func userPresentationView(_ presentation: UserMessagePresentation) -> some View {
        VStack(alignment: .leading, spacing: presentation.text.isEmpty ? 0 : 10) {
            ForEach(presentation.attachments) { attachment in
                userAttachmentView(attachment)
            }
            if !presentation.text.isEmpty {
                MarkdownText(presentation.text)
                    .font(.body)
            }
        }
    }

    private func userAttachmentView(_ attachment: UserVisibleAttachment) -> some View {
        MacUserAttachmentView(attachment: attachment, isUserMessage: message.role == .user)
    }

    @ViewBuilder
    private func blockView(_ block: ContentBlock, isLastVisibleBlock: Bool) -> some View {
        switch block {
        case .text(let rawText):
            let extraction = displayTextAndFileReferences(for: rawText)
            if !extraction.text.isEmpty || !extraction.references.isEmpty {
                bubbleSurface(
                    isLastVisibleBlock: isLastVisibleBlock,
                    prefersCompactWidth: prefersCompactWidth(for: extraction.text, referenceCount: extraction.references.count)
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !extraction.text.isEmpty {
                            MarkdownText(extraction.text)
                                .font(.body)
                        }
                        ForEach(extraction.references) { reference in
                            ChatFileReferenceCard(
                                reference: reference,
                                baseDirectory: fileReferenceBaseDirectory
                            )
                        }
                    }
                }
            }
        case .thinking:
            EmptyView()
        case .image(let path, _):
            bubbleSurface(isLastVisibleBlock: isLastVisibleBlock, prefersCompactWidth: true) {
                if let image = resolvedImage(for: path) {
                    Button { previewImage(at: path) } label: {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 240, maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Preview")
                } else {
                    Text("[image]")
                        .font(.body.monospaced())
                }
            }
        }
    }

    private func bubbleSurface<Content: View>(
        isLastVisibleBlock: Bool,
        prefersCompactWidth: Bool,
        timestampOverlaysContent: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let showsTimestamp = isLastVisibleBlock && formattedTime != nil

        return VStack(alignment: .leading, spacing: 0) {
            content()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, showsTimestamp && !timestampOverlaysContent ? 24 : 10)
        .background(bubbleBackground)
        .foregroundStyle(textColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if isLastVisibleBlock, let timestamp = formattedTime {
                timestampView(timestamp, compact: timestampOverlaysContent)
            }
        }
        .modifier(BubbleWidthModifier(prefersCompactWidth: prefersCompactWidth, alignment: bubbleFrameAlignment))
    }

    private func timestampView(_ timestamp: String, compact: Bool) -> some View {
        Text(timestamp)
            .font(.caption2)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(timestampColor)
            .padding(.horizontal, compact ? 6 : 0)
            .padding(.vertical, compact ? 3 : 0)
            .background {
                if compact {
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(message.role == .user ? 0.18 : 0.08))
                }
            }
            .padding(.trailing, 10)
            .padding(.bottom, 8)
    }

    private var visibleBlocks: [ContentBlock] {
        message.content.filter {
            if case .thinking = $0 { return false }
            return true
        }
    }

    private var userPresentation: UserMessagePresentation? {
        guard message.role == .user else { return nil }
        let presentation = UserMessagePresentation.cachedBuild(from: message.content)
        return presentation.hasAttachments ? presentation : nil
    }

    private var shouldRenderRow: Bool {
        if message.role != .assistant { return true }
        return !thinkingText.isEmpty || !visibleBlocks.isEmpty || userPresentation != nil
    }

    private var thinkingText: String {
        message.content.compactMap { block in
            if case .thinking(let text, _) = block {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n---\n\n")
    }

    private func displayTextAndFileReferences(for rawText: String) -> FileReferenceExtraction {
        guard message.role != .user else {
            return FileReferenceExtraction(
                text: UserMessagePresentation.sanitizeTextOnly(rawText),
                references: []
            )
        }
        return ChatFileReferenceExtractor.extract(from: rawText)
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user:
            return appState.appearance.userMessageBackgroundColor
        case .assistant:
            return appState.appearance.assistantMessageBackgroundColor(for: resolvedColorScheme)
        case .system:
            return appState.appearance.systemMessageBackgroundColor(for: resolvedColorScheme)
        }
    }

    private var textColor: Color {
        switch message.role {
        case .user:
            return appState.appearance.userMessageTextColor
        case .assistant, .system:
            return appState.appearance.assistantMessageTextColor(for: resolvedColorScheme)
        }
    }

    private var formattedTime: String? {
        guard let timestamp = message.timestamp else { return nil }
        return Self.timeFormatter.string(from: timestamp)
    }

    private var timestampColor: Color {
        switch message.role {
        case .user:
            return appState.appearance.userMessageTextColor.opacity(0.82)
        case .assistant, .system:
            return appState.appearance.assistantMessageTextColor(for: resolvedColorScheme).opacity(0.64)
        }
    }

    private var bubbleFrameAlignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private func prefersCompactWidth(for text: String, referenceCount: Int = 0) -> Bool {
        guard referenceCount == 0 else { return false }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.count <= 42 && !normalized.contains("\n")
    }

    private func resolvedImage(for path: String) -> NSImage? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "inline-image" else { return nil }
        return ChatImageCache.shared.image(for: trimmed) {
            if trimmed.hasPrefix("data:"),
               let commaIndex = trimmed.firstIndex(of: ",") {
                let base64 = String(trimmed[trimmed.index(after: commaIndex)...])
                if let data = Data(base64Encoded: base64) {
                    return NSImage(data: data)
                }
            }
            return NSImage(contentsOfFile: trimmed)
        }
    }

    private func previewImage(at path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let data: Data?
        if trimmed.hasPrefix("data:"), let comma = trimmed.firstIndex(of: ",") {
            data = Data(base64Encoded: String(trimmed[trimmed.index(after: comma)...]))
        } else {
            data = try? Data(contentsOf: URL(fileURLWithPath: trimmed))
        }
        guard let data else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-app-image-previews", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(UUID().uuidString).png")
            try data.write(to: url, options: .atomic)
            previewURL = url
        } catch {}
    }

    private func copyMessageToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyableMessageText, forType: .string)
    }

    private var copyableMessageText: String {
        if let presentation = userPresentation {
            var parts = presentation.attachments.map(copyText(for:))
            if !presentation.text.isEmpty {
                parts.append(presentation.text)
            }
            return parts.joined(separator: "\n\n")
        }

        let parts = message.content.compactMap { block -> String? in
            switch block {
            case .text(let rawText):
                let sanitized = UserMessagePresentation.sanitizeTextOnly(rawText)
                let text = ChatFileReferenceExtractor.extract(from: sanitized).text
                return text.isEmpty ? nil : text
            case .thinking:
                return nil
            case .image(let path, let mime):
                if let mime {
                    return "[image: \(path), \(mime)]"
                }
                return "[image: \(path)]"
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private func copyText(for attachment: UserVisibleAttachment) -> String {
        switch attachment.kind {
        case .image(_, _, _, let displayName):
            return "[image attachment: \(displayName)]"
        case .file(_, let displayName, let isAudio, _, _):
            return "[\(isAudio ? "audio" : "file") attachment: \(displayName)]"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
