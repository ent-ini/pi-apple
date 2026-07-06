import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct MobileAppAppearance: Codable, Equatable {
    var accentColorValue: MobileCodableAccentColor = .yellow
    var mainBackgroundColorValue: MobileCodableAccentColor?
    var topBarBackgroundColorValue: MobileCodableAccentColor?
    var sidebarBackgroundColorValue: MobileCodableAccentColor?
    var composerAreaBackgroundColorValue: MobileCodableAccentColor?
    var textColorValue: MobileCodableAccentColor?
    var userMessageBackgroundColorValue: MobileCodableAccentColor?
    var userMessageTextColorValue: MobileCodableAccentColor?
    var assistantMessageBackgroundColorValue: MobileCodableAccentColor?
    var assistantMessageTextColorValue: MobileCodableAccentColor?
    var colorScheme: MobileAppColorSchemePreference = .system
    var useTransparentTitlebar: Bool = true
    var emptyChatMessage: String = "Hi"

    init() {}

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
        accentColorValue = try container.decodeIfPresent(MobileCodableAccentColor.self, forKey: .accentColorValue)
            ?? (try container.decodeIfPresent(MobileAccentColorName.self, forKey: .accentColorName).map(MobileCodableAccentColor.init))
            ?? .yellow
        mainBackgroundColorValue = try container.decodeIfPresent(MobileCodableAccentColor.self, forKey: .mainBackgroundColorValue)
        topBarBackgroundColorValue = try container.decodeIfPresent(MobileCodableAccentColor.self, forKey: .topBarBackgroundColorValue)
        sidebarBackgroundColorValue = try container.decodeIfPresent(MobileCodableAccentColor.self, forKey: .sidebarBackgroundColorValue)
        composerAreaBackgroundColorValue = try container.decodeIfPresent(MobileCodableAccentColor.self, forKey: .composerAreaBackgroundColorValue)
        textColorValue = try container.decodeIfPresent(MobileCodableAccentColor.self, forKey: .textColorValue)
        userMessageBackgroundColorValue = try container.decodeIfPresent(MobileCodableAccentColor.self, forKey: .userMessageBackgroundColorValue)
        userMessageTextColorValue = try container.decodeIfPresent(MobileCodableAccentColor.self, forKey: .userMessageTextColorValue)
        assistantMessageBackgroundColorValue = try container.decodeIfPresent(MobileCodableAccentColor.self, forKey: .assistantMessageBackgroundColorValue)
        assistantMessageTextColorValue = try container.decodeIfPresent(MobileCodableAccentColor.self, forKey: .assistantMessageTextColorValue)
        colorScheme = try container.decodeIfPresent(MobileAppColorSchemePreference.self, forKey: .colorScheme) ?? .system
        useTransparentTitlebar = try container.decodeIfPresent(Bool.self, forKey: .useTransparentTitlebar) ?? true
        emptyChatMessage = try container.decodeIfPresent(String.self, forKey: .emptyChatMessage)
            ?? container.decodeIfPresent(String.self, forKey: .emptyTerminalMessage)
            ?? "Hi"
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
    }

    var accentColor: Color { accentColorValue.color }
    var accentForegroundColor: Color { accentColorValue.readableForegroundColor }
    var userMessageBackgroundColor: Color { userMessageBackgroundColorValue?.color ?? accentColor }
    var userMessageTextColor: Color { userMessageTextColorValue?.color ?? accentForegroundColor }

    mutating func setAccentColor(_ color: Color) { accentColorValue = MobileCodableAccentColor(color) }
    mutating func setMainBackgroundColor(_ color: Color) { mainBackgroundColorValue = MobileCodableAccentColor(color) }
    mutating func setTopBarBackgroundColor(_ color: Color) { topBarBackgroundColorValue = MobileCodableAccentColor(color) }
    mutating func setSidebarBackgroundColor(_ color: Color) { sidebarBackgroundColorValue = MobileCodableAccentColor(color) }
    mutating func setComposerAreaBackgroundColor(_ color: Color) { composerAreaBackgroundColorValue = MobileCodableAccentColor(color) }
    mutating func setTextColor(_ color: Color) { textColorValue = MobileCodableAccentColor(color) }
    mutating func setUserMessageBackgroundColor(_ color: Color) { userMessageBackgroundColorValue = MobileCodableAccentColor(color) }
    mutating func setUserMessageTextColor(_ color: Color) { userMessageTextColorValue = MobileCodableAccentColor(color) }
    mutating func setAssistantMessageBackgroundColor(_ color: Color) { assistantMessageBackgroundColorValue = MobileCodableAccentColor(color) }
    mutating func setAssistantMessageTextColor(_ color: Color) { assistantMessageTextColorValue = MobileCodableAccentColor(color) }

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
        let trimmed = emptyChatMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Hi" : trimmed
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

enum MobileAppColorSchemePreference: String, Codable, CaseIterable, Identifiable {
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

enum MobileAccentColorName: String, Codable, CaseIterable, Identifiable {
    case yellow
    case blue
    case green
    case graphite

    var id: String { rawValue }

    var colorValue: MobileCodableAccentColor {
        switch self {
        case .yellow: .yellow
        case .blue: .blue
        case .green: .green
        case .graphite: .graphite
        }
    }
}

struct MobileCodableAccentColor: Codable, Equatable {
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

    init(_ preset: MobileAccentColorName) {
        self = preset.colorValue
    }

    init(_ color: Color) {
        #if canImport(UIKit)
        let platformColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if platformColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            self.red = Double(red)
            self.green = Double(green)
            self.blue = Double(blue)
            self.alpha = Double(alpha)
        } else {
            self = .yellow
        }
        #elseif canImport(AppKit)
        let platformColor = NSColor(color).usingColorSpace(.sRGB) ?? .systemYellow
        self.red = Double(platformColor.redComponent)
        self.green = Double(platformColor.greenComponent)
        self.blue = Double(platformColor.blueComponent)
        self.alpha = Double(platformColor.alphaComponent)
        #else
        self = .yellow
        #endif
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var isDark: Bool {
        relativeLuminance < 0.58
    }

    var readableForegroundColor: Color {
        isDark ? .white : .black
    }

    private var relativeLuminance: Double {
        (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }

    static let yellow = MobileCodableAccentColor(red: 0.98, green: 0.78, blue: 0.23)
    static let blue = MobileCodableAccentColor(red: 0.42, green: 0.63, blue: 1.0)
    static let green = MobileCodableAccentColor(red: 0.42, green: 0.82, blue: 0.55)
    static let graphite = MobileCodableAccentColor(red: 0.66, green: 0.68, blue: 0.72)
}
