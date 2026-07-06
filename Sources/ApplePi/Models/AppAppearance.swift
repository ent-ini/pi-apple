import AppKit
import Foundation
import SwiftUI
import ApplePiCore
import ApplePiRemote

struct AppAppearance: Codable, Equatable {
    var accentColorValue: CodableAccentColor = .yellow
    var mainBackgroundColorValue: CodableAccentColor?
    var topBarBackgroundColorValue: CodableAccentColor?
    var sidebarBackgroundColorValue: CodableAccentColor?
    var composerAreaBackgroundColorValue: CodableAccentColor?
    var textColorValue: CodableAccentColor?
    var userMessageBackgroundColorValue: CodableAccentColor?
    var userMessageTextColorValue: CodableAccentColor?
    var assistantMessageBackgroundColorValue: CodableAccentColor?
    var assistantMessageTextColorValue: CodableAccentColor?
    var colorScheme: AppColorSchemePreference = .system
    var useTransparentTitlebar: Bool = true
    var emptyChatMessage: String = "Hi"
    var notifications: TerminalNotificationPreferences = TerminalNotificationPreferences()

    init() {}

    // Explicit CodingKeys: opacity keys and `emptyTerminalMessage` are kept
    // only so older saved settings still decode. New encodes do not write
    // opacity settings any more: colors are now the customization surface.
    enum CodingKeys: String, CodingKey {
        case windowOpacity
        case sidebarOpacity
        case listOpacity
        case chromeOpacity
        case chatSurfaceOpacity
        case terminalOpacity
        case reduceTransparency
        case accentColorValue
        case accentColorName
        case mainBackgroundColorValue
        case topBarBackgroundColorValue
        case sidebarBackgroundColorValue
        case composerAreaBackgroundColorValue
        case textColorValue
        case userMessageBackgroundColorValue
        case userMessageTextColorValue
        case assistantMessageBackgroundColorValue
        case assistantMessageTextColorValue
        case colorScheme
        case useTransparentTitlebar
        case emptyChatMessage
        case emptyTerminalMessage
        case notifications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accentColorValue = try container.decodeIfPresent(CodableAccentColor.self, forKey: .accentColorValue)
            ?? (try container.decodeIfPresent(AccentColorName.self, forKey: .accentColorName).map(CodableAccentColor.init))
            ?? .yellow
        mainBackgroundColorValue = try container.decodeIfPresent(CodableAccentColor.self, forKey: .mainBackgroundColorValue)
        topBarBackgroundColorValue = try container.decodeIfPresent(CodableAccentColor.self, forKey: .topBarBackgroundColorValue)
        sidebarBackgroundColorValue = try container.decodeIfPresent(CodableAccentColor.self, forKey: .sidebarBackgroundColorValue)
        composerAreaBackgroundColorValue = try container.decodeIfPresent(CodableAccentColor.self, forKey: .composerAreaBackgroundColorValue)
        textColorValue = try container.decodeIfPresent(CodableAccentColor.self, forKey: .textColorValue)
        userMessageBackgroundColorValue = try container.decodeIfPresent(CodableAccentColor.self, forKey: .userMessageBackgroundColorValue)
        userMessageTextColorValue = try container.decodeIfPresent(CodableAccentColor.self, forKey: .userMessageTextColorValue)
        assistantMessageBackgroundColorValue = try container.decodeIfPresent(CodableAccentColor.self, forKey: .assistantMessageBackgroundColorValue)
        assistantMessageTextColorValue = try container.decodeIfPresent(CodableAccentColor.self, forKey: .assistantMessageTextColorValue)
        colorScheme = try container.decodeIfPresent(AppColorSchemePreference.self, forKey: .colorScheme) ?? .system
        useTransparentTitlebar = try container.decodeIfPresent(Bool.self, forKey: .useTransparentTitlebar) ?? true
        emptyChatMessage = try container.decodeIfPresent(String.self, forKey: .emptyChatMessage)
            ?? container.decodeIfPresent(String.self, forKey: .emptyTerminalMessage)
            ?? "Hi"
        notifications = try container.decodeIfPresent(TerminalNotificationPreferences.self, forKey: .notifications) ?? TerminalNotificationPreferences()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accentColorValue, forKey: .accentColorValue)
        try container.encodeIfPresent(mainBackgroundColorValue, forKey: .mainBackgroundColorValue)
        try container.encodeIfPresent(topBarBackgroundColorValue, forKey: .topBarBackgroundColorValue)
        try container.encodeIfPresent(sidebarBackgroundColorValue, forKey: .sidebarBackgroundColorValue)
        try container.encodeIfPresent(composerAreaBackgroundColorValue, forKey: .composerAreaBackgroundColorValue)
        try container.encodeIfPresent(textColorValue, forKey: .textColorValue)
        try container.encodeIfPresent(userMessageBackgroundColorValue, forKey: .userMessageBackgroundColorValue)
        try container.encodeIfPresent(userMessageTextColorValue, forKey: .userMessageTextColorValue)
        try container.encodeIfPresent(assistantMessageBackgroundColorValue, forKey: .assistantMessageBackgroundColorValue)
        try container.encodeIfPresent(assistantMessageTextColorValue, forKey: .assistantMessageTextColorValue)
        try container.encode(colorScheme, forKey: .colorScheme)
        try container.encode(useTransparentTitlebar, forKey: .useTransparentTitlebar)
        try container.encode(emptyChatMessage, forKey: .emptyChatMessage)
        try container.encode(notifications, forKey: .notifications)
    }

    var accentColor: Color {
        accentColorValue.color
    }

    var accentForegroundColor: Color {
        accentColorValue.readableForegroundColor
    }

    var userMessageBackgroundColor: Color {
        userMessageBackgroundColorValue?.color ?? accentColor
    }

    var userMessageTextColor: Color {
        userMessageTextColorValue?.color ?? accentForegroundColor
    }

    mutating func setAccentColor(_ color: Color) {
        accentColorValue = CodableAccentColor(color)
    }

    mutating func setMainBackgroundColor(_ color: Color) {
        mainBackgroundColorValue = CodableAccentColor(color)
    }

    mutating func setTopBarBackgroundColor(_ color: Color) {
        topBarBackgroundColorValue = CodableAccentColor(color)
    }

    mutating func setSidebarBackgroundColor(_ color: Color) {
        sidebarBackgroundColorValue = CodableAccentColor(color)
    }

    mutating func setComposerAreaBackgroundColor(_ color: Color) {
        composerAreaBackgroundColorValue = CodableAccentColor(color)
    }

    mutating func setTextColor(_ color: Color) {
        textColorValue = CodableAccentColor(color)
    }

    mutating func setUserMessageBackgroundColor(_ color: Color) {
        userMessageBackgroundColorValue = CodableAccentColor(color)
    }

    mutating func setUserMessageTextColor(_ color: Color) {
        userMessageTextColorValue = CodableAccentColor(color)
    }

    mutating func setAssistantMessageBackgroundColor(_ color: Color) {
        assistantMessageBackgroundColorValue = CodableAccentColor(color)
    }

    mutating func setAssistantMessageTextColor(_ color: Color) {
        assistantMessageTextColorValue = CodableAccentColor(color)
    }

    mutating func resetCustomColors() {
        mainBackgroundColorValue = nil
        topBarBackgroundColorValue = nil
        sidebarBackgroundColorValue = nil
        composerAreaBackgroundColorValue = nil
        textColorValue = nil
        userMessageBackgroundColorValue = nil
        userMessageTextColorValue = nil
        assistantMessageBackgroundColorValue = nil
        assistantMessageTextColorValue = nil
    }

    func resolvedColorScheme(current: ColorScheme) -> ColorScheme {
        colorScheme.colorScheme ?? current
    }

    func mainBackgroundColor(for colorScheme: ColorScheme) -> Color {
        mainBackgroundColorValue?.color ?? adaptiveSurfaceColor(for: colorScheme)
    }

    func topBarBackgroundColor(for colorScheme: ColorScheme) -> Color {
        topBarBackgroundColorValue?.color ?? adaptiveTopBarColor(for: colorScheme)
    }

    func sidebarBackgroundColor(for colorScheme: ColorScheme) -> Color {
        sidebarBackgroundColorValue?.color ?? adaptiveSidebarColor(for: colorScheme)
    }

    func composerAreaBackgroundColor(for colorScheme: ColorScheme) -> Color {
        composerAreaBackgroundColorValue?.color ?? adaptiveComposerAreaColor(for: colorScheme)
    }

    func textColor(for colorScheme: ColorScheme) -> Color {
        textColorValue?.color ?? adaptiveTextColor(for: colorScheme)
    }

    func assistantMessageBackgroundColor(for colorScheme: ColorScheme) -> Color {
        assistantMessageBackgroundColorValue?.color ?? (colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06))
    }

    func assistantMessageTextColor(for colorScheme: ColorScheme) -> Color {
        assistantMessageTextColorValue?.color ?? adaptiveTextColor(for: colorScheme)
    }

    func systemMessageBackgroundColor(for colorScheme: ColorScheme) -> Color {
        assistantMessageBackgroundColor(for: colorScheme).opacity(0.72)
    }

    var resolvedEmptyChatMessage: String {
        let trimmedMessage = emptyChatMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedMessage.isEmpty ? "Hi" : trimmedMessage
    }

    private func adaptiveSurfaceColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.055, green: 0.058, blue: 0.065) : Color(red: 0.965, green: 0.965, blue: 0.955)
    }

    private func adaptiveTopBarColor(for colorScheme: ColorScheme) -> Color {
        adaptiveSurfaceColor(for: colorScheme)
    }

    private func adaptiveSidebarColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.078, green: 0.082, blue: 0.092) : Color(red: 0.91, green: 0.91, blue: 0.895)
    }

    private func adaptiveComposerAreaColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.074, green: 0.078, blue: 0.088) : Color(red: 0.93, green: 0.93, blue: 0.92)
    }

    private func adaptiveTextColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : .black
    }
}

