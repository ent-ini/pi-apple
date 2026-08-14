import AppKit
import SwiftUI
import ApplePiCore
import ApplePiRemote

enum ChatWindowPresentation {
    case standard
    case floatingOverlay
}

struct ContentView: View {
    let presentation: ChatWindowPresentation

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState
    @AppStorage("ApplePi.showsSessionList") private var wantsStandardSessionList = true
    @AppStorage("ApplePi.showsSessionOverlay") private var wantsOverlaySessionList = false
    @AppStorage("ApplePi.sessionListWidth") private var storedSessionListWidth = PaneLayout.sessionListDefault
    @AppStorage("ApplePi.showsUtilitySidebar") private var wantsUtilitySidebar = false
    @AppStorage("ApplePi.utilitySidebarWidth") private var storedUtilitySidebarWidth = PaneLayout.utilitySidebarDefault
    @State private var liveSessionListWidth: Double?
    @State private var liveUtilitySidebarWidth: Double?
    @State private var activeResize: ActivePaneResize?

    var body: some View {
        GeometryReader { proxy in
            let sessionListWidth = liveSessionListWidth ?? storedSessionListWidth
            let utilitySidebarWidth = liveUtilitySidebarWidth ?? storedUtilitySidebarWidth
            let paneVisibility = AdaptivePaneVisibility(
                windowWidth: proxy.size.width,
                presentation: presentation,
                wantsSessionList: wantsSessionList,
                wantsUtilitySidebar: wantsUtilitySidebar
            )

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if paneVisibility.showsStandardSessionList {
                        sessionListPanel(width: sessionListWidth, topInset: proxy.safeAreaInsets.top)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }

                    DetailView()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)

                    if paneVisibility.showsUtilitySidebar {
                        PaneResizeHandle(
                            topInset: proxy.safeAreaInsets.top,
                            onDragStart: {
                                activeResize = ActivePaneResize(kind: .utilitySidebar, startingWidth: utilitySidebarWidth)
                            },
                            onDrag: { translation in
                                let startWidth = activeResize?.startingWidth ?? utilitySidebarWidth
                                let nextWidth = PaneLayout.clampedUtilitySidebarWidth(startWidth - translation)
                                withTransaction(Transaction(animation: nil)) {
                                    liveUtilitySidebarWidth = Double(nextWidth)
                                }
                            },
                            onDragEnd: {
                                let finalWidth = liveUtilitySidebarWidth ?? utilitySidebarWidth
                                storedUtilitySidebarWidth = finalWidth
                                activeResize = nil
                                if finalWidth <= PaneLayout.utilitySidebarCollapseThreshold {
                                    withAnimation(.snappy(duration: 0.18)) {
                                        wantsUtilitySidebar = false
                                    }
                                }
                            }
                        )
                        UtilitySidebarView()
                            .frame(width: PaneLayout.clampedUtilitySidebarWidth(utilitySidebarWidth))
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }

                if presentation == .floatingOverlay && wantsSessionList {
                    HStack(spacing: 0) {
                        sessionListPanel(width: sessionListWidth, topInset: proxy.safeAreaInsets.top)
                        Spacer(minLength: 0)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(1)
                }
            }
            .animation(.snappy(duration: 0.18), value: paneVisibility)
            .animation(.snappy(duration: 0.18), value: wantsSessionList)
        }
        .foregroundStyle(appState.appearance.textColor(for: appState.appearance.resolvedColorScheme(current: colorScheme)))
        .background(AppBackdrop(appearance: appState.appearance))
        .onAppear {
            liveSessionListWidth = storedSessionListWidth
            liveUtilitySidebarWidth = storedUtilitySidebarWidth
        }
        .onChange(of: storedSessionListWidth) { _, newValue in
            guard activeResize?.kind != .sessionList else { return }
            liveSessionListWidth = newValue
        }
        .onChange(of: storedUtilitySidebarWidth) { _, newValue in
            guard activeResize?.kind != .utilitySidebar else { return }
            liveUtilitySidebarWidth = newValue
        }
        .onChange(of: appState.sessionSearchFocusRequestID) { _, _ in
            revealSessionListForSearch()
        }
        .overlay(alignment: .topLeading) {
            WindowAppearanceConfigurator(appearance: appState.appearance)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            if let update = appState.availableUpdate {
                UpdatePillView(update: update) {
                    appState.dismissAvailableUpdate()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: appState.availableUpdate)
        .preferredColorScheme(appState.appearance.colorScheme.colorScheme)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    toggleSessionList()
                } label: {
                    Label("Sessions", systemImage: "sidebar.right")
                }
                .help(wantsSessionList ? "Hide sessions" : "Show sessions")

                Button {
                    toggleUtilitySidebar()
                } label: {
                    Label("Utility Panel", systemImage: "sidebar.trailing")
                }
                .help(wantsUtilitySidebar ? "Hide utility panel" : "Show utility panel")

            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    appState.openNewSessionInCurrentFolder()
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(appState.appearance.accentColor)
                }
                .help("New session")

