import AppKit
import SwiftUI
import ApplePiCore
import ApplePiRemote

/// View for a single open Pi session. The composer stays compact but now
/// supports staged attachments above the input row.
struct ChatSessionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState
    @ObservedObject var session: ChatSession

    @State private var draftAttachments: [ChatAttachment] = []
    @State private var isTranscribingAudio = false
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var showMicrophonePermissionAlert = false
    @State private var showsModelPicker = false
    @State private var showsThinkingPicker = false
    @State private var modelPickerButtonFrame: CGRect = .zero
    @State private var thinkingPickerButtonFrame: CGRect = .zero
    @StateObject private var audioRecorder = AudioRecordingController()

    private let attachmentStagingService = AttachmentStagingService()
    private static let slashCommands: [SlashCommand] = [
        SlashCommand(name: "/abort", description: "Stop the active run"),
        SlashCommand(name: "/compact", description: "Compact this session")
    ]

    private var draftTextBinding: Binding<String> {
        Binding(
            get: { session.draftText },
            set: { session.draftText = $0 }
        )
    }

    private var draftHeightBinding: Binding<CGFloat> {
        Binding(
            get: { session.draftHeight },
            set: { session.draftHeight = $0 }
        )
    }

    private var hasDraftContent: Bool {
        !session.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty
    }

    private var canSend: Bool {
        !audioRecorder.isRecording &&
        !isTranscribingAudio &&
        hasDraftContent
    }

    private var canAdjustSessionOptions: Bool {
        session.sessionID != nil || session.launchRequest != nil
    }

    private var slashCommandMatches: [SlashCommand] {
        guard let query = slashCommandQuery(in: session.draftText) else { return [] }
        return Self.slashCommands.filter { command in
            let bareName = String(command.name.dropFirst())
            return query.isEmpty || bareName.hasPrefix(query) || command.name.hasPrefix("/\(query)")
        }
    }

    private var showsSlashCommandSuggestions: Bool {
        !slashCommandMatches.isEmpty && draftAttachments.isEmpty && !audioRecorder.isRecording && !isTranscribingAudio
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .bottom) {
                    MessageListView(session: session)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            Color.clear.frame(height: composerReservedHeight)
                        }
                    composerArea
                }

                if showsModelPicker {
                    modelPickerOverlay(containerSize: proxy.size)
                        .zIndex(20)
                        .transition(.opacity)
                }

                if showsThinkingPicker {
                    thinkingPickerOverlay(containerSize: proxy.size)
                        .zIndex(20)
                        .transition(.opacity)
                }
            }
            .coordinateSpace(name: Self.modelPickerCoordinateSpace)
            .onPreferenceChange(ModelPickerButtonFramePreferenceKey.self) { frame in
                modelPickerButtonFrame = frame
            }
            .onPreferenceChange(ThinkingPickerButtonFramePreferenceKey.self) { frame in
                thinkingPickerButtonFrame = frame
            }
        }
        .onAppear {
            if session.sessionID != nil {
                appState.refreshSessionRuntime(for: session)
                appState.refreshAvailableModels(for: session)
            } else {
                appState.hydratePendingSessionDefaults(for: session)
            }
        }
        .onChange(of: session.sessionID) { _, _ in
            showsModelPicker = false
            appState.refreshSessionRuntime(for: session)
        }
        .onDisappear {
            transcriptionTask?.cancel()
            transcriptionTask = nil
            if audioRecorder.isRecording {
                audioRecorder.cancelRecording()
            }
            cleanupAttachments(draftAttachments)
        }
        .alert("Microphone Access Needed", isPresented: $showMicrophonePermissionAlert) {
            Button("Open Settings") {
                openMicrophoneSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow microphone access for pi-app in System Settings → Privacy & Security → Microphone.")
        }
    }

    private var composerReservedHeight: CGFloat {
        max(session.draftHeight, 30)
            + 74
            + (draftAttachments.isEmpty ? 0 : 66)
            + (showsSlashCommandSuggestions ? 70 : 0)
    }

    private var composerArea: some View {
        let controlHeight = max(session.draftHeight, 30)

        return VStack(alignment: .leading, spacing: 6) {
            if showsSlashCommandSuggestions {
                slashCommandSuggestions
                    .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 6) {
                if !draftAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(draftAttachments) { attachment in
                                ComposerAttachmentPreview(
                                    attachment: attachment,
                                    onRemove: { removeAttachment(attachment) }
                                )
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                }

                composerInputSurface(controlHeight: controlHeight)

                composerControlsRow
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 9)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(composerAreaBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var composerControlsRow: some View {
        let runtime = session.runtimeState

        HStack(alignment: .center, spacing: 10) {
            composerIconButton(
                systemName: "plus",
                enabled: !audioRecorder.isRecording,
                action: pickAttachments
            )
            .help("Attach files")

            Text(statusMetricsText)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 72, alignment: .leading)
                .help("Used context window")

            Button {
                if session.availableModels.isEmpty {
                    appState.refreshAvailableModels(for: session, force: true)
                }
                withAnimation(.snappy(duration: 0.18)) {
                    showsThinkingPicker = false
                    showsModelPicker.toggle()
                }
            } label: {
                inlineStatusButton(title: runtime?.modelDisplayName ?? "model", showsChevron: true, chevronExpanded: showsModelPicker)
            }
            .buttonStyle(.plain)
            .disabled(!canAdjustSessionOptions)
            .background(ModelPickerButtonFrameReader())
            .zIndex(5)

            Button {
                if session.availableModels.isEmpty {
                    appState.refreshAvailableModels(for: session, force: true)
                }
                withAnimation(.snappy(duration: 0.18)) {
                    showsModelPicker = false
                    showsThinkingPicker.toggle()
                }
            } label: {
                inlineStatusButton(
                    title: thinkingControlTitle,
                    showsChevron: true,
                    chevronExpanded: showsThinkingPicker
                )
            }
            .buttonStyle(.plain)
            .disabled(!canAdjustSessionOptions)
            .background(ThinkingPickerButtonFrameReader())
            .zIndex(5)

            Spacer(minLength: 0)

            composerIconButton(
                systemName: audioRecorder.isRecording ? "stop.fill" : "mic.fill",
                enabled: true,
                foreground: audioRecorder.isRecording ? .red : appState.appearance.accentColor,
                action: handleMicrophoneTapped
            )
            .help(audioRecorder.isRecording ? "Stop recording" : "Record voice note")

            composerSendButton
                .help(session.hasActiveSend && session.canAcceptSteering ? "Send steering message (/abort to stop)" : "Send")
        }
    }

    private var statusMetricsText: String {
        let context = session.runtimeState?.contextUsage
        let used = formatCompactTokenCount(context?.tokens)
        let window = formatCompactTokenCount(context?.contextWindow)
        return "\(used)/\(window)"
    }

    private var displayedThinkingLevel: String {
        session.runtimeState?.thinkingLevel ?? "off"
    }

    private var thinkingControlTitle: String {
        displayedThinkingLevel
    }

    private var groupedModels: [ModelGroup] {
        Dictionary(grouping: session.availableModels, by: \.provider)
            .map { key, value in
                ModelGroup(
                    provider: key,
                    models: value.sorted { $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending }
                )
            }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }

    fileprivate static let modelPickerCoordinateSpace = "chat.session.model.picker"
    private static let modelPickerWidth: CGFloat = 320
    private static let modelPickerMargin: CGFloat = 12
    private static let modelPickerGap: CGFloat = 8

    private var modelPickerIdealHeight: CGFloat {
        guard !groupedModels.isEmpty else { return 52 }
        let modelCount = groupedModels.reduce(0) { $0 + $1.models.count }
        let groupCount = groupedModels.count
        let groupSpacingCount = max(0, groupCount - 1)
        return 16
            + CGFloat(groupCount * 22)
            + CGFloat(modelCount * 30)
            + CGFloat(groupSpacingCount * 6)
    }

    private func modelPickerOverlay(containerSize: CGSize) -> some View {
        let margin = Self.modelPickerMargin
        let width = min(Self.modelPickerWidth, max(240, containerSize.width - (margin * 2)))
        let hasButtonFrame = !modelPickerButtonFrame.isEmpty
        let availableAboveButton = hasButtonFrame
            ? max(160, modelPickerButtonFrame.minY - (margin * 2))
            : max(160, containerSize.height - 80)
        let height = min(modelPickerIdealHeight, availableAboveButton)
        let x = hasButtonFrame
            ? min(max(margin, modelPickerButtonFrame.maxX - width), max(margin, containerSize.width - width - margin))
            : max(margin, containerSize.width - width - margin)
        let y = hasButtonFrame
            ? max(margin, modelPickerButtonFrame.minY - height - Self.modelPickerGap)
            : max(margin, containerSize.height - height - 56)

        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: containerSize.width, height: containerSize.height)
                .onTapGesture {
                    withAnimation(.snappy(duration: 0.16)) {
                        showsModelPicker = false
                    }
                }

            modelPickerList(maxHeight: height)
                .frame(width: width, height: height, alignment: .top)
                .position(x: x + (width / 2), y: y + (height / 2))
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottomTrailing)))
        }
    }

    private var thinkingPickerIdealHeight: CGFloat {
        let count = appState.availableThinkingLevels(in: session).count
        return max(52, 16 + CGFloat(count * 30))
    }

    private func thinkingPickerOverlay(containerSize: CGSize) -> some View {
        let margin = Self.modelPickerMargin
        let width = min(Self.modelPickerWidth, max(240, containerSize.width - (margin * 2)))
        let hasButtonFrame = !thinkingPickerButtonFrame.isEmpty
        let availableAboveButton = hasButtonFrame
            ? max(160, thinkingPickerButtonFrame.minY - (margin * 2))
            : max(160, containerSize.height - 80)
        let height = min(thinkingPickerIdealHeight, availableAboveButton)
        let x = hasButtonFrame
            ? min(max(margin, thinkingPickerButtonFrame.maxX - width), max(margin, containerSize.width - width - margin))
            : max(margin, containerSize.width - width - margin)
        let y = hasButtonFrame
            ? max(margin, thinkingPickerButtonFrame.minY - height - Self.modelPickerGap)
            : max(margin, containerSize.height - height - 56)

        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: containerSize.width, height: containerSize.height)
                .onTapGesture {
                    withAnimation(.snappy(duration: 0.16)) {
                        showsThinkingPicker = false
                    }
                }

            ThinkingPickerDropdown(
                levels: appState.availableThinkingLevels(in: session),
                currentLevel: displayedThinkingLevel,
                accentColor: appState.appearance.accentColor,
                maxHeight: height,
                onSelect: { level in
                    withAnimation(.snappy(duration: 0.18)) {
                        showsThinkingPicker = false
                    }
                    appState.selectThinkingLevel(level, in: session)
                }
            )
            .frame(width: width, height: height, alignment: .top)
            .position(x: x + (width / 2), y: y + (height / 2))
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottomTrailing)))
        }
    }

    private func modelPickerList(maxHeight: CGFloat) -> some View {
        ModelPickerDropdown(
            groupedModels: groupedModels,
            accentColor: appState.appearance.accentColor,
            currentProvider: session.runtimeState?.provider,
            currentModelID: session.runtimeState?.modelID,
            maxHeight: maxHeight,
            onSelect: { model in
                withAnimation(.snappy(duration: 0.18)) {
                    showsModelPicker = false
                }
                appState.selectModel(model, in: session)
            }
        )
    }

    private func inlineStatusButton(title: String, showsChevron: Bool = false, chevronExpanded: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(chevronExpanded ? 180 : 0))
            }
        }
        .contentShape(Rectangle())
    }

    private func formatCompactTokenCount(_ value: Int?) -> String {
        guard let value else { return "?" }
        if value < 1_000 { return "\(value)" }
        if value < 10_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        if value < 1_000_000 { return "\(Int(round(Double(value) / 1_000)))k" }
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }

    @ViewBuilder
    private var slashCommandSuggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(slashCommandMatches) { command in
                Button {
                    selectSlashCommand(command)
                } label: {
                    HStack(spacing: 8) {
                        Text(command.name)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(appState.appearance.accentColor)
                        Text(command.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    private var composerAreaBackgroundColor: Color {
        appState.appearance.composerAreaBackgroundColor(for: appState.appearance.resolvedColorScheme(current: colorScheme))
    }

    @ViewBuilder
    private func composerInputSurface(controlHeight: CGFloat) -> some View {
        if audioRecorder.isRecording || isTranscribingAudio {
            HStack(spacing: 10) {
                if audioRecorder.isRecording {
                    VoiceWaveformView(levels: audioRecorder.levels, tint: appState.appearance.accentColor)
                        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)

                    Text(formattedDuration(audioRecorder.elapsedTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Transcribing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, minHeight: controlHeight, maxHeight: controlHeight)
        } else {
            ComposerTextView(
                text: draftTextBinding,
                dynamicHeight: draftHeightBinding,
                textColor: appState.appearance.textColor(for: appState.appearance.resolvedColorScheme(current: colorScheme)),
                onSubmit: handleComposerSubmit,
                onPasteAttachments: handlePasteAttachments,
                onDropFiles: addAttachments
            )
            .frame(maxWidth: .infinity, minHeight: controlHeight, maxHeight: controlHeight)
        }
    }

    @ViewBuilder
    private func composerIconButton(
        systemName: String,
        enabled: Bool,
        foreground: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle((foreground ?? appState.appearance.accentColor).opacity(enabled ? 1 : 0.28))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var composerSendButton: some View {
        Button(action: handleComposerSubmit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(appState.appearance.accentColor.opacity(canSend ? 1 : 0.28))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
    }

    private func handleComposerSubmit() {
        let prompt = session.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slashCommand = parseSlashCommand(prompt) {
            switch slashCommand {
            case .abort:
                handleAbortCommand()
            case .compact(let instructions):
                handleCompactCommand(instructions: instructions)
            }
            return
        }
        handleSendTapped()
    }

    private func handleSendTapped() {
        let prompt = session.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let promptToSend = prompt
        let attachmentsToSend = draftAttachments
        let submittedIDs = Set(attachmentsToSend.map(\.id))
        _ = appState.sendMessage(
            promptToSend,
            attachments: attachmentsToSend,
            in: session,
            onAccepted: {
                if session.draftText.trimmingCharacters(in: .whitespacesAndNewlines) == promptToSend {
                    session.draftText = ""
                    session.draftHeight = 30
                }
                draftAttachments.removeAll { submittedIDs.contains($0.id) }
            },
            onUploadFailed: {
                if session.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    session.draftText = promptToSend
                }
                for attachment in attachmentsToSend
                where FileManager.default.fileExists(atPath: attachment.fileURL.path)
                    && !draftAttachments.contains(where: { $0.id == attachment.id }) {
                    draftAttachments.append(attachment)
                }
            }
        )
    }

    private func handleAbortCommand() {
        appState.cancelSend(in: session)
        clearComposer()
    }

    private func handleCompactCommand(instructions: String) {
        appState.compactSession(session, instructions: instructions)
        clearComposer()
    }

    private func clearComposer() {
        session.draftText = ""
        session.draftHeight = 30
        cleanupAttachments(draftAttachments)
        draftAttachments = []
    }

    private func selectSlashCommand(_ command: SlashCommand) {
        session.draftText = command.name
        session.draftHeight = 30
    }

    private func handleMicrophoneTapped() {
        if audioRecorder.isRecording {
            finishVoiceRecording()
            return
        }

        if isTranscribingAudio {
            transcriptionTask?.cancel()
            transcriptionTask = nil
            isTranscribingAudio = false
        }

        let status = AudioRecordingController.microphoneAuthorizationStatus()
        switch status {
        case .authorized:
            startRecordingNow()
        case .notDetermined:
            appState.statusMessage = "Requesting microphone access..."
            AudioRecordingController.requestMicrophoneAccess { granted in
                Task { @MainActor in
                    if granted {
                        startRecordingNow()
                    } else {
                        appState.statusMessage = AudioRecordingError.microphonePermissionDenied.localizedDescription
                        showMicrophonePermissionAlert = true
                    }
                }
            }
        case .denied, .restricted:
            appState.statusMessage = AudioRecordingError.microphonePermissionDenied.localizedDescription
            showMicrophonePermissionAlert = true
        @unknown default:
            appState.statusMessage = AudioRecordingError.microphonePermissionDenied.localizedDescription
            showMicrophonePermissionAlert = true
        }
    }

    private func startRecordingNow() {
        do {
            try audioRecorder.startRecordingAuthorized()
            appState.statusMessage = "Recording voice note..."
        } catch {
            appState.statusMessage = error.localizedDescription
        }
    }

    private func finishVoiceRecording() {
        do {
            let recordingURL = try audioRecorder.stopRecording()
            let staged = try attachmentStagingService.stageFile(at: recordingURL)
            try? FileManager.default.removeItem(at: recordingURL)
            transcribeAudioAttachmentIfPossible(staged)
        } catch {
            appState.statusMessage = error.localizedDescription
        }
    }

    private func transcribeAudioAttachmentIfPossible(_ attachment: ChatAttachment) {
        guard attachment.kind == .audio else { return }

        let fileURL = attachment.fileURL
        let host = appState.host
        isTranscribingAudio = true
        appState.statusMessage = "Transcribing voice note..."
        transcriptionTask?.cancel()
        transcriptionTask = Task {
            do {
                let transcript = try await RemoteDaemonClient().transcribeAudio(host: host, fileURL: fileURL)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    mergeTranscript(transcript)
                    isTranscribingAudio = false
                    transcriptionTask = nil
                    cleanupAttachments([attachment])
                    appState.statusMessage = "Voice note transcribed"
                }
            } catch is CancellationError {
                await MainActor.run {
                    isTranscribingAudio = false
                    transcriptionTask = nil
                    cleanupAttachments([attachment])
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isTranscribingAudio = false
                    transcriptionTask = nil
                    cleanupAttachments([attachment])
                    appState.statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func mergeTranscript(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if session.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.draftText = trimmed
        } else if session.draftText.hasSuffix("\n") {
            session.draftText += trimmed
        } else {
            session.draftText += "\n\n\(trimmed)"
        }
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.title = "Choose files or images"

        guard panel.runModal() == .OK else { return }
        addAttachments(from: panel.urls)
    }

    private func handlePasteAttachments(_ pasteboard: NSPasteboard) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            addAttachments(from: urls)
            return
        }

        if let rawFileNames = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String],
           !rawFileNames.isEmpty {
            addAttachments(from: rawFileNames.map(URL.init(fileURLWithPath:)))
            return
        }

        do {
            if let stagedImage = try attachmentStagingService.stagePastedImage(from: pasteboard) {
                appendAttachments([stagedImage])
            }
        } catch {
            appState.statusMessage = error.localizedDescription
        }
    }

    private func addAttachments(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        var staged: [ChatAttachment] = []
        do {
            for url in urls { staged.append(try attachmentStagingService.stageFile(at: url)) }
            appendAttachments(staged)
        } catch {
            cleanupAttachments(staged)
            appState.statusMessage = error.localizedDescription
        }
    }

    private func appendAttachments(_ attachments: [ChatAttachment]) {
        for attachment in attachments where !draftAttachments.contains(where: { $0.fileURL == attachment.fileURL }) {
            draftAttachments.append(attachment)
        }
    }

    private func removeAttachment(_ attachment: ChatAttachment) {
        draftAttachments.removeAll { $0.id == attachment.id }
        cleanupAttachments([attachment])
    }

    private func cleanupAttachments(_ attachments: [ChatAttachment]) {
        for attachment in attachments {
            try? FileManager.default.removeItem(at: attachment.fileURL)
        }
    }

    private func formattedDuration(_ value: TimeInterval) -> String {
        let totalSeconds = max(0, Int(value.rounded(.down)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct ModelGroup: Identifiable {
    let provider: String
    let models: [PiModelOption]

    var id: String { provider }
}

private enum ParsedSlashCommand: Equatable {
    case abort
    case compact(instructions: String)
}

private func slashCommandQuery(in text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else { return nil }
    let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rest.isEmpty else { return "" }
    let commandPart = rest.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
    return commandPart.lowercased()
}

private func parseSlashCommand(_ text: String) -> ParsedSlashCommand? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else { return nil }
    let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = rest.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
    guard let command = parts.first?.lowercased() else { return nil }
    let arguments = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    switch command {
    case "abort":
        return .abort
    case "compact":
        return .compact(instructions: arguments)
    default:
        return nil
    }
}

private struct SlashCommand: Identifiable, Hashable {
    let name: String
    let description: String

    var id: String { name }
}

private struct ModelPickerButtonFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty {
            value = next
        }
    }
}

private struct ModelPickerButtonFrameReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ModelPickerButtonFramePreferenceKey.self,
                value: proxy.frame(in: .named(ChatSessionView.modelPickerCoordinateSpace))
            )
        }
    }
}

private struct ThinkingPickerButtonFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty {
            value = next
        }
    }
}

private struct ThinkingPickerButtonFrameReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ThinkingPickerButtonFramePreferenceKey.self,
                value: proxy.frame(in: .named(ChatSessionView.modelPickerCoordinateSpace))
            )
        }
    }
}

private struct ModelPickerDropdown: View {
    let groupedModels: [ModelGroup]
    let accentColor: Color
    let currentProvider: String?
    let currentModelID: String?
    let maxHeight: CGFloat
    let onSelect: (PiModelOption) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if groupedModels.isEmpty {
                    Text("Loading models…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                } else {
                    ForEach(groupedModels) { group in
                        ModelPickerGroupSection(
                            group: group,
                            accentColor: accentColor,
                            currentProvider: currentProvider,
                            currentModelID: currentModelID,
                            onSelect: onSelect
                        )
                    }
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: maxHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }
}

private struct ThinkingPickerDropdown: View {
    let levels: [String]
    let currentLevel: String
    let accentColor: Color
    let maxHeight: CGFloat
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if levels.isEmpty {
                    Text("Loading thinking levels…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                } else {
                    ForEach(levels, id: \.self) { level in
                        ThinkingPickerRow(
                            level: level,
                            isSelected: level == currentLevel,
                            accentColor: accentColor,
                            onSelect: onSelect
                        )
                    }
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: maxHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }
}

private struct ThinkingPickerRow: View {
    let level: String
    let isSelected: Bool
    let accentColor: Color
    let onSelect: (String) -> Void

