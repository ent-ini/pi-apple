import Foundation
import SwiftUI
import Testing
@testable import ApplePi
@testable import ApplePiCore
@testable import ApplePiRemote

@Test func shellQuotingProtectsSpacesAndQuotes() {
    #expect("hello".shellQuoted == "hello")
    #expect("two words".shellQuoted == "'two words'")
    #expect("it's".shellQuoted == "'it'\\''s'")
}

@Test func appearanceDecodingKeepsNotificationsEnabledByDefault() throws {
    let data = #"{"emptyTerminalMessage":"Ready"}"#.data(using: .utf8)!

    let appearance = try JSONDecoder().decode(AppAppearance.self, from: data)

    #expect(appearance.emptyChatMessage == "Ready")
    #expect(appearance.notifications.isEnabled)
    #expect(appearance.notifications.presentation == .bannerAndSound)
    #expect(appearance.notifications.allowsForegroundNotifications)
}

@Test func appearanceRoundTripsTopBarAndComposerColors() throws {
    var appearance = AppAppearance()
    appearance.setTopBarBackgroundColor(Color(red: 0.18, green: 0.24, blue: 0.62))
    appearance.setComposerAreaBackgroundColor(Color(red: 0.81, green: 0.85, blue: 0.91))

    let data = try JSONEncoder().encode(appearance)
    let decoded = try JSONDecoder().decode(AppAppearance.self, from: data)

    #expect(decoded.topBarBackgroundColorValue == appearance.topBarBackgroundColorValue)
    #expect(decoded.composerAreaBackgroundColorValue == appearance.composerAreaBackgroundColorValue)
}

@Test func updateCheckReportsNewerLatestRelease() async throws {
    let service = UpdateCheckService(
        latestReleaseURL: URL(string: "https://example.test/releases/latest")!,
        currentVersionProvider: { "1.2.3" },
        fetch: { request in
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "pi-app")
            let data = """
            {"tag_name":"v1.3.0","html_url":"https://example.test/releases/v1.3.0"}
            """.data(using: .utf8)!
            return HTTPResult(statusCode: 200, data: data)
        }
    )

    let update = try await service.checkForUpdate()

    #expect(update?.latestVersion == "1.3.0")
    #expect(update?.releaseURL == URL(string: "https://example.test/releases/v1.3.0"))
}

@Test func updateCheckIgnoresCurrentOrOlderRelease() async throws {
    let service = UpdateCheckService(
        currentVersionProvider: { "1.3.0" },
        fetch: { _ in
            let data = """
            {"tag_name":"v1.3.0","html_url":"https://example.test/releases/v1.3.0"}
            """.data(using: .utf8)!
            return HTTPResult(statusCode: 200, data: data)
        }
    )

    let update = try await service.checkForUpdate()

    #expect(update == nil)
}

@Test func updateCheckIgnoresNonSuccessResponse() async throws {
    let service = UpdateCheckService(
        currentVersionProvider: { "1.0.0" },
        fetch: { _ in HTTPResult(statusCode: 503, data: Data()) }
    )

    let update = try await service.checkForUpdate()

    #expect(update == nil)
}


@Test(.disabled("Local filesystem catalog is legacy-disabled in remote-only mode")) func catalogUsesSessionHeaderCwdForProjectDirectory() async throws {
    let temp = try TemporaryPiFixture()
    let sessionsRoot = temp.agent.appendingPathComponent("sessions")
    let encodedProject = sessionsRoot.appendingPathComponent("--Users-ada-Code-my-project--")
    try Foundation.FileManager().createDirectory(at: encodedProject, withIntermediateDirectories: true)
    let sessionFile = encodedProject.appendingPathComponent("session.jsonl")
    let cwd = "/Users/ada/Code/my-project"
    try """
    {"type":"session","id":"session-1","cwd":"\(cwd)"}
    {"type":"message","role":"user","content":"hello"}
    """.write(to: sessionFile, atomically: true, encoding: .utf8)
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiSessionCatalogService(configurationService: PiConfigurationService(environment: [:]))

    let snapshot = try await service.loadCatalog(host: host)

    #expect(snapshot.sessions.first?.workingDirectory == cwd)
    #expect(snapshot.projects.first?.workingDirectory == cwd)
    #expect(snapshot.projects.first?.title == "my-project")
}

@Test(.disabled("Local filesystem catalog is legacy-disabled in remote-only mode")) func catalogPreservesHyphenatedProjectFolderNameFromSessionHeader() async throws {
    let temp = try TemporaryPiFixture()
    let sessionsRoot = temp.agent.appendingPathComponent("sessions")
    let encodedProject = sessionsRoot.appendingPathComponent("--Users-ada-Code-apple-pi--")
    try Foundation.FileManager().createDirectory(at: encodedProject, withIntermediateDirectories: true)
    let sessionFile = encodedProject.appendingPathComponent("session.jsonl")
    let cwd = "/Users/ada/Code/apple-pi"
    try """
    {"type":"session","id":"session-1","cwd":"\(cwd)"}
    {"type":"message","role":"user","content":"hello"}
    """.write(to: sessionFile, atomically: true, encoding: .utf8)
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiSessionCatalogService(configurationService: PiConfigurationService(environment: [:]))

    let snapshot = try await service.loadCatalog(host: host)

    #expect(snapshot.projects.first?.title == "apple-pi")
}