                Menu {
                    Button("Refresh Sessions") {
                        appState.refreshCatalog()
                    }
                    Divider()
                    SettingsLink {
                        Label("App Settings", systemImage: "gearshape")
                    }
                    Divider()
                    Button("Open Agent Settings JSON") {
                        appState.openGlobalSettings()
                    }
                    .disabled(!appState.pathExists(appState.configurationSummary.globalSettingsPath))
                    Button("Reveal Agent Folder") {
                        appState.revealAgentDirectory()
                    }
                    .disabled(!appState.pathExists(appState.configurationSummary.agentDirectoryPath))
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .help("More actions")
            }
        }
        .tint(appState.appearance.accentColor)
        .sheet(isPresented: $appState.showsNewSessionSheet) {
            NewSessionSheet()
                .environmentObject(appState)
        }
    }

    private var wantsSessionList: Bool {
        get {
            switch presentation {
            case .standard: wantsStandardSessionList
            case .floatingOverlay: wantsOverlaySessionList
            }
        }
        nonmutating set {
            switch presentation {
            case .standard: wantsStandardSessionList = newValue
            case .floatingOverlay: wantsOverlaySessionList = newValue
            }
        }
    }

    @ViewBuilder
    private func sessionListPanel(width: Double, topInset: CGFloat) -> some View {
        SessionListView()
            .frame(width: PaneLayout.clampedSessionListWidth(width))
        PaneResizeHandle(
            topInset: topInset,
            onDragStart: {
                activeResize = ActivePaneResize(kind: .sessionList, startingWidth: width)
            },
            onDrag: { translation in
                let startWidth = activeResize?.startingWidth ?? width
                let nextWidth = PaneLayout.clampedSessionListWidth(startWidth + translation)
                withTransaction(Transaction(animation: nil)) {
                    liveSessionListWidth = Double(nextWidth)
                }
            },
            onDragEnd: {
                let finalWidth = liveSessionListWidth ?? width
                storedSessionListWidth = finalWidth
                activeResize = nil
                if finalWidth <= PaneLayout.sessionListCollapseThreshold {
                    withAnimation(.snappy(duration: 0.18)) {
                        wantsSessionList = false
                    }
                }
            }
        )
    }

    private func toggleSessionList() {
        if !wantsSessionList && storedSessionListWidth <= PaneLayout.sessionListCollapseThreshold {
            storedSessionListWidth = PaneLayout.sessionListReopenWidth
            liveSessionListWidth = PaneLayout.sessionListReopenWidth
        }
        withAnimation(.snappy(duration: 0.18)) {
            wantsSessionList.toggle()
        }
    }

    private func toggleUtilitySidebar() {
        if !wantsUtilitySidebar && storedUtilitySidebarWidth <= PaneLayout.utilitySidebarCollapseThreshold {
            storedUtilitySidebarWidth = PaneLayout.utilitySidebarReopenWidth
            liveUtilitySidebarWidth = PaneLayout.utilitySidebarReopenWidth
        }
        withAnimation(.snappy(duration: 0.18)) {
            wantsUtilitySidebar.toggle()
        }
    }

    private func revealSessionListForSearch() {
        if storedSessionListWidth <= PaneLayout.sessionListCollapseThreshold {
            storedSessionListWidth = PaneLayout.sessionListReopenWidth
            liveSessionListWidth = PaneLayout.sessionListReopenWidth
        }
        guard !wantsSessionList else { return }
        withAnimation(.snappy(duration: 0.18)) {
            wantsSessionList = true
        }
    }
}

