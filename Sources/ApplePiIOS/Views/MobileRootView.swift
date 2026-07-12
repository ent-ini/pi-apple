import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ApplePiCore
import ApplePiRemote

#if canImport(UIKit)
import UIKit
#endif

struct MobileRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    @State private var showsSettings = false
    @State private var showsChat = false

    var body: some View {
        NavigationStack {
            MobileSessionListView(
                showsSettings: $showsSettings,
                onOpenDetail: { showsChat = true }
            )
            .navigationDestination(isPresented: $showsChat) {
                MobileSessionDetailView()
            }
            .hiddenMobileNavigationBar()
        }
        .tint(appState.appearance.accentColor)
        .preferredColorScheme(appState.appearance.colorScheme.colorScheme)
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                MobileSettingsView()
                    .navigationTitle("Remote API")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                showsSettings = false
                                Task {
                                    await appState.reloadCatalog()
                                    appState.startCatalogStream()
                                }
                            }
                        }
                    }
            }
        }
    }
}

private struct MobileSessionListView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    @Binding var showsSettings: Bool
    let onOpenDetail: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 10)
                .background(appState.appearance.topBarBackgroundColor(for: resolvedColorScheme))

            Divider().opacity(0.24)

            content
        }
        .foregroundStyle(appState.appearance.textColor(for: resolvedColorScheme))
        .background(appState.appearance.sidebarBackgroundColor(for: resolvedColorScheme).ignoresSafeArea())
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            MobileSearchField(text: $appState.sessionSearchText)

            MobileIconButton(systemName: "square.and.pencil", help: "New session") {
                appState.startNewSession()
                onOpenDetail()
            }

            MobileIconButton(systemName: "arrow.clockwise", help: "Refresh sessions", isDisabled: appState.isLoadingCatalog) {
                Task { await appState.reloadCatalog() }
            }

            MobileIconButton(systemName: "gearshape", help: "Settings") {
                showsSettings = true
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !appState.isConfigured {
            ContentUnavailableView(
                "Remote API required",
                systemImage: "network",
                description: Text("Open settings and enter your pi-appd URL.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appState.isLoadingCatalog && appState.sessions.isEmpty {
            ProgressView("Loading sessions…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appState.filteredSessions.isEmpty {
            ContentUnavailableView(
                appState.sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No sessions" : "No matches",
                systemImage: appState.sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                description: Text(appState.sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? appState.statusMessage : appState.sessionSearchText)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(appState.filteredSessions) { session in
                        Button {
                            appState.selectSession(session)
                            onOpenDetail()
                        } label: {
                            MobileSessionRow(
                                session: session,
                                isSelected: appState.selectedSession?.id == session.id,
                                isSending: session.isGenerating || appState.isSessionSending(session)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

private struct MobileSessionRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    let session: PiSessionSummary
    let isSelected: Bool
    let isSending: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(session.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(appState.appearance.textColor(for: resolvedColorScheme))
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text(session.modifiedAt, style: .date)
                        Label("\(session.messageCount)", systemImage: "text.bubble")
                        if let model = session.latestModel {
                            Text(model)
                        }
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isSending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(appState.appearance.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? MobileTheme.controlTint(for: resolvedColorScheme, opacity: 0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Divider()
                .padding(.leading, 12)
                .opacity(isSelected ? 0 : 0.28)
        }
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }
}

@MainActor
private final class MobileKeyboardObserver: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var visibleHeight: CGFloat = 0
    @Published private(set) var animationDuration: TimeInterval = 0.25

    #if canImport(UIKit)
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers = [
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardWillHideNotification
        ].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let userInfo = notification.userInfo ?? [:]
                let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
                let endFrame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)
                    ?? (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                let isHiding = notification.name == UIResponder.keyboardWillHideNotification
                Task { @MainActor [weak self] in
                    self?.handleKeyboardChange(isHiding: isHiding, endFrame: endFrame, duration: duration)
                }
            }
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func handleKeyboardChange(isHiding: Bool, endFrame: CGRect?, duration: TimeInterval) {
        animationDuration = duration

        guard !isHiding, let endFrame else {
            visibleHeight = 0
            return
        }
        visibleHeight = Self.additionalKeyboardInset(for: endFrame)
    }

    private static func additionalKeyboardInset(for endFrame: CGRect) -> CGFloat {
        guard let window = activeKeyWindow() else {
            return max(0, UIScreen.main.bounds.maxY - endFrame.minY)
        }
        let convertedFrame = window.convert(endFrame, from: nil)
        guard convertedFrame.isFinite else { return 0 }
        let overlapHeight = window.bounds.intersection(convertedFrame).height
        // The SwiftUI view is still laid out inside the regular bottom safe
        // area. Only add the keyboard overlap beyond that safe-area inset;
        // otherwise the composer floats above the keyboard by the home-indicator
        // height.
        return max(0, overlapHeight - window.safeAreaInsets.bottom)
    }

    private static func activeKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
    #else
    override init() {
        super.init()
    }
    #endif
}

private extension CGRect {
    var isFinite: Bool {
        origin.x.isFinite
            && origin.y.isFinite
            && size.width.isFinite
            && size.height.isFinite
    }
}

private struct MobileScrollViewportPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MobileScrollBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MobileHistoryLoadRowMinYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MobileComposerHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MobileSessionDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: MobilePiAppState
    @FocusState private var isComposerFocused: Bool
    @StateObject private var keyboardObserver = MobileKeyboardObserver()
    @State private var showsModelPicker = false
    @State private var showsThinkingPicker = false
    @State private var showsDefaultModelPicker = false
    @State private var showsDefaultThinkingPicker = false
    @State private var showsSubagents = false
    @State private var showsRenameAlert = false
    @State private var showsFileImporter = false
    @State private var showsPhotoPicker = false
    @State private var showsCamera = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var draftAttachments: [ChatAttachment] = []
    @StateObject private var audioRecorder = MobileAudioRecordingController()
    @State private var isTranscribingAudio = false
    @State private var voiceTranscriptionTask: Task<Void, Never>?
    @State private var renameDraftTitle = ""
    @State private var composerHeight: CGFloat = 0
    @State private var transcriptViewportHeight: CGFloat = 0
    @State private var transcriptBottomMaxY: CGFloat = 0
    @State private var isTranscriptPinnedToBottom = true
    @State private var isTranscriptDetachedByUser = false
    @State private var stickyAutoScrollUntil: Date?
    @State private var hasCompletedInitialScrollPlacement = false
    @State private var bottomScrollWorkItems: [DispatchWorkItem] = []
    @State private var bottomScrollGeneration = 0
    @State private var recentTranscriptUserScrollUntil: Date?
    @State private var historyLoadRowMinY: CGFloat = .greatestFiniteMagnitude
    @State private var showsScrollToBottomButton = false

    private static let slashCommands: [MobileSlashCommand] = [
        MobileSlashCommand(name: "/abort", description: "Stop the active run"),
        MobileSlashCommand(name: "/compact", description: "Compact this session")
    ]
    private static let transcriptCoordinateSpace = "MobileTranscriptScroll"
    private static let transcriptBottomID = "MobileTranscriptBottom"
    private static let transcriptAutoscrollBuffer: CGFloat = 180
    private static let transcriptBottomReachedEpsilon: CGFloat = 3
    private static let scrollToBottomButtonMinimumDistance: CGFloat = 360
    private static let historyAutoLoadDistance: CGFloat = 280
    private static let historyPageSize = 40
    private static let stickyAutoScrollDuration: TimeInterval = 30
    private static let recentUserScrollDuration: TimeInterval = 0.9
    private static let userScrollBreakawayDistance: CGFloat = 12
    private static let transcriptScrollSettleDelays: [TimeInterval] = [0.0, 0.12]
    private static let transcriptKeyboardScrollSettleDelays: [TimeInterval] = [0.0, 0.12, 0.28, 0.45]

    var body: some View {
        VStack(spacing: 0) {
            chatTopBar
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(appState.appearance.topBarBackgroundColor(for: resolvedColorScheme))

            Divider().opacity(0.24)

            ZStack(alignment: .bottom) {
                if appState.selectedSession != nil || !appState.selectedEvents.isEmpty {
                    transcript(title: appState.selectedSession?.title ?? "New session")
                } else {
                    ContentUnavailableView(
                        "New session",
                        systemImage: "message",
                        description: Text("Type a prompt below to start a remote session.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, composerHeight)
                }

                composer
            }
        }
        .foregroundStyle(appState.appearance.textColor(for: resolvedColorScheme))
        .padding(.bottom, keyboardObserver.visibleHeight)
        .background(appState.appearance.mainBackgroundColor(for: resolvedColorScheme).ignoresSafeArea())
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(.easeOut(duration: keyboardObserver.animationDuration), value: keyboardObserver.visibleHeight)
        .hiddenMobileNavigationBar()
        .task(id: appState.selectedSession?.id) {
            await appState.refreshSelectedRuntimeAndModels()
        }
        .sheet(isPresented: $showsModelPicker) {
            NavigationStack {
                MobileModelPickerSheet()
            }
            .environmentObject(appState)
        }
        .sheet(isPresented: $showsThinkingPicker) {
            NavigationStack {
                MobileThinkingPickerSheet()
            }
            .environmentObject(appState)
        }
        .sheet(isPresented: $showsDefaultModelPicker) {
            NavigationStack {
                MobileDefaultModelPickerSheet()
            }
            .environmentObject(appState)
        }
        .sheet(isPresented: $showsDefaultThinkingPicker) {
            NavigationStack {
                MobileDefaultThinkingPickerSheet()
            }
            .environmentObject(appState)
        }
        .sheet(isPresented: $showsSubagents) {
            NavigationStack {
                MobileSubagentsView()
            }
            .environmentObject(appState)
        }
        .alert("Rename Session", isPresented: $showsRenameAlert) {
            TextField("Name", text: $renameDraftTitle)
            Button("Rename") {
                appState.renameSelectedSession(to: renameDraftTitle)
            }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handleFileImporterResult
        )
        .photosPicker(isPresented: $showsPhotoPicker, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
        .sheet(isPresented: $showsCamera) {
            MobileCameraPicker { image in
                importCameraImage(image)
            }
            .ignoresSafeArea()
        }
        .mobileBackSwipe { dismiss() }
        .onAppear {
            appState.setChatVisible(true)
        }
        .onDisappear {
            appState.setChatVisible(false)
            if !appState.isSending {
                cleanupAttachments(draftAttachments)
                draftAttachments = []
            }
            if audioRecorder.isRecording {
                audioRecorder.cancelRecording()
            }
            voiceTranscriptionTask?.cancel()
            voiceTranscriptionTask = nil
            isTranscribingAudio = false
        }
    }

    private var chatTopBar: some View {
        HStack(spacing: 8) {
            MobileIconButton(systemName: "chevron.left", help: "Back") {
                dismiss()
            }

            sessionTitleMenu

            Spacer(minLength: 0)

            if appState.isSelectedSessionBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(appState.appearance.accentColor)
            }

            MobileIconButton(systemName: "square.and.pencil", help: "New session") {
                appState.startNewSession()
            }

            MobileIconButton(systemName: "person.2.wave.2", help: "Subagents", isDisabled: appState.selectedSession == nil) {
                showsSubagents = true
            }
        }
    }

    private var sessionTitleMenu: some View {
        Menu {
            if appState.selectedSession == nil {
                Button("Context: \(appState.defaultContextWindowDisplayName)") {}
                    .disabled(true)

                Button("Model: \(appState.defaultModelDisplayName)") {
                    showsDefaultModelPicker = true
                    appState.refreshAvailableModelsCache()
                }

                Button("Thinking: \(appState.defaultThinkingDisplayName)") {
                    showsDefaultThinkingPicker = true
                }
                .disabled(appState.defaultModelPreference == nil)
            } else {
                Button("Rename") {
                    renameDraftTitle = appState.selectedSession?.title ?? ""
                    showsRenameAlert = true
                }

                Divider()

                Button("Context: \(appState.selectedContextUsageDisplayName)") {}
                    .disabled(true)

                Button("Model: \(appState.selectedModelDisplayName)") {
                    showsModelPicker = true
                    appState.refreshAvailableModelsCache()
                }

                Button("Thinking: \(appState.selectedThinkingLevel)") {
                    showsThinkingPicker = true
                }

                Divider()

                Button("Refresh runtime") {
                    Task { await appState.refreshSelectedRuntimeAndModels() }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(appState.selectedSession?.title ?? "New Session")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .mobileBlobStyle(colorScheme: resolvedColorScheme)
        }
        .buttonStyle(.plain)
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }

    private func transcript(title: String) -> some View {
        let rows = MobileDisplayedRow.groupingToolResults(in: appState.filteredVisibleEvents)
        let scrollSignature = "\(rows.count):\(rows.last?.scrollFingerprint ?? "empty"):\(Int(transcriptBottomSpacerHeight.rounded()))"
        return GeometryReader { viewportProxy in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if appState.hasEarlierHistory || appState.isLoadingEarlierHistory {
                            historyLoadRow
                        }
                        ForEach(rows) { row in
                            MobileEventRow(row: row)
                                .id(row.id)
                        }
                        Color.clear
                            .frame(height: transcriptBottomSpacerHeight)
                            .id(Self.transcriptBottomID)
                            .background(
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: MobileScrollBottomPreferenceKey.self,
                                        value: geometry.frame(in: .named(Self.transcriptCoordinateSpace)).maxY
                                    )
                                }
                            )
                    }
                    .padding()
                    .frame(minHeight: viewportProxy.size.height, alignment: .top)
                }
                .coordinateSpace(name: Self.transcriptCoordinateSpace)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: MobileScrollViewportPreferenceKey.self, value: geometry.size.height)
                    }
                )
                .scrollContentBackground(.hidden)
                .contentShape(Rectangle())
                .mobileScrollKeepsKeyboardVisible()
                .simultaneousGesture(dismissKeyboardTapGesture)
                .simultaneousGesture(transcriptUserScrollGesture)
                .overlay {
                    if appState.isLoadingSession && appState.selectedEvents.isEmpty {
                        ProgressView()
                    }
                }
                .onPreferenceChange(MobileScrollViewportPreferenceKey.self) { height in
                    transcriptViewportHeight = height
                    updateTranscriptPinnedState(scrollProxy: proxy)
                }
                .onPreferenceChange(MobileScrollBottomPreferenceKey.self) { maxY in
                    transcriptBottomMaxY = maxY
                    updateTranscriptPinnedState(scrollProxy: proxy)
                }
                .onPreferenceChange(MobileHistoryLoadRowMinYPreferenceKey.self) { minY in
                    historyLoadRowMinY = minY
                    autoLoadEarlierHistoryIfUserScrolledNearTop()
                }
                .onAppear {
                    resetTranscriptScrollState()
                    scrollToBottomSettled(proxy: proxy, animated: false, completesInitialPlacement: true)
                }
                .onDisappear {
                    cancelBottomScrollWorkItems()
                }
                .onChange(of: appState.selectedSession?.id) { _, _ in
                    resetTranscriptScrollState()
                    scrollToBottomSettled(proxy: proxy, animated: false, completesInitialPlacement: true)
                }
                .onChange(of: appState.isSending) { _, isSending in
                    guard isSending else { return }
                    startStickyAutoScroll()
                    scrollToBottomSettled(proxy: proxy, animated: false, completesInitialPlacement: !hasCompletedInitialScrollPlacement)
                }
                .onChange(of: appState.historyRevision) { _, _ in
                    stickyAutoScrollUntil = nil
                    isTranscriptPinnedToBottom = false
                    isTranscriptDetachedByUser = true
                    cancelBottomScrollWorkItems()
                    if let anchorID = appState.consumePendingEarlierHistoryAnchorID() {
                        let rowID = MobileDisplayedRow.scrollID(forEventID: anchorID, in: rows) ?? anchorID
                        proxy.scrollTo(rowID, anchor: .top)
                    }
                }
                .onChange(of: keyboardObserver.visibleHeight) { oldHeight, newHeight in
                    guard newHeight > oldHeight,
                          isTranscriptPinnedToBottom || isComposerFocused else { return }
                    isTranscriptDetachedByUser = false
                    startStickyAutoScroll()
                    scrollToBottomForKeyboard(proxy: proxy)
                }
                .onChange(of: scrollSignature) { _, _ in
                    scrollToBottomIfNeeded(proxy: proxy)
                }
                .overlay(alignment: .bottomTrailing) {
                    if showsScrollToBottomButton {
                        Button {
                            isTranscriptPinnedToBottom = true
                            isTranscriptDetachedByUser = false
                            showsScrollToBottomButton = false
                            startStickyAutoScroll()
                            scrollToBottomSettled(proxy: proxy, animated: true, completesInitialPlacement: false)
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(appState.appearance.accentColor)
                                .frame(width: 36, height: 36)
                                .background(.regularMaterial, in: Circle())
                                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Scroll to bottom")
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                        .transition(.scale(scale: 0.88).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.16), value: showsScrollToBottomButton)
            }
        }
    }

    private var transcriptBottomSpacerHeight: CGFloat {
        max(1, composerHeight + 18)
    }

    @ViewBuilder
    private var historyLoadRow: some View {
        HStack {
            Spacer()
            if appState.isLoadingEarlierHistory {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading earlier messages")
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
            Spacer()
        }
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .background {
            GeometryReader { historyProxy in
                Color.clear.preference(
                    key: MobileHistoryLoadRowMinYPreferenceKey.self,
                    value: historyProxy.frame(in: .named(Self.transcriptCoordinateSpace)).minY
                )
            }
        }
        .onAppear {
            guard hasCompletedInitialScrollPlacement,
                  isTranscriptDetachedByUser || !isTranscriptPinnedToBottom else { return }
            loadEarlierHistoryPage(userInitiated: true)
        }
        .id("mobile-history-load-row")
    }

    private func loadEarlierHistoryPage(userInitiated: Bool) {
        guard appState.hasEarlierHistory,
              !appState.isLoadingEarlierHistory else { return }
        stickyAutoScrollUntil = nil
        isTranscriptPinnedToBottom = false
        isTranscriptDetachedByUser = true
        cancelBottomScrollWorkItems()
        Task {
            await appState.loadEarlierSelectedHistory(
                limit: Self.historyPageSize,
                preserveVisiblePosition: userInitiated
            )
        }
    }

    private func autoLoadEarlierHistoryIfUserScrolledNearTop() {
        guard isRecentTranscriptUserScrollActive,
              historyLoadRowMinY.isFinite,
              historyLoadRowMinY >= -Self.historyAutoLoadDistance,
              historyLoadRowMinY <= Self.historyAutoLoadDistance else {
            return
        }
        loadEarlierHistoryPage(userInitiated: true)
    }

    private func resetTranscriptScrollState() {
        cancelBottomScrollWorkItems()
        isTranscriptPinnedToBottom = true
        isTranscriptDetachedByUser = false
        stickyAutoScrollUntil = Date().addingTimeInterval(Self.stickyAutoScrollDuration)
        hasCompletedInitialScrollPlacement = false
        showsScrollToBottomButton = false
        recentTranscriptUserScrollUntil = nil
        historyLoadRowMinY = .greatestFiniteMagnitude
    }

    private var isStickyAutoScrollActive: Bool {
        guard let stickyAutoScrollUntil else { return false }
        return stickyAutoScrollUntil > Date()
    }

    private var isRecentTranscriptUserScrollActive: Bool {
        guard let recentTranscriptUserScrollUntil else { return false }
        return recentTranscriptUserScrollUntil > Date()
    }

    private var transcriptUserScrollGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                noteTranscriptUserScrollIntent(value)
            }
    }

    private func noteTranscriptUserScrollIntent(_ value: DragGesture.Value) {
        recentTranscriptUserScrollUntil = Date().addingTimeInterval(Self.recentUserScrollDuration)
        autoLoadEarlierHistoryIfUserScrolledNearTop()
        guard abs(value.translation.height) > 4,
              abs(value.translation.height) > abs(value.translation.width) else { return }
        // A deliberate user drag must win over live-tail auto-scroll immediately;
        // otherwise streaming responses keep snapping the transcript back down.
        stickyAutoScrollUntil = nil
        isTranscriptPinnedToBottom = false
        isTranscriptDetachedByUser = true
        cancelBottomScrollWorkItems()
    }

    private func startStickyAutoScroll() {
        stickyAutoScrollUntil = Date().addingTimeInterval(Self.stickyAutoScrollDuration)
    }

    private func updateTranscriptPinnedState(scrollProxy: ScrollViewProxy) {
        guard transcriptViewportHeight > 0,
              transcriptBottomMaxY.isFinite,
              transcriptBottomMaxY < .greatestFiniteMagnitude / 2 else { return }
        let distanceFromBottom = transcriptBottomMaxY - transcriptViewportHeight
        updateScrollToBottomButton(distanceFromBottom: distanceFromBottom)

        if isStickyAutoScrollActive {
            if isRecentTranscriptUserScrollActive,
               distanceFromBottom > Self.userScrollBreakawayDistance {
                stickyAutoScrollUntil = nil
                isTranscriptPinnedToBottom = false
                isTranscriptDetachedByUser = true
                cancelBottomScrollWorkItems()
                return
            }
            isTranscriptPinnedToBottom = true
            isTranscriptDetachedByUser = false
            if distanceFromBottom > Self.transcriptBottomReachedEpsilon,
               bottomScrollWorkItems.isEmpty {
                scrollToBottomSettled(
                    proxy: scrollProxy,
                    animated: false,
                    completesInitialPlacement: !hasCompletedInitialScrollPlacement
                )
            }
            return
        }

        let isNearBottom = distanceFromBottom <= Self.transcriptAutoscrollBuffer
        isTranscriptPinnedToBottom = isNearBottom
        if isNearBottom {
            isTranscriptDetachedByUser = false
        }
    }

    private func updateScrollToBottomButton(distanceFromBottom: CGFloat) {
        let threshold = max(Self.scrollToBottomButtonMinimumDistance, transcriptViewportHeight * 0.8)
        let shouldShow = hasCompletedInitialScrollPlacement && distanceFromBottom > threshold
        if showsScrollToBottomButton != shouldShow {
            showsScrollToBottomButton = shouldShow
        }
    }

    private func scrollToBottomIfNeeded(proxy: ScrollViewProxy) {
        let shouldFollowLiveTail = isTranscriptPinnedToBottom || isStickyAutoScrollActive || !isTranscriptDetachedByUser
        guard shouldFollowLiveTail else { return }
        startStickyAutoScroll()
        guard bottomScrollWorkItems.isEmpty else { return }
        scrollToBottomSettled(proxy: proxy, animated: false, completesInitialPlacement: !hasCompletedInitialScrollPlacement)
    }

    private func scrollToBottomForKeyboard(proxy: ScrollViewProxy) {
        scrollToBottomSettled(
            proxy: proxy,
            animated: false,
            completesInitialPlacement: !hasCompletedInitialScrollPlacement,
            delays: Self.transcriptKeyboardScrollSettleDelays
        )
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo(Self.transcriptBottomID, anchor: .bottom)
        }
        if animated {
            withAnimation(.easeOut(duration: 0.12)) { action() }
        } else {
            action()
        }
    }

    private func scrollToBottomSettled(
        proxy: ScrollViewProxy,
        animated: Bool,
        completesInitialPlacement: Bool,
        delays: [TimeInterval] = Self.transcriptScrollSettleDelays
    ) {
        cancelBottomScrollWorkItems()
        bottomScrollGeneration &+= 1
        let generation = bottomScrollGeneration
        let settleDelays = delays.isEmpty ? [0] : delays

        let workItems = settleDelays.enumerated().map { index, delay in
            let item = DispatchWorkItem {
                guard bottomScrollGeneration == generation else { return }
                scrollToBottom(proxy: proxy, animated: animated && index == 0)
                if index == settleDelays.count - 1 {
                    if completesInitialPlacement {
                        hasCompletedInitialScrollPlacement = true
                    }
                    if bottomScrollGeneration == generation {
                        bottomScrollWorkItems = []
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
        bottomScrollWorkItems = workItems
    }

    private func cancelBottomScrollWorkItems() {
        bottomScrollGeneration &+= 1
        bottomScrollWorkItems.forEach { $0.cancel() }
        bottomScrollWorkItems = []
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsSlashCommandSuggestions {
                slashCommandSuggestions
            }

            if !draftAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(draftAttachments) { attachment in
                            MobileComposerAttachmentPreview(attachment: attachment) {
                                removeAttachment(attachment)
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button {
                        showsCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                    .disabled(!MobileCameraPicker.isAvailable)

                    Button {
                        showsPhotoPicker = true
                    } label: {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        showsFileImporter = true
                    } label: {
                        Label("Choose File", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Add attachment")
                .tint(appState.appearance.accentColor)

                TextField("", text: $appState.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($isComposerFocused)
                    .padding(.vertical, 8)
                    .foregroundStyle(appState.appearance.textColor(for: resolvedColorScheme))

                MobileComposerIconButton(systemName: audioRecorder.isRecording ? "stop.fill" : "mic.fill", isDisabled: isTranscribingAudio) {
                    handleMicrophoneTapped()
                }

                MobileComposerIconButton(
                    systemName: "arrow.up",
                    isDisabled: !canSendDraft
                ) {
                    handleComposerSubmit()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(appState.appearance.composerAreaBackgroundColor(for: resolvedColorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, keyboardObserver.visibleHeight > 0 ? 6 : 8)
        .frame(maxWidth: .infinity)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: MobileComposerHeightPreferenceKey.self, value: geometry.size.height)
            }
        )
        .onPreferenceChange(MobileComposerHeightPreferenceKey.self) { height in
            guard height > 0, abs(composerHeight - height) > 0.5 else { return }
            composerHeight = height
        }
    }

    private var canSendDraft: Bool {
        !appState.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty
    }

    private var dismissKeyboardTapGesture: some Gesture {
        TapGesture()
            .onEnded {
                guard isComposerFocused else { return }
                dismissKeyboard()
            }
    }

    private func dismissKeyboard() {
        isComposerFocused = false
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private var slashCommandMatches: [MobileSlashCommand] {
        guard let query = mobileSlashCommandQuery(in: appState.draft) else { return [] }
        return Self.slashCommands.filter { command in
            let bareName = String(command.name.dropFirst())
            return query.isEmpty || bareName.hasPrefix(query) || command.name.hasPrefix("/\(query)")
        }
    }

    private var showsSlashCommandSuggestions: Bool {
        !slashCommandMatches.isEmpty && draftAttachments.isEmpty && !audioRecorder.isRecording && !isTranscribingAudio
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
                .fill(MobileTheme.controlTint(for: resolvedColorScheme, opacity: 0.10))
                .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    private func handleComposerSubmit() {
        let prompt = appState.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slashCommand = parseMobileSlashCommand(prompt) {
            switch slashCommand {
            case .abort:
                handleAbortCommand()
            case .compact(let instructions):
                handleCompactCommand(instructions: instructions)
            }
            return
        }
        sendDraftToPi()
    }

    private func sendDraftToPi() {
        isComposerFocused = true
        let attachmentsToSend = draftAttachments
        Task {
            let sent = await appState.sendDraft(attachments: attachmentsToSend)
            await MainActor.run {
                if sent {
                    if draftAttachments == attachmentsToSend {
                        draftAttachments = []
                    }
                    cleanupAttachments(attachmentsToSend)
                }
                isComposerFocused = true
            }
        }
    }

    private func handleAbortCommand() {
        clearComposer()
        Task { await appState.abortSelectedSession() }
    }

    private func handleCompactCommand(instructions: String) {
        clearComposer()
        Task { await appState.compactSelectedSession(instructions: instructions) }
    }

    private func clearComposer() {
        appState.draft = ""
        cleanupAttachments(draftAttachments)
        draftAttachments = []
    }

    private func selectSlashCommand(_ command: MobileSlashCommand) {
        appState.draft = command.name
        isComposerFocused = true
    }

    private func handleMicrophoneTapped() {
        if audioRecorder.isRecording {
            finishVoiceRecording()
            return
        }
        guard !isTranscribingAudio else { return }

        switch MobileAudioRecordingController.microphoneAuthorizationStatus() {
        case .authorized:
            startVoiceRecording()
        case .notDetermined:
            appState.showStatus("Requesting microphone access…")
            MobileAudioRecordingController.requestMicrophoneAccess { granted in
                Task { @MainActor in
                    if granted {
                        startVoiceRecording()
                    } else {
                        appState.showStatus(MobileAudioRecordingError.microphonePermissionDenied.localizedDescription)
                    }
                }
            }
        case .denied, .restricted:
            appState.showStatus(MobileAudioRecordingError.microphonePermissionDenied.localizedDescription)
        @unknown default:
            appState.showStatus(MobileAudioRecordingError.microphonePermissionDenied.localizedDescription)
        }
    }

    private func startVoiceRecording() {
        do {
            try audioRecorder.startRecordingAuthorized()
            appState.showStatus("Recording voice… tap stop to transcribe.")
        } catch {
            appState.showStatus(error.localizedDescription)
        }
    }

    private func finishVoiceRecording() {
        do {
            let recordingURL = try audioRecorder.stopRecording()
            transcribeVoiceRecording(recordingURL)
        } catch {
            appState.showStatus(error.localizedDescription)
        }
    }

    private func transcribeVoiceRecording(_ fileURL: URL) {
        isTranscribingAudio = true
        appState.showStatus("Transcribing voice…")
        voiceTranscriptionTask?.cancel()
        voiceTranscriptionTask = Task {
            do {
                let transcript = try await RemoteDaemonClient().transcribeAudio(
                    host: appState.host,
                    fileURL: fileURL,
                    tokenOverride: appState.daemonToken.nilIfBlank
                )
                try? FileManager.default.removeItem(at: fileURL)
                await MainActor.run {
                    mergeVoiceTranscript(transcript)
                    isTranscribingAudio = false
                    voiceTranscriptionTask = nil
                    appState.showStatus("Voice transcribed.")
                    isComposerFocused = true
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: fileURL)
                await MainActor.run {
                    isTranscribingAudio = false
                    voiceTranscriptionTask = nil
                }
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                await MainActor.run {
                    isTranscribingAudio = false
                    voiceTranscriptionTask = nil
                    appState.showStatus(error.localizedDescription)
                }
            }
        }
    }

    private func mergeVoiceTranscript(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let current = appState.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.draft = current.isEmpty ? trimmed : "\(current)\n\(trimmed)"
    }

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            addAttachments(from: urls)
        case .failure(let error):
            appState.showStatus(error.localizedDescription)
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        defer { selectedPhoto = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                appState.showStatus("Could not load the selected photo.")
                return
            }
            let contentType = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .jpeg
            let extensionName = contentType.preferredFilenameExtension ?? "jpg"
            let attachment = try MobileAttachmentStagingService.stageImageData(
                data,
                suggestedName: "photo-\(UUID().uuidString).\(extensionName)",
                contentType: contentType
            )
            appendAttachments([attachment])
        } catch {
            appState.showStatus(error.localizedDescription)
        }
    }

    private func importCameraImage(_ image: UIImage?) {
        guard let image else { return }
        do {
            guard let data = image.jpegData(compressionQuality: 0.92) else {
                appState.showStatus("Could not prepare the photo.")
                return
            }
            let attachment = try MobileAttachmentStagingService.stageImageData(
                data,
                suggestedName: "camera-\(UUID().uuidString).jpg",
                contentType: .jpeg
            )
            appendAttachments([attachment])
        } catch {
            appState.showStatus(error.localizedDescription)
        }
    }

    private func addAttachments(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        do {
            let staged = try urls.map { try MobileAttachmentStagingService.stageFile(at: $0) }
            appendAttachments(staged)
        } catch {
            appState.showStatus(error.localizedDescription)
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
}

private enum MobileAttachmentStagingService {
    static func stageFile(at sourceURL: URL) throws -> ChatAttachment {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let destinationURL = try makeDestinationURL(
            suggestedName: sourceURL.lastPathComponent,
            preferredExtension: sourceURL.pathExtension.nilIfBlank
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        let values = try destinationURL.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        let type = values.contentType
        return ChatAttachment(
            kind: chatAttachmentKind(for: type),
            fileURL: destinationURL,
            displayName: sourceURL.lastPathComponent.nilIfBlank ?? destinationURL.lastPathComponent,
            mimeType: type?.preferredMIMEType,
            size: values.fileSize.map(Int64.init)
        )
    }

    static func stageImageData(_ data: Data, suggestedName: String, contentType: UTType) throws -> ChatAttachment {
        let destinationURL = try makeDestinationURL(
            suggestedName: suggestedName,
            preferredExtension: contentType.preferredFilenameExtension ?? URL(fileURLWithPath: suggestedName).pathExtension.nilIfBlank
        )
        try data.write(to: destinationURL, options: .atomic)
        return ChatAttachment(
            kind: .image,
            fileURL: destinationURL,
            displayName: suggestedName,
            mimeType: contentType.preferredMIMEType,
            size: Int64(data.count)
        )
    }

    private static func makeDestinationURL(suggestedName: String, preferredExtension: String?) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("ApplePiIOS/attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let rawBaseName = URL(fileURLWithPath: suggestedName).deletingPathExtension().lastPathComponent
        let sanitizedBaseName = rawBaseName
            .replacingOccurrences(of: #"[^A-Za-z0-9._ -]+"#, with: "_", options: .regularExpression)
            .nilIfBlank ?? "attachment"
        let uniqueName = "\(sanitizedBaseName)-\(UUID().uuidString)"
        if let ext = preferredExtension?.nilIfBlank {
            return directory.appendingPathComponent(uniqueName).appendingPathExtension(ext)
        }
        return directory.appendingPathComponent(uniqueName)
    }

    private static func chatAttachmentKind(for type: UTType?) -> ChatAttachment.Kind {
        guard let type else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        return .file
    }
}

private struct MobileCameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    let onComplete: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete, dismiss: dismiss) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onComplete: (UIImage?) -> Void
        let dismiss: DismissAction
        init(onComplete: @escaping (UIImage?) -> Void, dismiss: DismissAction) {
            self.onComplete = onComplete
            self.dismiss = dismiss
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onComplete(info[.originalImage] as? UIImage)
            dismiss()
        }
    }
}

private struct MobileComposerAttachmentPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    let attachment: ChatAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: iconName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(appState.appearance.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 150, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(MobileTheme.controlTint(for: resolvedColorScheme, opacity: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var iconName: String {
        switch attachment.kind {
        case .image: return "photo"
        case .audio: return "waveform"
        case .file: return "doc"
        }
    }

    private var subtitle: String? {
        if let size = attachment.size {
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        return attachment.mimeType
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }
}

private struct MobileModelGroup: Identifiable {
    let provider: String
    let models: [PiModelOption]
    var id: String { provider }
}

private enum MobileDisplayedRow: Identifiable, Hashable {
    case event(SessionEvent)
    case toolInteraction(call: ToolCall, result: ToolResult?, lineIndex: Int)

    var id: String {
        switch self {
        case .event(let event):
            return event.id
        case .toolInteraction(let call, _, _):
            return "toolInteraction:\(call.id)"
        }
    }

    var scrollFingerprint: String {
        switch self {
        case .event(let event):
            return "\(event.id):\(event.contentLengthForScrolling)"
        case .toolInteraction(let call, let result, _):
            return "toolInteraction:\(call.id):\(call.arguments.count):\(result?.output.count ?? 0)"
        }
    }

    func containsEventID(_ eventID: String) -> Bool {
        switch self {
        case .event(let event):
            return event.id == eventID
        case .toolInteraction(let call, let result, _):
            return eventID == "toolCall:\(call.id)" || result.map { eventID == "toolResult:\($0.id)" } == true
        }
    }

    static func scrollID(forEventID eventID: String, in rows: [MobileDisplayedRow]) -> String? {
        rows.first { $0.containsEventID(eventID) }?.id
    }

    static func groupingToolResults(in events: [SessionEvent]) -> [MobileDisplayedRow] {
        var resultByCallID: [String: ToolResult] = [:]
        var callIDs = Set<String>()

        for event in events {
            switch event {
            case .toolCall(let call, _):
                callIDs.insert(call.id)
            case .toolResult(let result, _):
                guard !result.callId.isEmpty else { continue }
                resultByCallID[result.callId] = result
            case .message, .meta, .other:
                continue
            }
        }

        let pairedCallIDs = Set(callIDs.filter { resultByCallID[$0] != nil })
        return events.compactMap { event in
            switch event {
            case .toolCall(let call, let lineIndex):
                return .toolInteraction(call: call, result: resultByCallID[call.id], lineIndex: lineIndex)
            case .toolResult(let result, _):
                if pairedCallIDs.contains(result.callId) { return nil }
                return .event(event)
            case .message, .meta, .other:
                return .event(event)
            }
        }
    }
}

private extension SessionEvent {
    var contentLengthForScrolling: Int {
        switch self {
        case .message(let message, _):
            return message.content.reduce(0) { partial, block in
                switch block {
                case .text(let text):
                    return partial + text.count
                case .thinking(let text, let signature):
                    return partial + text.count + (signature?.count ?? 0)
                case .image(let path, let mime):
                    return partial + path.count + (mime?.count ?? 0)
                }
            }
        case .toolCall(let call, _):
            return call.arguments.count
        case .toolResult(let result, _):
            return result.output.count
        case .other(let type, _):
            return type.count
        case .meta(let meta, _):
            return meta.id.count + (meta.displayName?.count ?? 0)
        }
    }
}

private struct MobileEventRow: View {
    let row: MobileDisplayedRow

    var body: some View {
        switch row {
        case .event(let event):
            switch event {
            case .message(let message, _):
                MessageBubble(message: message)
            case .toolCall(let call, _):
                ToolBlock(title: "tool · \(call.name)", sections: [("Call", call.arguments)])
            case .toolResult(let result, _):
                ToolBlock(title: result.toolName ?? "Tool result", sections: [("Response", result.output)], isError: result.isError)
            case .other(let type, _):
                ToolBlock(title: type, sections: [])
            case .meta:
                EmptyView()
            }
        case .toolInteraction(let call, let result, _):
            ToolBlock(
                title: "tool · \(call.name)",
                sections: [
                    ("Call", call.arguments),
                    ("Response", result?.output ?? "(waiting for tool result)")
                ],
                isError: result?.isError == true
            )
        }
    }
}

private struct MessageBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    let message: Message

    var body: some View {
        if shouldRenderRow {
            HStack(alignment: .top, spacing: 0) {
                if message.role == .user {
                    Spacer(minLength: 32)
                    bubbleColumn(alignment: .trailing)
                } else {
                    bubbleColumn(alignment: .leading)
                    Spacer(minLength: 32)
                }
            }
            .contextMenu {
                Button("Copy message") {
                    copyMessageToPasteboard()
                }
            }
        }
    }

    private func bubbleColumn(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            if !thinkingText.isEmpty {
                MobileThinkingSummaryView(thinkingText: thinkingText)
            }
            ForEach(Array(visibleBlocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isLastVisibleBlock: index == visibleBlocks.count - 1)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ContentBlock, isLastVisibleBlock: Bool) -> some View {
        switch block {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                bubbleSurface(isLastVisibleBlock: isLastVisibleBlock) {
                    MobileMarkdownText(trimmed)
                }
            }
        case .thinking:
            EmptyView()
        case .image(let path, let mime):
            bubbleSurface(isLastVisibleBlock: isLastVisibleBlock) {
                MobileAttachmentImage(path: path, mimeType: mime)
            }
        }
    }

    private func bubbleSurface<Content: View>(isLastVisibleBlock: Bool, @ViewBuilder content: () -> Content) -> some View {
        let showsTimestamp = isLastVisibleBlock && formattedTime != nil
        return VStack(alignment: .leading, spacing: 0) {
            content()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, showsTimestamp ? 24 : 12)
        .background(bubbleBackground)
        .foregroundStyle(bubbleTextColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if isLastVisibleBlock, let timestamp = formattedTime {
                Text(timestamp)
                    .font(.caption2)
                    .foregroundStyle(timestampColor)
                    .padding(.trailing, 10)
                    .padding(.bottom, 7)
            }
        }
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

    private var bubbleTextColor: Color {
        switch message.role {
        case .user:
            return appState.appearance.userMessageTextColor
        case .assistant, .system:
            return appState.appearance.assistantMessageTextColor(for: resolvedColorScheme)
        }
    }

    private var timestampColor: Color {
        bubbleTextColor.opacity(message.role == .user ? 0.82 : 0.64)
    }

    private var formattedTime: String? {
        guard let timestamp = message.timestamp else { return nil }
        return Self.timeFormatter.string(from: timestamp)
    }

    private var visibleBlocks: [ContentBlock] {
        message.content.compactMap { block in
            switch block {
            case .thinking:
                return nil
            case .text(let rawText):
                let visible = MobileMessageTextSanitizer.visibleText(from: rawText)
                return visible.isEmpty ? nil : .text(visible)
            case .image:
                return block
            }
        }
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

    private var shouldRenderRow: Bool {
        !thinkingText.isEmpty || !visibleBlocks.isEmpty
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }

    private func copyMessageToPasteboard() {
        let text = MobileMessageTextSanitizer.copyText(from: message)
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct MobileAttachmentImage: View {
    let path: String
    let mimeType: String?

    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if didFail {
                Label("Image attachment", systemImage: "photo")
                    .font(.subheadline)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 72, height: 56)
            }
        }
        .task(id: path) {
            await loadImage()
        }
    }

    private func loadImage() async {
        let data: Data?
        if path.hasPrefix("data:"), let comma = path.firstIndex(of: ",") {
            data = Data(base64Encoded: String(path[path.index(after: comma)...]))
        } else if path.hasPrefix("/") {
            // This is the staged file while a send is in flight. Persisted
            // messages instead carry the base64 image block from the daemon.
            data = try? Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            data = nil
        }
        guard !Task.isCancelled else { return }
        image = data.flatMap(UIImage.init(data:))
        didFail = image == nil
    }
}

private enum MobileMessageTextSanitizer {
    static func visibleText(from text: String) -> String {
        let withoutSource = text.replacingOccurrences(
            of: #"(?:^|\s)\[source:[^\]]+\]\s*"#,
            with: "\n",
            options: .regularExpression
        )
        let withoutTelegramTopic = withoutSource.replacingOccurrences(
            of: #"(?:^|\n)\[telegram_topic\][\s\S]*?\[/telegram_topic\]\n?"#,
            with: "\n",
            options: .regularExpression
        )
        let withoutFileTags = withoutTelegramTopic.replacingOccurrences(
            of: #"<file\s+name=\"[^\"]*\">\[([^\]]+)\]</file>"#,
            with: "$1",
            options: .regularExpression
        )
        let collapsed = withoutFileTags.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func copyText(from message: Message) -> String {
        let parts = message.content.compactMap { block -> String? in
            switch block {
            case .text(let text):
                let visible = visibleText(from: text)
                return visible.isEmpty ? nil : visible
            case .thinking:
                return nil
            case .image:
                return "[image attachment]"
            }
        }
        return parts.joined(separator: "\n\n")
    }
}

private struct MobileThinkingSummaryView: View {
    let thinkingText: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Thinking")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(thinkingText)
                    .textSelection(.enabled)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct ToolBlock: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    let title: String
    let sections: [(label: String, text: String)]
    var isError = false
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isError ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isError ? .red : .secondary)
                        Text(title)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    if sections.isEmpty {
                        Text("(no details)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                            toolSection(title: section.label, text: section.text)
                        }
                    }
                }
            }
            .padding(.horizontal, isExpanded ? 10 : 0)
            .padding(.vertical, isExpanded ? 8 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isExpanded {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(MobileTheme.controlTint(for: resolvedColorScheme, opacity: 0.06))
                }
            }
            Spacer(minLength: 32)
        }
    }

    private func toolSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(empty)" : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(MobileTheme.controlTint(for: resolvedColorScheme, opacity: 0.05))
                )
        }
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }
}

private struct MobileSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    @State private var showsDefaultModelPicker = false
    @State private var showsDefaultThinkingPicker = false
    @State private var appearanceClipboardStatus: String?

    var body: some View {
        Form {
            appearanceSection
            piDefaultsSection
            remoteAPISection
            Section("Status") {
                Text(appState.statusMessage)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(appState.appearance.mainBackgroundColor(for: resolvedColorScheme).ignoresSafeArea())
        .sheet(isPresented: $showsDefaultModelPicker) {
            NavigationStack {
                MobileDefaultModelPickerSheet()
            }
            .environmentObject(appState)
        }
        .sheet(isPresented: $showsDefaultThinkingPicker) {
            NavigationStack {
                MobileDefaultThinkingPickerSheet()
            }
            .environmentObject(appState)
        }
        .onAppear {
            appState.refreshAvailableModelsCache()
            Task { await appState.refreshSessionDefaultsCache(quietly: true) }
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Mode", selection: Binding(
                get: { appState.appearance.colorScheme },
                set: { newValue in appState.updateAppearance { $0.colorScheme = newValue } }
            )) {
                ForEach(MobileAppColorSchemePreference.allCases) { scheme in
                    Text(scheme.title).tag(scheme)
                }
            }
            .pickerStyle(.segmented)

            ColorPicker("Accent", selection: Binding(
                get: { appState.appearance.accentColor },
                set: { newValue in appState.updateAppearance { $0.setAccentColor(newValue) } }
            ), supportsOpacity: false)

            ColorPicker("Main background", selection: Binding(
                get: { appState.appearance.mainBackgroundColor(for: resolvedColorScheme) },
                set: { newValue in appState.updateAppearance { $0.setMainBackgroundColor(newValue) } }
            ), supportsOpacity: false)

            ColorPicker("Top bar", selection: Binding(
                get: { appState.appearance.topBarBackgroundColor(for: resolvedColorScheme) },
                set: { newValue in appState.updateAppearance { $0.setTopBarBackgroundColor(newValue) } }
            ), supportsOpacity: false)

            ColorPicker("Sidebars background", selection: Binding(
                get: { appState.appearance.sidebarBackgroundColor(for: resolvedColorScheme) },
                set: { newValue in appState.updateAppearance { $0.setSidebarBackgroundColor(newValue) } }
            ), supportsOpacity: false)

            ColorPicker("Composer area", selection: Binding(
                get: { appState.appearance.composerAreaBackgroundColor(for: resolvedColorScheme) },
                set: { newValue in appState.updateAppearance { $0.setComposerAreaBackgroundColor(newValue) } }
            ), supportsOpacity: false)

            ColorPicker("Text", selection: Binding(
                get: { appState.appearance.textColor(for: resolvedColorScheme) },
                set: { newValue in appState.updateAppearance { $0.setTextColor(newValue) } }
            ), supportsOpacity: false)

            ColorPicker("User message", selection: Binding(
                get: { appState.appearance.userMessageBackgroundColor },
                set: { newValue in appState.updateAppearance { $0.setUserMessageBackgroundColor(newValue) } }
            ), supportsOpacity: false)

            ColorPicker("User message text", selection: Binding(
                get: { appState.appearance.userMessageTextColor },
                set: { newValue in appState.updateAppearance { $0.setUserMessageTextColor(newValue) } }
            ), supportsOpacity: false)

            ColorPicker("Assistant message", selection: Binding(
                get: { appState.appearance.assistantMessageBackgroundColor(for: resolvedColorScheme) },
                set: { newValue in appState.updateAppearance { $0.setAssistantMessageBackgroundColor(newValue) } }
            ), supportsOpacity: false)

            ColorPicker("Assistant message text", selection: Binding(
                get: { appState.appearance.assistantMessageTextColor(for: resolvedColorScheme) },
                set: { newValue in appState.updateAppearance { $0.setAssistantMessageTextColor(newValue) } }
            ), supportsOpacity: false)

            HStack {
                Button("Copy colors") {
                    copyAppearanceToClipboard()
                }
                Button("Paste colors") {
                    pasteAppearanceFromClipboard()
                }
                Spacer()
            }

            if let appearanceClipboardStatus {
                Text(appearanceClipboardStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Reset custom colors") {
                appState.updateAppearance { $0.resetCustomColors() }
            }

            Toggle("Transparent titlebar", isOn: Binding(
                get: { appState.appearance.useTransparentTitlebar },
                set: { newValue in appState.updateAppearance { $0.useTransparentTitlebar = newValue } }
            ))

            TextField("Empty chat message", text: Binding(
                get: { appState.appearance.emptyChatMessage },
                set: { newValue in appState.updateAppearance { $0.emptyChatMessage = newValue } }
            ))
        }
    }

    private var piDefaultsSection: some View {
        Section("Pi defaults") {
            settingsValueRow(title: "Context window", value: appState.defaultContextWindowDisplayName, showsDisclosure: false)

            Button {
                showsDefaultModelPicker = true
                appState.refreshAvailableModelsCache()
            } label: {
                settingsValueRow(title: "Default model", value: appState.defaultModelDisplayName)
            }
            .buttonStyle(.plain)

            Button {
                showsDefaultThinkingPicker = true
            } label: {
                settingsValueRow(title: "Default thinking", value: appState.defaultThinkingDisplayName)
            }
            .buttonStyle(.plain)
            .disabled(appState.defaultModelPreference == nil)

            Button(appState.isLoadingAvailableModels ? "Loading models…" : "Refresh model list") {
                appState.refreshAvailableModelsCache(force: true)
            }
            .disabled(appState.isLoadingAvailableModels)

            Text("New sessions use this model explicitly. Existing sessions keep their current model.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var remoteAPISection: some View {
        Section("pi-appd") {
            TextField("http://100.100.20.10:8787", text: $appState.daemonURL)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()
            SecureField("Bearer token", text: $appState.daemonToken)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()

            Button("Test Connection") {
                Task { await appState.testConnection() }
            }
            Button("Reload Catalog") {
                Task { await appState.reloadCatalog() }
            }
        }
    }

    private func settingsValueRow(title: String, value: String, showsDisclosure: Bool = true) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(appState.appearance.textColor(for: resolvedColorScheme))
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }

    private func copyAppearanceToClipboard() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(MobileAppearanceColorTransfer(
                appState.appearance,
                resolvedColorScheme: appState.appearance.resolvedColorScheme(current: colorScheme)
            ))
            guard let text = String(data: data, encoding: .utf8) else {
                appearanceClipboardStatus = "Could not encode colors."
                return
            }
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            appearanceClipboardStatus = "Colors copied."
            #else
            appearanceClipboardStatus = "Clipboard is unavailable on this platform."
            #endif
        } catch {
            appearanceClipboardStatus = error.localizedDescription
        }
    }

    private func pasteAppearanceFromClipboard() {
        #if canImport(UIKit)
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let data = text.data(using: .utf8) else {
            appearanceClipboardStatus = "Clipboard is empty."
            return
        }
        do {
            let decoded = try JSONDecoder().decode(MobileAppearanceColorTransfer.self, from: data)
            applyPastedAppearance(decoded)
            appearanceClipboardStatus = "Colors pasted."
        } catch {
            appearanceClipboardStatus = "Could not paste colors: \(error.localizedDescription)"
        }
        #else
        appearanceClipboardStatus = "Clipboard is unavailable on this platform."
        #endif
    }

    private func applyPastedAppearance(_ transfer: MobileAppearanceColorTransfer) {
        appState.updateAppearance { transfer.apply(to: &$0) }
        // Some visible ColorPickers can briefly write their stale binding value
        // back during the same Form update. Re-apply on the next ticks so the
        // pasted accent/user-message colors win reliably on iPhone.
        DispatchQueue.main.async {
            appState.updateAppearance { transfer.apply(to: &$0) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            appState.updateAppearance { transfer.apply(to: &$0) }
        }
    }
}

private struct MobileAppearanceColorTransfer: Codable {
    var accentColorValue: MobileCodableAccentColor?
    var mainBackgroundColorValue: MobileCodableAccentColor?
    var topBarBackgroundColorValue: MobileCodableAccentColor?
    var sidebarBackgroundColorValue: MobileCodableAccentColor?
    var composerAreaBackgroundColorValue: MobileCodableAccentColor?
    var textColorValue: MobileCodableAccentColor?
    var userMessageBackgroundColorValue: MobileCodableAccentColor?
    var userMessageTextColorValue: MobileCodableAccentColor?
    var assistantMessageBackgroundColorValue: MobileCodableAccentColor?
    var assistantMessageTextColorValue: MobileCodableAccentColor?
    var colorScheme: MobileAppColorSchemePreference?

    init(_ appearance: MobileAppAppearance, resolvedColorScheme: ColorScheme) {
        // Store concrete resolved colors, not only user-overridden optionals.
        // This makes the clipboard payload portable between Mac/iPhone and
        // preserves the exact visible theme even when some values were defaults.
        accentColorValue = appearance.accentColorValue
        mainBackgroundColorValue = MobileCodableAccentColor(appearance.mainBackgroundColor(for: resolvedColorScheme))
        topBarBackgroundColorValue = MobileCodableAccentColor(appearance.topBarBackgroundColor(for: resolvedColorScheme))
        sidebarBackgroundColorValue = MobileCodableAccentColor(appearance.sidebarBackgroundColor(for: resolvedColorScheme))
        composerAreaBackgroundColorValue = MobileCodableAccentColor(appearance.composerAreaBackgroundColor(for: resolvedColorScheme))
        textColorValue = MobileCodableAccentColor(appearance.textColor(for: resolvedColorScheme))
        userMessageBackgroundColorValue = MobileCodableAccentColor(appearance.userMessageBackgroundColor)
        userMessageTextColorValue = MobileCodableAccentColor(appearance.userMessageTextColor)
        assistantMessageBackgroundColorValue = MobileCodableAccentColor(appearance.assistantMessageBackgroundColor(for: resolvedColorScheme))
        assistantMessageTextColorValue = MobileCodableAccentColor(appearance.assistantMessageTextColor(for: resolvedColorScheme))
        colorScheme = appearance.colorScheme
    }

    func apply(to appearance: inout MobileAppAppearance) {
        // Be tolerant of older/partial clipboard payloads: missing fields leave
        // current settings untouched instead of resetting them to defaults.
        if let accentColorValue { appearance.accentColorValue = accentColorValue }
        if let mainBackgroundColorValue { appearance.mainBackgroundColorValue = mainBackgroundColorValue }
        if let topBarBackgroundColorValue { appearance.topBarBackgroundColorValue = topBarBackgroundColorValue }
        if let sidebarBackgroundColorValue { appearance.sidebarBackgroundColorValue = sidebarBackgroundColorValue }
        if let composerAreaBackgroundColorValue { appearance.composerAreaBackgroundColorValue = composerAreaBackgroundColorValue }
        if let textColorValue { appearance.textColorValue = textColorValue }
        if let userMessageBackgroundColorValue {
            appearance.userMessageBackgroundColorValue = userMessageBackgroundColorValue
        } else if let accentColorValue {
            appearance.userMessageBackgroundColorValue = accentColorValue
        }
        if let userMessageTextColorValue {
            appearance.userMessageTextColorValue = userMessageTextColorValue
        } else if let accentColorValue {
            appearance.userMessageTextColorValue = accentColorValue.readableForegroundColorValue
        }
        if let assistantMessageBackgroundColorValue { appearance.assistantMessageBackgroundColorValue = assistantMessageBackgroundColorValue }
        if let assistantMessageTextColorValue { appearance.assistantMessageTextColorValue = assistantMessageTextColorValue }
        if let colorScheme { appearance.colorScheme = colorScheme }
    }
}

private struct MobileRuntimePill: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    let systemName: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(MobileTheme.controlTint(for: resolvedColorScheme, opacity: 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }
}

private struct MobileSubagentsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: MobilePiAppState
    @State private var selectedSubagentID: SubagentSession.ID?

    private var subagents: [SubagentSession] {
        SubagentSession.extract(from: appState.selectedEvents)
    }

    private var selectedSubagent: SubagentSession? {
        guard let selectedSubagentID else { return nil }
        return subagents.first { $0.id == selectedSubagentID }
    }

    var body: some View {
        Group {
            if let selectedSubagent {
                MobileSubagentDetailView(subagent: selectedSubagent) {
                    self.selectedSubagentID = nil
                }
            } else if subagents.isEmpty {
                ContentUnavailableView(
                    "No subagents yet",
                    systemImage: "person.2.slash",
                    description: Text("Subagent runs for this session will appear here.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(subagents) { subagent in
                            Button {
                                selectedSubagentID = subagent.id
                            } label: {
                                MobileSubagentRow(subagent: subagent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Subagents")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .mobileBackSwipe {
            if selectedSubagentID != nil {
                selectedSubagentID = nil
            } else {
                dismiss()
            }
        }
        .onChange(of: subagents.map(\.id)) { _, ids in
            guard let selectedSubagentID, !ids.contains(selectedSubagentID) else { return }
            self.selectedSubagentID = nil
        }
    }
}

private struct MobileSubagentRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    let subagent: SubagentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: subagent.isError ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.checkmark")
                    .foregroundStyle(subagent.isError ? .red : appState.appearance.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(subagent.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(subagent.displayModel)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(subagent.displayStatus)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(subagent.isError ? .red : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(MobileTheme.controlTint(for: resolvedColorScheme, opacity: subagent.isError ? 0.10 : 0.06))
                    .clipShape(Capsule())
            }

            Text(subagent.taskPreview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let cwd = subagent.cwd?.nilIfBlank {
                Label(cwd, systemImage: "folder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MobileTheme.controlTint(for: resolvedColorScheme, opacity: 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }
}

private struct MobileSubagentDetailView: View {
    let subagent: SubagentSession
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(subagent.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(subagent.displayModel)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.18)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let cwd = subagent.cwd?.nilIfBlank {
                            Label(cwd, systemImage: "folder")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        ForEach(rows) { row in
                            MobileEventRow(row: row)
                                .id(row.id)
                        }
                    }
                    .padding()
                }
                .onAppear { scrollToBottom(proxy: proxy, animated: false) }
                .onChange(of: scrollSignature) { _, _ in
                    scrollToBottom(proxy: proxy, animated: true)
                }
            }
        }
    }

    private var rows: [MobileDisplayedRow] {
        MobileDisplayedRow.groupingToolResults(in: subagent.events.filter(\.isVisibleInTranscript))
    }

    private var scrollSignature: String {
        rows.map(\.scrollFingerprint).joined(separator: "|")
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard let id = rows.last?.id else { return }
        let action = { proxy.scrollTo(id, anchor: .bottom) }
        if animated {
            withAnimation(.snappy) { action() }
        } else {
            action()
        }
    }
}

private struct MobileModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: MobilePiAppState

    var body: some View {
        MobileModelList(
            models: appState.selectableAvailableModels,
            selectedID: appState.selectedModelID,
            emptyMessage: appState.isLoadingAvailableModels ? "Loading models…" : "No pi models loaded.",
            includesDaemonDefault: false,
            onSelectDefault: nil,
            onSelectModel: { model in
                Task {
                    await appState.setSelectedModel(model)
                    dismiss()
                }
            }
        )
        .navigationTitle("Model")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear { appState.refreshAvailableModelsCache() }
    }
}

private struct MobileDefaultModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: MobilePiAppState

    var body: some View {
        MobileModelList(
            models: appState.cachedSelectableAvailableModels,
            selectedID: appState.defaultModelPreference?.id,
            emptyMessage: appState.isLoadingAvailableModels ? "Loading models…" : "No cached models yet. Refresh once to populate the picker.",
            includesDaemonDefault: true,
            onSelectDefault: {
                appState.setDefaultModel(nil)
                dismiss()
            },
            onSelectModel: { model in
                appState.setDefaultModel(model)
                dismiss()
            }
        )
        .navigationTitle("Default model")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear { appState.refreshAvailableModelsCache() }
    }
}

private struct MobileThinkingPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: MobilePiAppState

    var body: some View {
        MobileChoiceList(
            title: "Thinking",
            choices: appState.selectedThinkingLevels,
            selected: appState.selectedThinkingLevel,
            includesDefault: false,
            onSelect: { level in
                Task {
                    await appState.setSelectedThinkingLevel(level)
                    dismiss()
                }
            },
            onSelectDefault: nil
        )
    }
}

private struct MobileDefaultThinkingPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: MobilePiAppState

    var body: some View {
        MobileChoiceList(
            title: "Default thinking",
            choices: appState.defaultThinkingLevels,
            selected: appState.defaultModelPreference?.thinkingLevel,
            includesDefault: true,
            onSelect: { level in
                appState.setDefaultThinkingLevel(level)
                dismiss()
            },
            onSelectDefault: {
                appState.setDefaultThinkingLevel(nil)
                dismiss()
            }
        )
    }
}

private struct MobileModelList: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    let models: [PiModelOption]
    let selectedID: String?
    let emptyMessage: String
    let includesDaemonDefault: Bool
    let onSelectDefault: (() -> Void)?
    let onSelectModel: (PiModelOption) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if includesDaemonDefault, let onSelectDefault {
                    MobileSelectionRow(
                        title: "Use daemon default",
                        subtitle: nil,
                        isSelected: selectedID == nil,
                        action: onSelectDefault
                    )
                }

                if models.isEmpty {
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    ForEach(groupedModels) { group in
                        Text(group.provider)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        ForEach(group.models) { model in
                            MobileSelectionRow(
                                title: model.shortLabel,
                                subtitle: model.provider,
                                isSelected: selectedID == model.id,
                                action: { onSelectModel(model) }
                            )
                        }
                    }
                }

                Button(appState.isLoadingAvailableModels ? "Loading models…" : "Refresh model list") {
                    appState.refreshAvailableModelsCache(force: true)
                }
                .disabled(appState.isLoadingAvailableModels)
                .buttonStyle(.bordered)
                .padding(.top, 8)
            }
            .padding()
        }
        .background(appState.appearance.mainBackgroundColor(for: resolvedColorScheme).ignoresSafeArea())
    }

    private var groupedModels: [MobileModelGroup] {
        Dictionary(grouping: models, by: \.provider)
            .map { provider, models in
                MobileModelGroup(
                    provider: provider,
                    models: models.sorted { $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending }
                )
            }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }
}

private struct MobileChoiceList: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: MobilePiAppState
    let title: String
    let choices: [String]
    let selected: String?
    let includesDefault: Bool
    let onSelect: (String) -> Void
    let onSelectDefault: (() -> Void)?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if includesDefault, let onSelectDefault {
                    MobileSelectionRow(
                        title: "Use daemon default",
                        subtitle: nil,
                        isSelected: selected?.nilIfBlank == nil,
                        action: onSelectDefault
                    )
                }

                ForEach(choices, id: \.self) { choice in
                    MobileSelectionRow(
                        title: choice,
                        subtitle: nil,
                        isSelected: selected == choice,
                        action: { onSelect(choice) }
                    )
                }
            }
            .padding()
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .background(appState.appearance.mainBackgroundColor(for: resolvedColorScheme).ignoresSafeArea())
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }
}

private struct MobileSelectionRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(appState.appearance.textColor(for: resolvedColorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(appState.appearance.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(MobileTheme.controlTint(for: resolvedColorScheme, opacity: isSelected ? 0.14 : 0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }
}

private struct MobileSearchField: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search sessions", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = false
                    dismissKeyboard()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(MobileTheme.controlTint(for: resolvedColorScheme, opacity: 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }

    private func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

private struct MobileIconButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: MobilePiAppState
    let systemName: String
    var help: String = ""
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(appState.appearance.accentColor.opacity(isDisabled ? 0.28 : 1))
                .frame(width: 34, height: 34)
                .background(MobileTheme.controlTint(for: resolvedColorScheme, opacity: 0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
    }

    private var resolvedColorScheme: ColorScheme {
        appState.appearance.resolvedColorScheme(current: colorScheme)
    }
}

private enum ParsedMobileSlashCommand: Equatable {
    case abort
    case compact(instructions: String)
}

private func mobileSlashCommandQuery(in text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else { return nil }
    let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rest.isEmpty else { return "" }
    let commandPart = rest.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
    return commandPart.lowercased()
}

private func parseMobileSlashCommand(_ text: String) -> ParsedMobileSlashCommand? {
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

private struct MobileSlashCommand: Identifiable, Hashable {
    let name: String
    let description: String

    var id: String { name }
}

private struct MobileComposerIconButton: View {
    @EnvironmentObject private var appState: MobilePiAppState
    let systemName: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(appState.appearance.accentColor.opacity(isDisabled ? 0.28 : 1))
                .frame(width: 22, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

private struct MobileBlobModifier: ViewModifier {
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(MobileTheme.controlTint(for: colorScheme, opacity: 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private extension View {
    func mobileBlobStyle(colorScheme: ColorScheme) -> some View {
        modifier(MobileBlobModifier(colorScheme: colorScheme))
    }

    func mobileBackSwipe(edgeWidth: CGFloat = 44, action: @escaping () -> Void) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .local)
                .onEnded { value in
                    guard value.startLocation.x <= edgeWidth,
                          value.translation.width > 72,
                          abs(value.translation.height) < 80,
                          value.predictedEndTranslation.width > 96 else { return }
                    action()
                }
        )
    }

    @ViewBuilder
    func hiddenMobileNavigationBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    @ViewBuilder
    func mobileScrollKeepsKeyboardVisible() -> some View {
        #if os(iOS)
        scrollDismissesKeyboard(.never)
        #else
        self
        #endif
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum MobileTheme {
    static let accentColor = Color.yellow

    static func mainBackgroundColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.055, green: 0.058, blue: 0.065) : Color(red: 0.965, green: 0.965, blue: 0.955)
    }

    static func sidebarBackgroundColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.078, green: 0.082, blue: 0.092) : Color(red: 0.91, green: 0.91, blue: 0.895)
    }

    static func composerAreaBackgroundColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.074, green: 0.078, blue: 0.088) : Color(red: 0.93, green: 0.93, blue: 0.92)
    }

    static func textColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : .black
    }

    static func assistantMessageBackgroundColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
    }

    static func controlTint(for colorScheme: ColorScheme, opacity: Double) -> Color {
        (colorScheme == .dark ? Color.white : Color.black).opacity(opacity)
    }
}