struct TerminalNotificationPreferences: Codable, Equatable, Sendable {
    var isEnabled: Bool = true
    var presentation: TerminalNotificationPresentation = .bannerAndSound
    var allowsForegroundNotifications: Bool = true
}

enum TerminalNotificationPresentation: String, Codable, CaseIterable, Identifiable, Sendable {
    case bannerOnly
    case soundOnly
    case bannerAndSound

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bannerOnly: "Banner"
        case .soundOnly: "Sound"
        case .bannerAndSound: "Banner + Sound"
        }
    }

    var usesBanner: Bool {
        self != .soundOnly
    }

    var usesSound: Bool {
        self != .bannerOnly
    }

    var usesSystemNotification: Bool {
        self != .soundOnly
    }
}

enum AppColorSchemePreference: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AccentColorName: String, Codable, CaseIterable, Identifiable {
    case yellow
    case blue
    case green
    case graphite

    var id: String { rawValue }

    var colorValue: CodableAccentColor {
        switch self {
        case .yellow: .yellow
        case .blue: .blue
        case .green: .green
        case .graphite: .graphite
        }
    }
}

struct CodableAccentColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ preset: AccentColorName) {
        self = preset.colorValue
    }

    init(_ color: Color) {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .systemYellow
        self.red = Double(nsColor.redComponent)
        self.green = Double(nsColor.greenComponent)
        self.blue = Double(nsColor.blueComponent)
        self.alpha = Double(nsColor.alphaComponent)
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var isDark: Bool {
        relativeLuminance < 0.58
    }

    var readableForegroundColor: Color {
        readableForegroundColorValue.color
    }

    var readableForegroundColorValue: CodableAccentColor {
        isDark ? .white : .black
    }

    private var relativeLuminance: Double {
        (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }

    static let yellow = CodableAccentColor(red: 0.98, green: 0.78, blue: 0.23)
    static let blue = CodableAccentColor(red: 0.42, green: 0.63, blue: 1.0)
    static let green = CodableAccentColor(red: 0.42, green: 0.82, blue: 0.55)
    static let graphite = CodableAccentColor(red: 0.66, green: 0.68, blue: 0.72)
    static let white = CodableAccentColor(red: 1.0, green: 1.0, blue: 1.0)
    static let black = CodableAccentColor(red: 0.0, green: 0.0, blue: 0.0)
}