private enum PaneLayout {
    static let resizeHandleWidth: CGFloat = 1
    static let resizeHandleHitWidth: CGFloat = 14
    static let sessionListMinimum: Double = 88
    static let sessionListDefault: Double = 330
    static let sessionListMaximum: Double = 480
    static let sessionListCollapseThreshold: Double = 104
    static let sessionListReopenWidth: Double = 176
    static let utilitySidebarMinimum: Double = 220
    static let utilitySidebarDefault: Double = 320
    static let utilitySidebarMaximum: Double = 520
    static let utilitySidebarCollapseThreshold: Double = 232
    static let utilitySidebarReopenWidth: Double = 300

    static func clampedSessionListWidth(_ width: Double) -> CGFloat {
        CGFloat(min(max(width, sessionListMinimum), sessionListMaximum))
    }

    static func clampedUtilitySidebarWidth(_ width: Double) -> CGFloat {
        CGFloat(min(max(width, utilitySidebarMinimum), utilitySidebarMaximum))
    }
}

private struct ActivePaneResize {
    enum Kind {
        case sessionList
        case utilitySidebar
    }

    let kind: Kind
    let startingWidth: Double
}

private struct PaneResizeHandle: View {
    @Environment(\.colorScheme) private var colorScheme
    let topInset: CGFloat
    let onDragStart: () -> Void
    let onDrag: (Double) -> Void
    let onDragEnd: () -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        let hitOutset = max(0, (PaneLayout.resizeHandleHitWidth - PaneLayout.resizeHandleWidth) / 2)

        Rectangle()
            .fill(controlTint(for: colorScheme, opacity: isDragging ? 0.24 : (isHovering ? 0.16 : 0.06)))
            .frame(
                minWidth: PaneLayout.resizeHandleWidth,
                idealWidth: PaneLayout.resizeHandleWidth,
                maxWidth: PaneLayout.resizeHandleWidth,
                maxHeight: .infinity
            )
            .padding(.top, topInset)
            .padding(.horizontal, hitOutset)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onDragStart()
                        }
                        onDrag(value.translation.width)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onDragEnd()
                    }
            )
        .onHover { hovering in
            guard hovering != isHovering else { return }
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHovering {
                NSCursor.pop()
            }
        }
        .padding(.horizontal, -hitOutset)
        .accessibilityLabel("Resize pane")
        .accessibilityHint("Drag horizontally to resize this column")
    }
}

private struct AdaptivePaneVisibility: Equatable {
    let showsStandardSessionList: Bool
    let showsUtilitySidebar: Bool

    init(
        windowWidth: CGFloat,
        presentation: ChatWindowPresentation,
        wantsSessionList: Bool,
        wantsUtilitySidebar: Bool
    ) {
        let minimumDetailWidth: CGFloat = 320
        let minimumSessionWidth = CGFloat(PaneLayout.sessionListMinimum)
        let minimumUtilityWidth = CGFloat(PaneLayout.utilitySidebarMinimum)
        let resizeHandleWidth = PaneLayout.resizeHandleWidth
        showsStandardSessionList = presentation == .standard
            && wantsSessionList
            && windowWidth >= minimumDetailWidth + minimumSessionWidth + resizeHandleWidth
        let sessionWidth = showsStandardSessionList ? minimumSessionWidth + resizeHandleWidth : 0
        showsUtilitySidebar = wantsUtilitySidebar
            && windowWidth >= minimumDetailWidth + sessionWidth + minimumUtilityWidth + resizeHandleWidth
    }
}