@Test(.disabled("Local filesystem catalog is legacy-disabled in remote-only mode")) func catalogGroupsRootLevelSessionsByHeaderCwd() async throws {
    let temp = try TemporaryPiFixture()
    let sessionsRoot = temp.agent.appendingPathComponent("sessions")
    let encodedProject = sessionsRoot.appendingPathComponent("--home-edoardo--")
    try Foundation.FileManager().createDirectory(at: encodedProject, withIntermediateDirectories: true)

    let rootSession = sessionsRoot.appendingPathComponent("root-session.jsonl")
    let groupedSession = encodedProject.appendingPathComponent("grouped-session.jsonl")
    let cwd = "/home/edoardo"
    try """
    {"type":"session","id":"root-session","cwd":"\(cwd)"}
    {"type":"message","role":"user","content":"root level"}
    """.write(to: rootSession, atomically: true, encoding: .utf8)
    try """
    {"type":"session","id":"grouped-session","cwd":"\(cwd)"}
    {"type":"message","role":"user","content":"grouped"}
    """.write(to: groupedSession, atomically: true, encoding: .utf8)
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiSessionCatalogService(configurationService: PiConfigurationService(environment: [:]))

    let snapshot = try await service.loadCatalog(host: host)

    #expect(snapshot.projects.count == 1)
    #expect(snapshot.projects.first?.id == "--home-edoardo--")
    #expect(snapshot.projects.first?.sessionCount == 2)
    #expect(Set(snapshot.sessions.map(\.projectID)) == ["--home-edoardo--"])
}

@Test(.disabled("Local filesystem catalog is legacy-disabled in remote-only mode")) func catalogReadsModernSessionMetadata() async throws {
    let temp = try TemporaryPiFixture()
    let sessionsRoot = temp.agent.appendingPathComponent("sessions")
    let encodedProject = sessionsRoot.appendingPathComponent("--Users-ada-Code-my-project--")
    try Foundation.FileManager().createDirectory(at: encodedProject, withIntermediateDirectories: true)
    let sessionFile = encodedProject.appendingPathComponent("session.jsonl")
    let cwd = "/Users/ada/Code/my-project"
    try """
    {"type":"session","version":3,"id":"session-1","cwd":"\(cwd)","parentSession":"/tmp/parent.jsonl"}
    {"type":"message","id":"a","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"Build a tiny dashboard"}]}}
    {"type":"message","id":"b","parentId":"a","message":{"role":"assistant","provider":"openai","model":"gpt-5","content":[{"type":"text","text":"Sure"}]}}
    {"type":"message","id":"c","parentId":"a","message":{"role":"user","content":"Try another path"}}
    {"type":"label","id":"l","parentId":"c","targetId":"a","label":"checkpoint"}
    {"type":"branch_summary","id":"s","parentId":"a","fromId":"b","summary":"Explored first path"}
    {"type":"session_info","id":"n","parentId":"c","name":"Dashboard pass"}
    """.write(to: sessionFile, atomically: true, encoding: .utf8)
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiSessionCatalogService(configurationService: PiConfigurationService(environment: [:]))

    let snapshot = try await service.loadCatalog(host: host)
    let session = try #require(snapshot.sessions.first)

    #expect(session.title == "Dashboard pass")
    #expect(session.parentSession == "/tmp/parent.jsonl")
    #expect(session.branchCount == 1)
    #expect(session.labelCount == 1)
    #expect(session.branchSummaryCount == 1)
    #expect(session.latestModel == "openai/gpt-5")
}

@Test(.disabled("Local filesystem catalog is legacy-disabled in remote-only mode")) func catalogSkipsSymlinkedSessionFiles() async throws {
    let temp = try TemporaryPiFixture()
    let sessionsRoot = temp.agent.appendingPathComponent("sessions")
    let encodedProject = sessionsRoot.appendingPathComponent("--Users-ada-Code-symlink-target--")
    try Foundation.FileManager().createDirectory(at: encodedProject, withIntermediateDirectories: true)
    let realFile = encodedProject.appendingPathComponent("real.jsonl")
    try """
    {"type":"session","id":"real","cwd":"/Users/ada/Code/symlink-target"}
    {"type":"message","role":"user","content":"hello"}
    """.write(to: realFile, atomically: true, encoding: .utf8)
    // Symlink in the same root that points at the real file. If the
    // catalog follows the symlink we would see the same session twice.
    let symlink = sessionsRoot.appendingPathComponent("link-to-real.jsonl")
    try Foundation.FileManager().createSymbolicLink(at: symlink, withDestinationURL: realFile)
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiSessionCatalogService(configurationService: PiConfigurationService(environment: [:]))

    let snapshot = try await service.loadCatalog(host: host)

    #expect(snapshot.sessions.count == 1)
    #expect(snapshot.sessions.first?.filePath == realFile.path)
}