    var body: some View {
        Button {
            onSelect(level)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark" : "circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(accentColor) : AnyShapeStyle(.tertiary))
                    .frame(width: 14)
                Text(level)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(accentColor) : AnyShapeStyle(.primary))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ModelPickerGroupSection: View {
    let group: ModelGroup
    let accentColor: Color
    let currentProvider: String?
    let currentModelID: String?
    let onSelect: (PiModelOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.provider)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 2)

            ForEach(group.models) { model in
                ModelPickerRow(
                    model: model,
                    accentColor: accentColor,
                    isCurrent: isCurrent(model),
                    onSelect: { onSelect(model) }
                )
            }
        }
    }

    private func isCurrent(_ model: PiModelOption) -> Bool {
        currentProvider == model.provider && currentModelID == model.modelID
    }
}

private struct ModelPickerRow: View {
    let model: PiModelOption
    let accentColor: Color
    let isCurrent: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Text(model.shortLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(isCurrent ? accentColor : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isCurrent ? accentColor.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ComposerAttachmentPreview: View {
    let attachment: ChatAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.isImage, let image = NSImage(contentsOf: attachment.fileURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipped()
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: attachment.kind == .audio ? "waveform" : "doc")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(attachment.displayName)
                            .font(.caption)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(width: 160, height: 64, alignment: .leading)
                    .padding(.horizontal, 10)
                }
            }
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.black.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
        }
        .frame(width: attachment.isImage ? 84 : 160, height: attachment.isImage ? 84 : 64)
    }
}