private struct AppBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    let appearance: AppAppearance

    var body: some View {
        GeometryReader { proxy in
            let resolvedColorScheme = appearance.resolvedColorScheme(current: colorScheme)
            let topBarHeight = appearance.useTransparentTitlebar ? proxy.safeAreaInsets.top : 0

            VStack(spacing: 0) {
                if topBarHeight > 0 {
                    Rectangle()
                        .fill(appearance.topBarBackgroundColor(for: resolvedColorScheme))
                        .frame(height: topBarHeight)
                }

                Rectangle()
                    .fill(appearance.mainBackgroundColor(for: resolvedColorScheme))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea()
    }
}

struct ProjectSidebarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(appState.filteredProjects) { project in
                        ProjectRow(
                            project: project,
                            isSelected: appState.activeProject?.id == project.id && appState.selectedSession == nil,
                            onSelect: { appState.select(.project(project.id)) }
                        )
                    }
                }
                .padding(.vertical, 10)
            }
            .overlay {
                if appState.isLoadingCatalog {
                    ProgressView()
                        .controlSize(.small)
                } else if appState.projects.isEmpty {
                    EmptyCatalogView(
                        title: "No Sessions",
                        systemImage: "folder",
                        message: appState.statusMessage,
                        action: { appState.refreshCatalog() }
                    )
                    .padding()
                }
            }
            Divider().opacity(0.35)
            PiContextFooter(summary: appState.configurationSummary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .background(appState.appearance.sidebarBackgroundColor(for: appState.appearance.resolvedColorScheme(current: colorScheme)))
    }
}

private struct ProjectRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState
    let project: PiProject
    let isSelected: Bool
    let onSelect: () -> Void

    private var projectSettingsPath: String? {
        project.workingDirectory.map { "\($0)/.pi/settings.json" }
    }

    private var agentsPath: String? {
        project.workingDirectory.flatMap { directory in
            ["\(directory)/AGENTS.md", "\(directory)/.pi/AGENTS.md"]
                .first(where: { appState.pathExists($0) })
        }
    }

    private var piDirectoryPath: String? {
        project.workingDirectory.map { "\($0)/.pi" }
    }

    private var hasProjectDirectory: Bool {
        appState.pathExists(project.workingDirectory)
    }

    var body: some View {
        row
            .contextMenu {
                Button("New Session") {
                    appState.openNewSession(in: project.workingDirectory)
                }
                Divider()
                Button("Show in Finder") {
                    appState.revealProjectDirectory(for: project)
                }
                .disabled(!hasProjectDirectory)

                projectFileActions
            }
    }

    @ViewBuilder
    private var projectFileActions: some View {
        if appState.pathExists(projectSettingsPath) || appState.pathExists(agentsPath) || appState.pathExists(piDirectoryPath) {
            Divider()
        }

        if appState.pathExists(projectSettingsPath) {
            Button("Open Project Settings JSON") {
                appState.openProjectSettings(for: project)
            }
        }

        if appState.pathExists(agentsPath) {
            Button("Open AGENTS.md") {
                appState.openAgentsFile(for: project)
            }
        }

        if appState.pathExists(piDirectoryPath) {
            Button("Reveal .pi Folder") {
                appState.revealProjectPiDirectory(for: project)
            }
        }
    }

    private var row: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(appState.appearance.accentColor)
                    .frame(width: 22)
                Text(project.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(project.sessionCount)")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? controlTint(for: colorScheme, opacity: 0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }
}