@Test(.disabled("Local filesystem catalog is legacy-disabled in remote-only mode")) func catalogSurfacesInvalidUTF8SessionFileAsWarning() async throws {
    let temp = try TemporaryPiFixture()
    let sessionsRoot = temp.agent.appendingPathComponent("sessions")
    let encodedProject = sessionsRoot.appendingPathComponent("--Users-ada-Code-partial--")
    try Foundation.FileManager().createDirectory(at: encodedProject, withIntermediateDirectories: true)
    // Good file that we expect to be loaded normally.
    let good = encodedProject.appendingPathComponent("good.jsonl")
    try """
    {"type":"session","id":"good","cwd":"/Users/ada/Code/partial"}
    {"type":"message","role":"user","content":"hi"}
    """.write(to: good, atomically: true, encoding: .utf8)
    // A `.jsonl` file whose first preview line contains an invalid
    // UTF-8 byte sequence. The catalog should still surface the good
    // session and also record a warning naming the bad file.
    let bad = encodedProject.appendingPathComponent("bad.jsonl")
    var invalidBytes = Data([0xFF, 0xFE, 0xFD, 0xFC])
    invalidBytes.append(Data(#"{"type":"message","role":"user","content":"ok"}"#.utf8))
    try invalidBytes.write(to: bad)
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiSessionCatalogService(configurationService: PiConfigurationService(environment: [:]))

    let snapshot = try await service.loadCatalog(host: host)

    #expect(snapshot.sessions.contains(where: { $0.filePath == good.path }))
    #expect(snapshot.warnings.contains(where: { $0.contains(bad.path) }))
}

@Test(.disabled("Local filesystem catalog is legacy-disabled in remote-only mode")) func catalogSurfacesUnreadableSessionFileAsWarning() async throws {
    // Skip the test when running as root, because root can read any
    // file regardless of its POSIX mode bits. The test is then unable
    // to make a file genuinely unreadable.
    let runningAsRoot = ProcessInfo.processInfo.environment["USER"] == "root"
        || ProcessInfo.processInfo.environment["HOME"] == "/var/root"
    try #require(!runningAsRoot, "Unreadable-file test does not apply when running as root.")

    let temp = try TemporaryPiFixture()
    let sessionsRoot = temp.agent.appendingPathComponent("sessions")
    let encodedProject = sessionsRoot.appendingPathComponent("--Users-ada-Code-locked--")
    try Foundation.FileManager().createDirectory(at: encodedProject, withIntermediateDirectories: true)
    // Good file we expect to load normally.
    let good = encodedProject.appendingPathComponent("good.jsonl")
    try """
    {"type":"session","id":"good","cwd":"/Users/ada/Code/locked"}
    {"type":"message","role":"user","content":"hi"}
    """.write(to: good, atomically: true, encoding: .utf8)
    // A file we strip of all permissions so the catalog cannot read
    // it. We restore the permissions in a defer so the test fixture's
    // `deinit` can clean up the temporary directory.
    let locked = encodedProject.appendingPathComponent("locked.jsonl")
    try """
    {"type":"session","id":"locked","cwd":"/Users/ada/Code/locked"}
    {"type":"message","role":"user","content":"secret"}
    """.write(to: locked, atomically: true, encoding: .utf8)
    let fileManager = Foundation.FileManager()
    try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o000)], ofItemAtPath: locked.path)
    defer {
        try? fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: locked.path)
    }
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiSessionCatalogService(configurationService: PiConfigurationService(environment: [:]))

    let snapshot = try await service.loadCatalog(host: host)

    #expect(snapshot.sessions.contains(where: { $0.filePath == good.path }))
    #expect(snapshot.warnings.contains(where: { $0.contains(locked.path) }))
}