private struct VoiceWaveformView: View {
    let levels: [CGFloat]
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let samples = interpolatedLevels(targetCount: max(12, Int(geometry.size.width / 5)))
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(tint.opacity(0.92))
                        .frame(width: max(2, (geometry.size.width / CGFloat(max(samples.count, 1))) - 2), height: max(CGFloat(4), geometry.size.height * level))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
    }

    private func interpolatedLevels(targetCount: Int) -> [CGFloat] {
        guard !levels.isEmpty else { return Array(repeating: 0.12, count: targetCount) }
        guard targetCount > 0 else { return levels }
        if levels.count == targetCount { return levels }
        if levels.count == 1 { return Array(repeating: levels[0], count: targetCount) }

        return (0..<targetCount).map { index in
            let position = CGFloat(index) * CGFloat(levels.count - 1) / CGFloat(max(targetCount - 1, 1))
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, levels.count - 1)
            let fraction = position - CGFloat(lower)
            let start = levels[lower]
            let end = levels[upper]
            return start + ((end - start) * fraction)
        }
    }
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var dynamicHeight: CGFloat
    let textColor: Color
    let onSubmit: () -> Void
    let onPasteAttachments: (NSPasteboard) -> Void
    let onDropFiles: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            dynamicHeight: $dynamicHeight,
            onSubmit: onSubmit,
            onPasteAttachments: onPasteAttachments,
            onDropFiles: onDropFiles
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ComposerScrollView()
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.focusRingType = .none
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = NSColor.clear.cgColor

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onPasteAttachments = onPasteAttachments
        textView.onDropFiles = onDropFiles
        textView.registerForDraggedTypes([.fileURL])
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        let resolvedTextColor = NSColor(textColor).usingColorSpace(.sRGB) ?? .labelColor
        textView.textColor = resolvedTextColor
        textView.insertionPointColor = resolvedTextColor
        textView.textContainerInset = NSSize(width: 10, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.lineBreakMode = .byCharWrapping
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: max(scrollView.contentView.bounds.width - 20, 1), height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 20)
        textView.focusRingType = .none
        textView.string = text
        textView.frame = NSRect(x: 0, y: 0, width: 1, height: max(dynamicHeight, 30))

        scrollView.documentView = textView
        scrollView.composerTextView = textView
        context.coordinator.textView = textView
        Task { @MainActor in
            context.coordinator.recalculateHeight(for: textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.onPasteAttachments = onPasteAttachments
        textView.onDropFiles = onDropFiles
        if textView.string != text {
            textView.string = text
        }
        let resolvedTextColor = NSColor(textColor).usingColorSpace(.sRGB) ?? .labelColor
        textView.textColor = resolvedTextColor
        textView.insertionPointColor = resolvedTextColor
        if let composerScrollView = scrollView as? ComposerScrollView {
            composerScrollView.composerTextView = textView
            composerScrollView.needsLayout = true
            composerScrollView.layoutSubtreeIfNeeded()
        }
        Task { @MainActor in
            context.coordinator.recalculateHeight(for: textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var dynamicHeight: CGFloat
        let onSubmit: () -> Void
        let onPasteAttachments: (NSPasteboard) -> Void
        let onDropFiles: ([URL]) -> Void
        weak var textView: ComposerNSTextView?

        init(
            text: Binding<String>,
            dynamicHeight: Binding<CGFloat>,
            onSubmit: @escaping () -> Void,
            onPasteAttachments: @escaping (NSPasteboard) -> Void,
            onDropFiles: @escaping ([URL]) -> Void
        ) {
            self._text = text
            self._dynamicHeight = dynamicHeight
            self.onSubmit = onSubmit
            self.onPasteAttachments = onPasteAttachments
            self.onDropFiles = onDropFiles
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
            textView.enclosingScrollView?.needsLayout = true
            textView.enclosingScrollView?.layoutSubtreeIfNeeded()
            Task { @MainActor in
                self.recalculateHeight(for: textView)
            }
        }

        @MainActor
        func recalculateHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let next = min(max(usedRect.height + textView.textContainerInset.height * 2, 30), 340)
            if abs(dynamicHeight - next) > 0.5 {
                dynamicHeight = next
            }
        }
    }
}

private final class ComposerScrollView: NSScrollView {
    weak var composerTextView: NSTextView?

    override func layout() {
        super.layout()
        guard let textView = composerTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleWidth = contentView.bounds.width
        guard visibleWidth > 0 else { return }

        let textContainerWidth = max(visibleWidth - (textView.textContainerInset.width * 2), 1)
        textContainer.containerSize = NSSize(width: textContainerWidth, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)

        let usedRect = layoutManager.usedRect(for: textContainer)
        let fittedHeight = max(usedRect.height + textView.textContainerInset.height * 2, textView.minSize.height)
        textView.frame = NSRect(x: 0, y: 0, width: visibleWidth, height: fittedHeight)
    }
}

private final class ComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPasteAttachments: ((NSPasteboard) -> Void)?
    var onDropFiles: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if Self.isPasteShortcut(event) {
            let pasteboard = NSPasteboard.general
            if Self.hasAttachmentPayload(in: pasteboard) {
                onPasteAttachments?(pasteboard)
                return
            }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control) {
                paste(nil)
                return
            }
        }

        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.shift) {
                insertNewline(nil)
            } else {
                onSubmit?()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if Self.hasAttachmentPayload(in: pasteboard) {
            onPasteAttachments?(pasteboard)
            return
        }
        super.paste(sender)
    }

    private static func isPasteShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) else { return false }
        if event.keyCode == 9 { return true }
        return event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? [])
            .filter { $0.isFileURL }
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            }
    }

    private static func hasAttachmentPayload(in pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            return true
        }
        if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) {
            return true
        }
        let supportedTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            .png,
            .tiff,
            .URL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ]
        return pasteboard.types?.contains(where: { supportedTypes.contains($0) }) == true
    }
}