private struct PiContextFooter: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState
    let summary: PiConfigurationSummary
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text("Pi")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(summary.trustDisplayTitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                showsDetails.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Show Pi configuration")
            .popover(isPresented: $showsDetails, arrowEdge: .trailing) {
                PiContextPopover(summary: summary)
                    .environmentObject(appState)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(controlTint(for: colorScheme, opacity: 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var statusColor: Color {
        switch summary.trustStatus {
        case .trusted: .green
        case .untrusted: .orange
        case .unknown: summary.hasProjectContext ? .secondary : .secondary.opacity(0.55)
        }
    }
}

private struct PiContextPopover: View {
    @EnvironmentObject private var appState: PiAppState
    let summary: PiConfigurationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pi")
                        .font(.headline.weight(.semibold))
                    Text(summary.trustDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    appState.refreshConfigurationSummary()
                    appState.refreshCatalog()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh Pi context")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { metrics }
                VStack(alignment: .leading, spacing: 5) { metrics }
            }

            VStack(alignment: .leading, spacing: 8) {
                PiContextPathRow(title: "Session storage", path: summary.sessionRoot)
                if let projectDirectory = summary.projectDirectory {
                    PiContextPathRow(title: "Project", path: projectDirectory)
                }
                PiContextPathRow(title: "Agent", path: summary.agentDirectoryPath)
            }

            Divider()

            HStack {
                Button("Open Settings JSON") {
                    appState.openGlobalSettings()
                }
                .disabled(!appState.pathExists(summary.globalSettingsPath))

                Button("Reveal Agent") {
                    appState.revealAgentDirectory()
                }
                .disabled(!appState.pathExists(summary.agentDirectoryPath))
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    @ViewBuilder
    private var metrics: some View {
        PiContextMetric(title: "Config", value: summary.settingsCount) {
            appState.openConfigurationMetric(.config)
        }
        .help("Open Pi settings JSON")

        PiContextMetric(title: "Instructions", value: summary.contextFileCount) {
            appState.openConfigurationMetric(.instructions)
        }
        .help("Open Pi instruction file")

        PiContextMetric(title: "Resources", value: summary.resourceCount) {
            appState.openConfigurationMetric(.resources)
        }
        .help("Reveal Pi resources")
    }
}

private struct PiContextPathRow: View {
    let title: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
        }
    }
}

private struct PiContextMetric: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("\(value)")
                    .monospacedDigit()
                    .font(.caption.weight(.bold))
                Text(title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(controlTint(for: colorScheme, opacity: 0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .disabled(value == 0)
        .opacity(value == 0 ? 0.55 : 1)
    }
}

struct SessionListView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState
    @FocusState private var isSearchFieldFocused: Bool
    @State private var renameTarget: PiSessionSummary?
    @State private var renameDraftTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search sessions", text: $appState.sessionSearchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFieldFocused)
                if appState.hasActiveSessionSearch {
                    Button {
                        appState.sessionSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(controlTint(for: colorScheme, opacity: 0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider().opacity(0.24)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(appState.filteredSessions()) { session in
                        SessionListRow(
                            session: session,
                            isSelected: appState.isSelectedSession(session),
                            onSelect: {
                                appState.select(.session(session.id))
                            },
                            onRename: { session in
                                renameTarget = session
                                renameDraftTitle = session.title
                            }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .overlay {
                if !appState.isLoadingCatalog,
                   appState.filteredSessions().isEmpty {
                    EmptyCatalogView(
                        title: appState.hasActiveSessionSearch ? "No Matches" : "No Sessions",
                        systemImage: appState.hasActiveSessionSearch ? "magnifyingglass" : "text.bubble",
                        message: appState.hasActiveSessionSearch ? appState.sessionSearchText : appState.statusMessage,
                        action: {
                            if appState.hasActiveSessionSearch {
                                appState.sessionSearchText = ""
                            } else {
                                appState.refreshCatalog()
                            }
                        }
                    )
                    .padding()
                }
            }
            .scrollContentBackground(.hidden)
        }
        .background(appState.appearance.sidebarBackgroundColor(for: appState.appearance.resolvedColorScheme(current: colorScheme)))
        .alert("Rename Session", isPresented: renameAlertBinding) {
            TextField("Name", text: $renameDraftTitle)
            Button("Rename") {
                guard let renameTarget else { return }
                appState.rename(renameTarget, to: renameDraftTitle)
                self.renameTarget = nil
            }
            Button("Cancel", role: .cancel) {
                renameTarget = nil
            }
        }
        .onAppear {
            applyPendingSearchFocus()
        }
        .onChange(of: appState.sessionSearchFocusRequestID) { _, _ in
            applyPendingSearchFocus()
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { isPresented in
                if !isPresented {
                    renameTarget = nil
                }
            }
        )
    }

    private func applyPendingSearchFocus() {
        guard appState.pendingSessionSearchFocusRequest else { return }
        DispatchQueue.main.async {
            isSearchFieldFocused = true
            appState.consumeSessionSearchFocusRequest()
        }
    }
}

struct UtilitySidebarView: View {
    @EnvironmentObject private var appState: PiAppState

    var body: some View {
        UtilitySidebarSessionContent(workspace: appState.chatWorkspace)
    }
}

private struct UtilitySidebarSessionContent: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState
    @ObservedObject var workspace: ChatSessionStore

    var body: some View {
        VStack(spacing: 0) {
            UtilitySidebarHeader(
                title: "Subagents",
                subtitle: "Current session",
                systemImage: "person.2.wave.2"
            )

            Divider().opacity(0.24)

            if let session = workspace.selectedTab ?? workspace.tabs.first {
                UtilitySubagentsPanel(session: session)
            } else {
                UtilityEmptyState(
                    icon: "bubble.left.and.bubble.right",
                    title: "No active session",
                    message: "Open a chat to inspect its subagent runs."
                )
            }
        }
        .background(appState.appearance.sidebarBackgroundColor(for: appState.appearance.resolvedColorScheme(current: colorScheme)))
    }
}

private struct UtilitySubagentsPanel: View {
    @EnvironmentObject private var appState: PiAppState
    @ObservedObject var session: ChatSession
    @State private var subagents: [SubagentSession] = []
    @State private var selectedSubagentID: SubagentSession.ID?
    @State private var selectedSubagentDetail: SubagentSession?
    @State private var isLoadingSubagents = true
    @State private var isLoadingDetail = false
    @State private var recentSessionEvents: [SessionEvent] = []
    @State private var recentSessionEventsRevision = 0

    private var mergedSessionEvents: [SessionEvent] {
        guard !recentSessionEvents.isEmpty else { return session.events }
        // Prefer live ChatSession rows so active tool results and deltas
        // replace the recent server snapshot.
        var seenIDs = Set(session.events.map(\.id))
        return session.events + recentSessionEvents.filter { seenIDs.insert($0.id).inserted }
    }

    private var extractionRevision: String {
        "\(session.id.uuidString):\(session.streamRevision):\(session.historyRevision):\(recentSessionEventsRevision)"
    }

    var body: some View {
        panelContent
        .task(id: session.sessionID ?? session.sessionPath ?? session.id.uuidString) {
            await loadRecentSessionEvents()
        }
        .task(id: extractionRevision) {
            await refreshSubagents()
        }
        .onChange(of: session.id) { _, _ in
            subagents = []
            selectedSubagentID = nil
            selectedSubagentDetail = nil
            isLoadingSubagents = true
            isLoadingDetail = false
            recentSessionEvents = []
            recentSessionEventsRevision = 0
        }
        .onChange(of: subagents.map(\.id)) { _, ids in
            guard let selectedSubagentID, !ids.contains(selectedSubagentID) else { return }
            self.selectedSubagentID = nil
            selectedSubagentDetail = nil
            isLoadingDetail = false
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        if isLoadingSubagents {
            ProgressView("Loading subagents…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoadingDetail {
            ProgressView("Loading transcript…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let selectedSubagentDetail {
            SubagentDetailView(subagent: selectedSubagentDetail) {
                withAnimation(.snappy(duration: 0.16)) {
                    selectedSubagentID = nil
                    self.selectedSubagentDetail = nil
                }
            }
        } else if subagents.isEmpty {
            UtilityEmptyState(
                icon: "person.2.slash",
                title: "No subagents yet",
                message: "When this session uses the subagent tool, spawned agents will appear here."
            )
        } else {
            SubagentListView(subagents: subagents) { subagent in
                loadDetail(for: subagent)
            }
        }
    }

    @MainActor
    private func loadRecentSessionEvents() async {
        guard let sessionID = session.sessionID?.nilIfBlank else {
            recentSessionEvents = []
            recentSessionEventsRevision &+= 1
            return
        }
        let host = appState.host
        let sessionObjectID = session.id
        do {
            // A bounded page keeps opening this sidebar predictable even for
            // multi-megabyte sessions. The live transcript is merged above.
            let page = try await RemoteDaemonClient().loadSessionEventPage(
                host: host,
                sessionID: sessionID,
                limit: 200
            )
            guard !Task.isCancelled,
                  appState.host == host,
                  session.id == sessionObjectID,
                  session.sessionID == sessionID else { return }
            recentSessionEvents = page.events
            recentSessionEventsRevision &+= 1
        } catch {
            guard !Task.isCancelled, session.id == sessionObjectID else { return }
            recentSessionEvents = []
            recentSessionEventsRevision &+= 1
        }
    }

    @MainActor
    private func refreshSubagents() async {
        // Streaming revisions arrive frequently. Debounce before starting a
        // detached parse so cancelled intermediate renders never queue work.
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        let events = mergedSessionEvents
        let sessionObjectID = session.id
        let summaries = await Task.detached(priority: .userInitiated) {
            SubagentSession.extract(from: events, includeDetailEvents: false)
        }.value
        guard !Task.isCancelled, session.id == sessionObjectID else { return }
        subagents = summaries
        isLoadingSubagents = false
    }

    @MainActor
    private func loadDetail(for summary: SubagentSession) {
        selectedSubagentID = summary.id
        isLoadingDetail = true
        let events = mergedSessionEvents
        let sessionObjectID = session.id
        Task { @MainActor in
            let detail = await Task.detached(priority: .userInitiated) {
                SubagentSession.extract(from: events).first { $0.id == summary.id }
            }.value
            guard !Task.isCancelled,
                  session.id == sessionObjectID,
                  selectedSubagentID == summary.id else { return }
            selectedSubagentDetail = detail
            isLoadingDetail = false
        }
    }
}

private struct SubagentListView: View {
    let subagents: [SubagentSession]
    let onSelect: @MainActor (SubagentSession) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(subagents) { subagent in
                    Button {
                        withAnimation(.snappy(duration: 0.16)) {
                            onSelect(subagent)
                        }
                    } label: {
                        SubagentListRow(subagent: subagent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .scrollContentBackground(.hidden)
    }
}

private struct SubagentListRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState
    let subagent: SubagentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: subagent.isError ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(subagent.isError ? .red : appState.appearance.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(subagent.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
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
                    .background(controlTint(for: colorScheme, opacity: subagent.isError ? 0.10 : 0.06))
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
        .background(controlTint(for: colorScheme, opacity: 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(controlTint(for: colorScheme, opacity: 0.07), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SubagentDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState
    let subagent: SubagentSession
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back to subagents")

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
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(controlTint(for: colorScheme, opacity: 0.04))

            Divider().opacity(0.18)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let cwd = subagent.cwd?.nilIfBlank {
                        Label(cwd, systemImage: "folder")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    ForEach(displayedRows) { row in
                        subagentRow(row)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private func subagentRow(_ row: SubagentDisplayedRow) -> some View {
        switch row {
        case .event(let event):
            switch event {
            case .message(let message, _):
                MessageBubble(message: message)
            case .toolCall(let call, _):
                ToolInteractionRow(
                    name: call.name,
                    arguments: call.arguments,
                    result: nil,
                    visibilityID: "visibility:\(event.id)"
                )
            case .toolResult(let result, _):
                ToolEventRow(
                    kind: .toolResult(name: result.toolName, callId: result.callId, output: result.output, isError: result.isError),
                    visibilityID: "visibility:\(event.id)"
                )
            case .meta(let meta, _):
                ToolEventRow(
                    kind: .meta(displayName: meta.displayName, workingDirectory: meta.workingDirectory, parentSession: meta.parentSession),
                    visibilityID: "visibility:\(event.id)"
                )
            case .other(let type, _):
                ToolEventRow(kind: .other(type: type), visibilityID: "visibility:\(event.id)")
            }
        case .toolInteraction(let call, let result, _):
            ToolInteractionRow(
                name: call.name,
                arguments: call.arguments,
                result: result,
                visibilityID: "visibility:\(row.id)"
            )
        }
    }

    private var displayedRows: [SubagentDisplayedRow] {
        SubagentDisplayedRow.groupingToolResults(in: subagent.events.filter(\.isVisibleInTranscript))
    }
}

private enum SubagentDisplayedRow: Identifiable, Hashable {
    case event(SessionEvent)
    case toolInteraction(call: ToolCall, result: ToolResult?, lineIndex: Int)

    var id: String {
        switch self {
        case .event(let event): return event.id
        case .toolInteraction(let call, _, _): return "subagentToolInteraction:\(call.id)"
        }
    }

    static func groupingToolResults(in events: [SessionEvent]) -> [SubagentDisplayedRow] {
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
                return pairedCallIDs.contains(result.callId) ? nil : .event(event)
            case .message, .meta, .other:
                return .event(event)
            }
        }
    }
}

private struct UtilitySidebarHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(controlTint(for: colorScheme, opacity: 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

private struct UtilityEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 9) {
            Spacer(minLength: 0)
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyCatalogView: View {
    let title: String
    let systemImage: String
    let message: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button(action: action) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SessionListRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState
    let session: PiSessionSummary
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: (PiSessionSummary) -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                onSelect()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contextMenu {
            Button("Rename") {
                onRename(session)
            }
        }
        Divider()
            .padding(.leading, 12)
            .opacity(isSelected ? 0 : 0.28)
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text(session.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(appState.effectiveLastActivity(for: session), style: .date)
                        .lineLimit(1)
                    if session.hasMetadata {
                        SessionMetadataStrip(session: session)
                    }
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            SessionActivityIndicator(
                isGenerating: session.isGenerating || appState.isSessionSending(session),
                showsUnread: appState.hasUnreadIndicator(session),
                accentColor: appState.appearance.accentColor
            )
        }
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            controlTint(for: colorScheme, opacity: 0.14)
        } else {
            Color.clear
        }
    }
}

private struct SessionActivityIndicator: View {
    let isGenerating: Bool
    let showsUnread: Bool
    let accentColor: Color

    var body: some View {
        Group {
            if isGenerating {
                ProgressView()
                    .controlSize(.small)
                    .tint(accentColor)
                    .help("Pi is generating a response")
            } else if showsUnread {
                Circle()
                    .fill(accentColor)
                    .frame(width: 9, height: 9)
            }
        }
        .frame(width: 14, height: 14)
    }
}

private struct SessionMetadataStrip: View {
    let session: PiSessionSummary

    var body: some View {
        HStack(spacing: 5) {
            if session.messageCount > 0 {
                SessionMetadataBadge(systemImage: "text.bubble", value: session.messageCount, help: "Messages")
            }
            if session.branchCount > 0 {
                SessionMetadataBadge(systemImage: "point.3.connected.trianglepath.dotted", value: session.branchCount, help: "Branch points")
            }
            if session.labelCount > 0 {
                SessionMetadataBadge(systemImage: "tag", value: session.labelCount, help: "Labels")
            }
            if session.branchSummaryCount > 0 {
                SessionMetadataBadge(systemImage: "text.badge.checkmark", value: session.branchSummaryCount, help: "Branch summaries")
            }
            if session.parentSession != nil {
                Label("Fork", systemImage: "tuningfork")
                    .labelStyle(.iconOnly)
                    .font(.caption2.weight(.semibold))
                    .help("Forked session")
            }
            if let latestModel = session.latestModel {
                Text(latestModel)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 86)
                    .help(latestModel)
            }
        }
        .foregroundStyle(.tertiary)
    }
}

private struct SessionMetadataBadge: View {
    let systemImage: String
    let value: Int
    let help: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text("\(value)")
                .monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .help(help)
    }
}

struct DetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState

    var body: some View {
        VStack(spacing: 0) {
            ChatWorkspaceView(
                workspace: appState.chatWorkspace,
                appearance: appState.appearance
            )
        }
        .background(appState.appearance.mainBackgroundColor(for: appState.appearance.resolvedColorScheme(current: colorScheme)))
    }
}

private func controlTint(for colorScheme: ColorScheme, opacity: Double) -> Color {
    colorScheme == .dark ? Color.white.opacity(opacity) : Color.black.opacity(opacity)
}