@Test(.disabled("Local filesystem catalog is legacy-disabled in remote-only mode")) func catalogCountsAllMessagesInOnePass() async throws {
    let temp = try TemporaryPiFixture()
    let sessionsRoot = temp.agent.appendingPathComponent("sessions")
    let encodedProject = sessionsRoot.appendingPathComponent("--Users-ada-Code-counted--")
    try Foundation.FileManager().createDirectory(at: encodedProject, withIntermediateDirectories: true)
    let sessionFile = encodedProject.appendingPathComponent("counted.jsonl")
    // 1 session header line and 250 message lines. The single-pass
    // read should still report all 250 messages in the `messageCount`
    // even though only the first 240 lines are kept for preview.
    var lines: [String] = []
    lines.append(#"{"type":"session","id":"counted","cwd":"/Users/ada/Code/counted"}"#)
    for index in 0..<250 {
        lines.append(#"{"type":"message","role":"user","content":"hello \#(index)"}"#)
    }
    try lines.joined(separator: "\n").write(to: sessionFile, atomically: true, encoding: .utf8)
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiSessionCatalogService(configurationService: PiConfigurationService(environment: [:]))

    let snapshot = try await service.loadCatalog(host: host)
    let session = try #require(snapshot.sessions.first)

    #expect(session.messageCount == 250)
}

@Test(.disabled("Local filesystem catalog is legacy-disabled in remote-only mode")) func catalogBoundsLargeSessionFiles() async throws {
    let temp = try TemporaryPiFixture()
    let sessionsRoot = temp.agent.appendingPathComponent("sessions")
    let encodedProject = sessionsRoot.appendingPathComponent("--Users-ada-Code-huge--")
    try Foundation.FileManager().createDirectory(at: encodedProject, withIntermediateDirectories: true)
    let sessionFile = encodedProject.appendingPathComponent("huge.jsonl")
    // Write a session file with a header plus many message lines, so
    // we exceed the catalog's bounded line cap and the catalog should
    // surface a warning rather than read the entire file forever.
    let lineCount = 250_001
    var lines: [String] = ["{\"type\":\"session\",\"id\":\"huge\",\"cwd\":\"/Users/ada/Code/huge\"}"]
    lines.reserveCapacity(lineCount)
    for index in 0..<(lineCount - 1) {
        lines.append(#"{"type":"message","role":"user","content":"hi \#(index)"}"#)
    }
    try lines.joined(separator: "\n").write(to: sessionFile, atomically: true, encoding: .utf8)
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiSessionCatalogService(configurationService: PiConfigurationService(environment: [:]))

    let snapshot = try await service.loadCatalog(host: host)
    let session = try #require(snapshot.sessions.first)

    #expect(session.messageCount <= 200_000)
    #expect(snapshot.warnings.contains(where: { $0.contains("Truncated") }))
}

@MainActor
@Test func catalogStatusMessageIncludesWarningsAndCount() {
    #expect(PiAppState.catalogStatusMessage(sessionCount: 0, warnings: []) == "Loaded 0 Pi sessions")
    #expect(PiAppState.catalogStatusMessage(sessionCount: 1, warnings: []) == "Loaded 1 Pi session")
    #expect(PiAppState.catalogStatusMessage(sessionCount: 2, warnings: []) == "Loaded 2 Pi sessions")
    let withOne = PiAppState.catalogStatusMessage(
        sessionCount: 3,
        warnings: ["Read error in /tmp/a.jsonl: oops"]
    )
    #expect(withOne.contains("Loaded 3 Pi sessions"))
    #expect(withOne.contains("Read error in /tmp/a.jsonl: oops"))
    let withMany = PiAppState.catalogStatusMessage(
        sessionCount: 3,
        warnings: ["warn-1", "warn-2", "warn-3", "warn-4", "warn-5"]
    )
    #expect(withMany.contains("warn-1"))
    #expect(withMany.contains("(+ 2 more)"))
}

@MainActor
@Test func deleteSessionIsUnsupportedInRemoteOnlyMode() async throws {
    let temp = try TemporaryPiFixture()
    let sessionFile = temp.root.appendingPathComponent("session.jsonl")
    try "{}".write(to: sessionFile, atomically: true, encoding: .utf8)
    let session = PiSessionSummary(
        id: "session-1",
        filePath: sessionFile.path,
        projectID: "project",
        title: "Delete me",
        workingDirectory: temp.project.path,
        messageCount: 1,
        modifiedAt: Date(),
        displayName: nil,
        parentSession: nil,
        branchCount: 0,
        labelCount: 0,
        branchSummaryCount: 0,
        latestModel: nil
    )
    let state = PiAppState(
        defaults: isolatedDefaults(),
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )

    state.delete(session)

    #expect(Foundation.FileManager().fileExists(atPath: sessionFile.path))
    #expect(state.statusMessage == "Remote session deletion is not supported from pi-app.")
}

@MainActor
@Test func appStateStartupLoadsPersistedHostWithoutDuplicateCatalogRefresh() async throws {
    let defaults = isolatedDefaults()
    let host = PiHostConfiguration(agentDirectory: "/tmp/custom-agent")
    let hostData = try JSONEncoder().encode(host)
    defaults.set(hostData, forKey: "ApplePi.host")
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")
    let probe = CatalogLoaderProbe()

    _ = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        catalogLoader: { host, _ in
            await probe.load(host: host)
        }
    )
    try await Task.sleep(for: .milliseconds(100))

    #expect(await probe.callCount == 1)
    #expect(await probe.loadedHosts == [host])
}

@MainActor
@Test func catalogRefreshPreservesOpenPendingSessionInSidebar() async throws {
    let defaults = isolatedDefaults()
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")
    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        catalogLoader: { _, _ in PiCatalogSnapshot(projects: [], sessions: []) },
        startsBackgroundWork: false
    )

    state.openNewSession(in: "/tmp/project")
    guard let tab = state.chatWorkspace.selectedTab else {
        Issue.record("expected a selected new tab")
        return
    }
    tab.beginSending(prompt: "hello")

    state.refreshCatalog()
    try await Task.sleep(for: .milliseconds(100))

    #expect(state.sessions.contains { $0.filePath == tab.key || $0.id == tab.key })
    #expect(state.selection == .session(tab.key))
}

@MainActor
@Test func selectingOlderSessionDoesNotPromoteItInSessionList() async throws {
    let defaults = isolatedDefaults()
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")
    let now = Date()
    let newer = PiSessionSummary(id: "newer", filePath: "/tmp/newer.jsonl", projectID: "p", title: "Newer", workingDirectory: "/tmp/project", messageCount: 1, modifiedAt: now, displayName: nil, parentSession: nil, branchCount: 0, labelCount: 0, branchSummaryCount: 0, latestModel: nil)
    let older = PiSessionSummary(id: "older", filePath: "/tmp/older.jsonl", projectID: "p", title: "Older", workingDirectory: "/tmp/project", messageCount: 1, modifiedAt: now.addingTimeInterval(-3600), displayName: nil, parentSession: nil, branchCount: 0, labelCount: 0, branchSummaryCount: 0, latestModel: nil)
    let snapshot = PiCatalogSnapshot(
        projects: [PiProject(id: "p", title: "Project", workingDirectory: "/tmp/project", sessionDirectory: "p", sessionCount: 2, lastActivity: now)],
        sessions: [newer, older]
    )
    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        catalogLoader: { _, _ in snapshot },
        startsBackgroundWork: false
    )

    state.refreshCatalog()
    try await Task.sleep(for: .milliseconds(100))
    #expect(state.filteredSessions().map(\.id) == ["newer", "older"])

    state.select(.session("older"))

    #expect(state.filteredSessions().map(\.id) == ["newer", "older"])
    #expect(state.isSelectedSession(older))
}

@MainActor
@Test func catalogRefreshDoesNotReplaceRealSessionSummaryWithSyntheticOpenTab() async throws {
    let defaults = isolatedDefaults()
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")
    let now = Date()
    let real = PiSessionSummary(id: "real", filePath: "/tmp/real.jsonl", projectID: "p", title: "Real summary", workingDirectory: "/tmp/project", messageCount: 12, modifiedAt: now, displayName: "Real summary", parentSession: nil, branchCount: 1, labelCount: 2, branchSummaryCount: 3, latestModel: "provider/model")
    let snapshot = PiCatalogSnapshot(
        projects: [PiProject(id: "p", title: "Project", workingDirectory: "/tmp/project", sessionDirectory: "p", sessionCount: 1, lastActivity: now)],
        sessions: [real]
    )
    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        catalogLoader: { _, _ in snapshot },
        startsBackgroundWork: false
    )

    state.refreshCatalog()
    try await Task.sleep(for: .milliseconds(100))
    state.select(.session("real"))
    state.refreshCatalog()
    try await Task.sleep(for: .milliseconds(100))

    #expect(state.sessions.first?.messageCount == 12)
    #expect(state.sessions.first?.branchCount == 1)
    #expect(state.sessions.first?.labelCount == 2)
    #expect(state.sessions.first?.branchSummaryCount == 3)
    #expect(state.sessions.first?.latestModel == "provider/model")
}

@MainActor
@Test func openingNewSessionAddsStableSelectedSidebarEntryBeforeFirstSend() async throws {
    let defaults = isolatedDefaults()
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")
    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        catalogLoader: { _, _ in PiCatalogSnapshot(projects: [], sessions: []) },
        startsBackgroundWork: false
    )

    state.openNewSession(in: "/tmp/project")

    guard let tab = state.chatWorkspace.selectedTab else {
        Issue.record("expected a selected new tab")
        return
    }
    #expect(state.sessions.map(\.id) == [tab.key])
    #expect(state.selection == .session(tab.key))
    #expect(state.filteredSessions().map(\.id) == [tab.key])
}

@MainActor
@Test func sessionSearchCanMatchAcrossProjects() async throws {
    let defaults = isolatedDefaults()
    defaults.set(Date(), forKey: "ApplePi.updateCheck.lastCheckedAt")
    let now = Date()
    let snapshot = PiCatalogSnapshot(
        projects: [
            PiProject(id: "a", title: "Alpha", workingDirectory: "/tmp/a", sessionDirectory: "a", sessionCount: 1, lastActivity: now),
            PiProject(id: "b", title: "Beta", workingDirectory: "/tmp/b", sessionDirectory: "b", sessionCount: 1, lastActivity: now)
        ],
        sessions: [
            PiSessionSummary(id: "1", filePath: "/tmp/a/one.jsonl", projectID: "a", title: "Design Notes", workingDirectory: "/tmp/a", messageCount: 1, modifiedAt: now, displayName: nil, parentSession: nil, branchCount: 0, labelCount: 0, branchSummaryCount: 0, latestModel: nil),
            PiSessionSummary(id: "2", filePath: "/tmp/b/two.jsonl", projectID: "b", title: "Design Review", workingDirectory: "/tmp/b", messageCount: 1, modifiedAt: now.addingTimeInterval(-60), displayName: nil, parentSession: nil, branchCount: 0, labelCount: 0, branchSummaryCount: 0, latestModel: nil)
        ]
    )
    let state = PiAppState(
        defaults: defaults,
        configurationService: PiConfigurationService(environment: [:]),
        catalogLoader: { _, _ in snapshot }
    )
    try await Task.sleep(for: .milliseconds(100))

    state.sessionSearchText = "design"

    let matched = state.filteredSessions(for: nil)

    #expect(matched.map(\.id) == ["1", "2"])
}

@Test func sessionRootDefaultsToAgentSessions() throws {
    let temp = try TemporaryPiFixture()
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiConfigurationService(environment: [:])

    let resolution = service.resolveSessionRoots(host: host, projectDirectory: nil)

    #expect(resolution.displayRoot == temp.agent.appendingPathComponent("sessions").path)
    #expect(resolution.roots == [temp.agent.appendingPathComponent("sessions").path])
}

@Test func globalSessionDirOverridesDefault() throws {
    let temp = try TemporaryPiFixture()
    try temp.writeJSON(["sessionDir": "global-sessions"], to: temp.agent.appendingPathComponent("settings.json"))
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiConfigurationService(environment: [:])

    let resolution = service.resolveSessionRoots(host: host, projectDirectory: nil)

    #expect(resolution.displayRoot == temp.agent.appendingPathComponent("global-sessions").path)
    #expect(resolution.roots.first == temp.agent.appendingPathComponent("global-sessions").path)
    #expect(resolution.roots.contains(temp.agent.appendingPathComponent("sessions").path))
}

@Test func trustedProjectSessionDirOverridesGlobalDisplayRoot() throws {
    let temp = try TemporaryPiFixture()
    try temp.writeJSON(["sessionDir": "global-sessions"], to: temp.agent.appendingPathComponent("settings.json"))
    try temp.writeJSON([temp.project.path: true], to: temp.agent.appendingPathComponent("trust.json"))
    try Foundation.FileManager().createDirectory(at: temp.project.appendingPathComponent(".pi"), withIntermediateDirectories: true)
    try temp.writeJSON(["sessionDir": "project-sessions"], to: temp.project.appendingPathComponent(".pi/settings.json"))
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiConfigurationService(environment: [:])

    let resolution = service.resolveSessionRoots(host: host, projectDirectory: temp.project.path)

    #expect(resolution.displayRoot == temp.project.appendingPathComponent(".pi/project-sessions").path)
    #expect(resolution.roots.first == temp.project.appendingPathComponent(".pi/project-sessions").path)
}

@Test func untrustedProjectSessionDirIsIgnored() throws {
    let temp = try TemporaryPiFixture()
    try temp.writeJSON(["sessionDir": "global-sessions"], to: temp.agent.appendingPathComponent("settings.json"))
    try temp.writeJSON([temp.project.path: false], to: temp.agent.appendingPathComponent("trust.json"))
    try Foundation.FileManager().createDirectory(at: temp.project.appendingPathComponent(".pi"), withIntermediateDirectories: true)
    try temp.writeJSON(["sessionDir": "project-sessions"], to: temp.project.appendingPathComponent(".pi/settings.json"))
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiConfigurationService(environment: [:])

    let resolution = service.resolveSessionRoots(host: host, projectDirectory: temp.project.path)

    #expect(resolution.displayRoot == temp.agent.appendingPathComponent("global-sessions").path)
    #expect(!resolution.roots.contains(temp.project.appendingPathComponent(".pi/project-sessions").path))
}

@Test func unrelatedBooleanTrustValuesDoNotTrustProject() throws {
    let temp = try TemporaryPiFixture()
    try temp.writeJSON(["sessionDir": "global-sessions"], to: temp.agent.appendingPathComponent("settings.json"))
    try Foundation.FileManager().createDirectory(at: temp.project.appendingPathComponent(".pi"), withIntermediateDirectories: true)
    try temp.writeJSON(["sessionDir": "project-sessions"], to: temp.project.appendingPathComponent(".pi/settings.json"))
    try temp.writeJSON(["metadata": ["enabled": true]], to: temp.agent.appendingPathComponent("trust.json"))
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiConfigurationService(environment: [:])

    let resolution = service.resolveSessionRoots(host: host, projectDirectory: temp.project.path)

    #expect(resolution.displayRoot == temp.agent.appendingPathComponent("global-sessions").path)
    #expect(!resolution.roots.contains(temp.project.appendingPathComponent(".pi/project-sessions").path))
}

@Test func environmentSessionDirOverridesSettings() throws {
    let temp = try TemporaryPiFixture()
    try temp.writeJSON(["sessionDir": "global-sessions"], to: temp.agent.appendingPathComponent("settings.json"))
    let override = temp.root.appendingPathComponent("env-sessions").path
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiConfigurationService(environment: ["PI_CODING_AGENT_SESSION_DIR": override])

    let resolution = service.resolveSessionRoots(host: host, projectDirectory: nil)

    #expect(resolution.displayRoot == override)
    #expect(resolution.roots == [override])
}

@Test func invalidSettingsAreIgnored() throws {
    let temp = try TemporaryPiFixture()
    try "not json".write(to: temp.agent.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    let service = PiConfigurationService(environment: [:])

    let settings = service.readSettings(at: temp.agent.appendingPathComponent("settings.json").path)

    #expect(settings == nil)
}

@Test func configurationSummaryCountsContextAndResources() throws {
    let temp = try TemporaryPiFixture()
    try temp.writeJSON([temp.project.path: true], to: temp.agent.appendingPathComponent("trust.json"))
    try Foundation.FileManager().createDirectory(at: temp.project.appendingPathComponent(".pi/extensions"), withIntermediateDirectories: true)
    try Foundation.FileManager().createDirectory(at: temp.agent.appendingPathComponent("skills"), withIntermediateDirectories: true)
    try "".write(to: temp.project.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try "".write(to: temp.agent.appendingPathComponent("SYSTEM.md"), atomically: true, encoding: .utf8)
    try "".write(to: temp.project.appendingPathComponent(".pi/extensions/local.ts"), atomically: true, encoding: .utf8)
    try "".write(to: temp.agent.appendingPathComponent("skills/review.md"), atomically: true, encoding: .utf8)
    try temp.writeJSON(["prompts": ["review.md"]], to: temp.agent.appendingPathComponent("settings.json"))
    let host = PiHostConfiguration(agentDirectory: temp.agent.path)
    let service = PiConfigurationService(environment: [:])

    let summary = service.loadSummary(host: host, projectDirectory: temp.project.path)

    #expect(summary.trustStatus == .trusted)
    #expect(summary.settingsCount == 1)
    #expect(summary.contextFileCount == 2)
    #expect(summary.resourceCount == 3)
    #expect(summary.settingsPaths == [temp.agent.appendingPathComponent("settings.json").path])
    #expect(summary.contextFilePaths.contains(temp.project.appendingPathComponent("AGENTS.md").path))
    #expect(summary.resourceRootPaths.contains(temp.agent.appendingPathComponent("skills").path))
}

@MainActor
@Test func remoteDeleteDoesNotRemoveLocalPathCollision() throws {
    let temp = try TemporaryPiFixture()
    let sessionFile = temp.root.appendingPathComponent("session.jsonl")
    try "{}".write(to: sessionFile, atomically: true, encoding: .utf8)
    let session = PiSessionSummary(
        id: "session-1",
        filePath: sessionFile.path,
        projectID: "project",
        title: "Remote",
        workingDirectory: temp.project.path,
        messageCount: 1,
        modifiedAt: Date(),
        displayName: nil,
        parentSession: nil,
        branchCount: 0,
        labelCount: 0,
        branchSummaryCount: 0,
        latestModel: nil
    )
    let state = PiAppState(
        defaults: isolatedDefaults(),
        configurationService: PiConfigurationService(environment: [:]),
        catalogLoader: { _, _ in PiCatalogSnapshot(projects: [], sessions: []) },
        startsBackgroundWork: false
    )
    state.delete(session)

    #expect(Foundation.FileManager().fileExists(atPath: sessionFile.path))
    #expect(state.statusMessage == "Remote session deletion is not supported from pi-app.")
}

@MainActor
@Test func remoteConfigurationSummaryDoesNotExposeLocalConfiguration() {
    let state = PiAppState(
        defaults: isolatedDefaults(),
        configurationService: PiConfigurationService(environment: [:]),
        catalogLoader: { _, _ in PiCatalogSnapshot(projects: [], sessions: []) },
        startsBackgroundWork: false
    )
    state.host = PiHostConfiguration(
        mode: .remoteAPI,
        agentDirectory: "~/.pi/agent",
        remoteDaemonURL: "http://pi.example.com:8787"
    )

    #expect(state.configurationSummary.isRemote)
    #expect(state.configurationSummary.trustDisplayTitle == "Remote API")
    #expect(state.configurationSummary.globalSettingsPath.isEmpty)
    #expect(state.configurationSummary.settingsCount == 0)
    #expect(state.configurationSummary.contextFileCount == 0)
    #expect(state.configurationSummary.resourceCount == 0)
}

private final class TemporaryPiFixture {
    let root: URL
    let agent: URL
    let project: URL

    init() throws {
        root = Foundation.FileManager().temporaryDirectory.appendingPathComponent(UUID().uuidString)
        agent = root.appendingPathComponent("agent")
        project = root.appendingPathComponent("project")
        try Foundation.FileManager().createDirectory(at: agent, withIntermediateDirectories: true)
        try Foundation.FileManager().createDirectory(at: project, withIntermediateDirectories: true)
    }

    deinit {
        try? Foundation.FileManager().removeItem(at: root)
    }

    func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url)
    }
}

private actor CatalogLoaderProbe {
    private(set) var callCount = 0
    private(set) var loadedHosts: [PiHostConfiguration] = []
    private(set) var loadedProjectDirectories: [String?] = []

    func load(
        host: PiHostConfiguration,
        activeProjectDirectory: String? = nil,
        snapshot: PiCatalogSnapshot = PiCatalogSnapshot(projects: [], sessions: [])
    ) -> PiCatalogSnapshot {
        callCount += 1
        loadedHosts.append(host)
        loadedProjectDirectories.append(activeProjectDirectory)
        return snapshot
    }
}

private func isolatedDefaults() -> UserDefaults {
    let suiteName = "ApplePiTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@Test func sessionEventParserReadsUserAndAssistantMessages() {
    let lines = [
        #"{"type":"session","id":"s1","cwd":"/tmp/proj"}"#,
        #"{"type":"message","message":{"role":"user","content":"hello"}}"#,
        #"{"type":"message","message":{"role":"assistant","content":"hi there","model":"anthropic/claude-3.5"}}"#
    ]

    let events = SessionEventParser.parse(lines: lines)

    #expect(events.count == 3)
    if case .message(let user, _) = events[1] {
        #expect(user.role == .user)
        #expect(user.content == [.text("hello")])
    } else {
        Issue.record("Expected user message at index 1")
    }
    if case .message(let assistant, _) = events[2] {
        #expect(assistant.role == .assistant)
        #expect(assistant.model == "anthropic/claude-3.5")
        #expect(assistant.content == [.text("hi there")])
    } else {
        Issue.record("Expected assistant message at index 2")
    }
}

@Test func transcriptVisibilityHidesRuntimeBookkeepingEvents() {
    let events = SessionEventParser.parse(lines: [
        #"{"type":"session","id":"s1","cwd":"/tmp/proj"}"#,
        #"{"type":"model_change","provider":"opencode-go","model":"minimax-m3"}"#,
        #"{"type":"thinking_level_change","level":"high"}"#,
        #"{"type":"label","label":"checkpoint"}"#,
        #"{"type":"message","message":{"role":"user","content":"hello"}}"#
    ])

    let visible = events.filter(\.isVisibleInTranscript)

    #expect(visible.count == 2)
    #expect({
        if case .other(let type, _) = visible[0] { return type == "label" }
        return false
    }())
    #expect({
        if case .message = visible[1] { return true }
        return false
    }())
}

@Test func transcriptVisibilityHidesCompactionBookkeepingEvents() {
    let events = SessionEventParser.parse(lines: [
        #"{"type":"message","message":{"role":"user","content":"before"}}"#,
        #"{"type":"compaction","summary":"large summary"}"#,
        #"{"type":"compaction_start","reason":"manual"}"#,
        #"{"type":"compaction_end","reason":"manual"}"#,
        #"{"type":"message","message":{"role":"assistant","content":"after"}}"#
    ])

    let visible = events.filter(\.isVisibleInTranscript)

    #expect(visible.count == 2)
    #expect({
        if case .message(let message, _) = visible[0] { return message.content == [.text("before")] }
        return false
    }())
    #expect({
        if case .message(let message, _) = visible[1] { return message.content == [.text("after")] }
        return false
    }())
}

@Test func transcriptVisibilityHidesThinkingOnlyAssistantFragments() {
    let events = SessionEventParser.parse(lines: [
        #"{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"checking"},{"type":"toolCall","id":"call-1","name":"read","arguments":{}}]}}"#,
        #"{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"done"},{"type":"text","text":"Готово"}]}}"#
    ])

    let visible = events.filter(\.isVisibleInTranscript)

    #expect(visible.count == 2)
    #expect({
        if case .toolCall = visible[0] { return true }
        return false
    }())
    #expect({
        if case .message(let message, _) = visible[1] { return message.content.contains(.text("Готово")) }
        return false
    }())
}

@Test func sessionEventParserHandlesContentBlocksAndImages() {
    let lines = [
        #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"see "},{"type":"image","source":{"path":"/tmp/cat.png","media_type":"image/png"}}]}}"#
    ]

    let events = SessionEventParser.parse(lines: lines)

    guard events.count == 1, case .message(let message, _) = events[0] else {
        Issue.record("Expected one message event")
        return
    }
    #expect(message.content.count == 2)
    if case .text(let text) = message.content[0] {
        #expect(text == "see ")
    } else {
        Issue.record("Expected first block to be text")
    }
    if case .image(let path, let mime) = message.content[1] {
        #expect(path == "/tmp/cat.png")
        #expect(mime == "image/png")
    } else {
        Issue.record("Expected second block to be image")
    }
}

@Test func sessionEventParserSkipsBlankAndMalformedLines() {
    let lines = [
        "",
        "not json at all",
        #"{"unrelated":"value"}"#,
        #"{"type":"message","message":{"role":"user","content":"valid"}}"#,
        ""
    ]

    let events = SessionEventParser.parse(lines: lines)

    #expect(events.count == 1)
    if case .message(let message, let lineIndex) = events[0] {
        #expect(message.content == [.text("valid")])
        #expect(lineIndex == 3)
    } else {
        Issue.record("Expected a single valid message")
    }
}

@Test func sessionEventParserCapturesToolCallsAndResults() {
    let lines = [
        #"{"type":"tool_use","id":"call-1","name":"read_file","input":{"path":"/tmp/a.txt"}}"#,
        #"{"type":"tool_result","toolCallId":"call-1","content":"file contents","isError":false}"#
    ]

    let events = SessionEventParser.parse(lines: lines)

    #expect(events.count == 2)
    if case .toolCall(let call, _) = events[0] {
        #expect(call.id == "call-1")
        if case .function(_, let name, let arguments) = call {
            #expect(name == "read_file")
            #expect(arguments.contains("\"path\":\"/tmp/a.txt\""))
        } else {
            Issue.record("Expected function-style tool call")
        }
    } else {
        Issue.record("Expected tool call at index 0")
    }
    if case .toolResult(let result, _) = events[1] {
        #expect(result.callId == "call-1")
        if case .result(_, _, _, let output, let isError) = result {
            #expect(output == "file contents")
            #expect(isError == false)
        } else {
            Issue.record("Expected plain tool result")
        }
    } else {
        Issue.record("Expected tool result at index 1")
    }
}

@Test func sessionEventDecodeAppendsLineIndexForLiveTail() {
    let raw = #"{"type":"message","message":{"role":"user","content":"queued"}}"#

    let event = SessionEventParser.decode(line: raw, at: 42)

    guard let event, case .message(_, let lineIndex) = event else {
        Issue.record("Expected a message with line index")
        return
    }
    #expect(lineIndex == 42)
}

@Test func sessionEventIdentityDoesNotDependOnLineIndex() {
    let message = Message(id: "m1", role: .assistant, content: [.text("hi")], model: nil, timestamp: nil, parentId: nil)
    let first = SessionEvent.message(message, lineIndex: 1)
    let finalEvent = SessionEvent.message(message, lineIndex: 99)

    #expect(first.id == finalEvent.id)
}

@Test func piTurnStreamParserDecodesFinalToolResultMessageEvents() {
    let raw = #"{"type":"message_end","message":{"role":"toolResult","toolCallId":"call-1","content":"done","isError":false}}"#

    let event = PiTurnStreamParser.parseLine(raw)

    guard let event else {
        Issue.record("Expected a streamed tool-result event")
        return
    }
    guard case .sessionEvents(let events, let isFinal) = event else {
        Issue.record("Expected .sessionEvents")
        return
    }
    #expect(isFinal)
    guard case .toolResult(let result, _) = events.first else {
        Issue.record("Expected first streamed event to be .toolResult")
        return
    }
    #expect(result.callId == "call-1")
    #expect(result.output == "done")
}

@Test func piTurnStreamParserRecognizesTurnEnd() {
    let raw = #"{"type":"turn_end","message":{"role":"assistant","content":"done"},"toolResults":[]}"#

    let event = PiTurnStreamParser.parseLine(raw)

    guard let event else {
        Issue.record("Expected a turn-end event")
        return
    }
    if case .turnEnd = event {
        // ok
    } else {
        Issue.record("Expected .turnEnd")
    }
}

@Test func piTurnStreamParserRecognizesAgentEnd() {
    let raw = #"{"type":"agent_end"}"#

    let event = PiTurnStreamParser.parseLine(raw)

    guard let event else {
        Issue.record("Expected an agent-end event")
        return
    }
    if case .agentEnd = event {
        // ok
    } else {
        Issue.record("Expected .agentEnd")
    }
}

@Test func piTurnStreamParserRecognizesOutputComplete() {
    let raw = #"{"type":"output_complete"}"#

    let event = PiTurnStreamParser.parseLine(raw)

    guard let event else {
        Issue.record("Expected an output-complete event")
        return
    }
    if case .outputComplete = event {
        // ok
    } else {
        Issue.record("Expected .outputComplete")
    }
}

@Test func piTurnStreamParserRecognizesAbort() {
    let raw = #"{"type":"abort"}"#

    let event = PiTurnStreamParser.parseLine(raw)

    guard let event else {
        Issue.record("Expected an abort event")
        return
    }
    if case .abort = event {
        // ok
    } else {
        Issue.record("Expected .abort")
    }
}

@Test func shortcutPreferencesUseDefaultsAndSwapConflicts() {
    var preferences = AppShortcutPreferences()

    #expect(preferences.binding(for: .newSession).displayString == "⌘N")
    #expect(preferences.binding(for: .findSessions).displayString == "⌘F")

    preferences.set(AppShortcut(key: .character("f"), modifiers: .command), for: .newSession)

    #expect(preferences.binding(for: .newSession).displayString == "⌘F")
    #expect(preferences.binding(for: .findSessions).displayString == "⌘N")

    preferences.set(AppShortcutAction.newSession.defaultShortcut, for: .newSession)

    #expect(preferences.binding(for: .newSession).displayString == "⌘N")
}

@MainActor
@Test func appStateCanRequestSessionSearchFocus() {
    let state = PiAppState(
        defaults: isolatedDefaults(),
        configurationService: PiConfigurationService(environment: [:]),
        startsBackgroundWork: false
    )

    #expect(state.pendingSessionSearchFocusRequest == false)
    let previousID = state.sessionSearchFocusRequestID

    state.requestSessionSearchFocus()

    #expect(state.pendingSessionSearchFocusRequest)
    #expect(state.sessionSearchFocusRequestID == previousID + 1)

    state.consumeSessionSearchFocusRequest()

    #expect(state.pendingSessionSearchFocusRequest == false)
}

// MARK: - Test helpers

private func makeTemporaryHomeDirectory() -> String {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ApplePiTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(atPath: directory.path, withIntermediateDirectories: true)
    return directory.path
}
