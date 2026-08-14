import AppKit
import SwiftUI
import ApplePiCore
import ApplePiRemote

enum AppShortcutAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case toggleChatOverlay
    case newSession
    case newTemporarySession
    case newSessionInFolder
    case findSessions
    case refreshSessions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleChatOverlay: "Toggle floating chat"
        case .newSession: "New Session"
        case .newTemporarySession: "New Temporary Session"
        case .newSessionInFolder: "New Session in Folder"
        case .findSessions: "Find Sessions"
        case .refreshSessions: "Refresh Sessions"
        }
    }

    var defaultShortcut: AppShortcut {
        switch self {
        case .toggleChatOverlay:
            AppShortcut(key: .special(.space), modifiers: .option)
        case .newSession:
            AppShortcut(key: .character("n"), modifiers: .command)
        case .newTemporarySession:
            AppShortcut(key: .character("n"), modifiers: [.command, .shift])
        case .newSessionInFolder:
            AppShortcut(key: .character("n"), modifiers: [.command, .option])
        case .findSessions:
            AppShortcut(key: .character("f"), modifiers: .command)
        case .refreshSessions:
            AppShortcut(key: .character("r"), modifiers: .command)
        }
    }
}

struct AppShortcutPreferences: Codable, Equatable, Sendable {
    var customBindings: [AppShortcutAction: AppShortcut] = [:]

    func binding(for action: AppShortcutAction) -> AppShortcut {
        customBindings[action] ?? action.defaultShortcut
    }

    mutating func set(_ shortcut: AppShortcut, for action: AppShortcutAction) {
        let previousShortcut = binding(for: action)
        if let conflictingAction = AppShortcutAction.allCases.first(where: { $0 != action && binding(for: $0) == shortcut }) {
            apply(previousShortcut, to: conflictingAction)
        }
        apply(shortcut, to: action)
    }

    private mutating func apply(_ shortcut: AppShortcut, to action: AppShortcutAction) {
        if shortcut == action.defaultShortcut {
            customBindings.removeValue(forKey: action)
        } else {
            customBindings[action] = shortcut
        }
    }
}

struct AppShortcut: Codable, Equatable, Hashable, Sendable {
    var key: ShortcutKey
    var modifiers: ShortcutModifiers
    /// The physical macOS virtual key code captured from NSEvent. Keeping it
    /// makes global shortcuts layout-independent; older saved bindings fall
    /// back to the US-layout mapping below.
    var capturedKeyCode: UInt16?

    init(key: ShortcutKey, modifiers: ShortcutModifiers, capturedKeyCode: UInt16? = nil) {
        self.key = key
        self.modifiers = modifiers
        self.capturedKeyCode = capturedKeyCode
    }

    init?(capturing event: NSEvent) {
        let modifiers = ShortcutModifiers(event.modifierFlags)
        guard !modifiers.isEmpty else { return nil }

        if let specialKey = SpecialShortcutKey(event: event) {
            self.init(key: .special(specialKey), modifiers: modifiers, capturedKeyCode: event.keyCode)
            return
        }

        guard let rawCharacters = event.charactersIgnoringModifiers,
              let keyCharacter = ShortcutKey.character(from: rawCharacters) else {
            return nil
        }

        self.init(key: .character(keyCharacter), modifiers: modifiers, capturedKeyCode: event.keyCode)
    }

    var keyEquivalent: KeyEquivalent {
        key.keyEquivalent
    }

    var eventModifiers: EventModifiers {
        modifiers.eventModifiers
    }

    var displayString: String {
        modifiers.displayString + key.displayString
    }

    /// Values accepted by Carbon's RegisterEventHotKey. The modifier values
    /// are deliberately kept here instead of exposing Carbon to SwiftUI.
    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= 1 << 8 }
        if modifiers.contains(.shift) { value |= 1 << 9 }
        if modifiers.contains(.option) { value |= 1 << 11 }
        if modifiers.contains(.control) { value |= 1 << 12 }
        return value
    }

    var globalVirtualKeyCode: UInt32? {
        if let capturedKeyCode { return UInt32(capturedKeyCode) }
        return key.globalVirtualKeyCode
    }

    static func == (lhs: AppShortcut, rhs: AppShortcut) -> Bool {
        lhs.modifiers == rhs.modifiers && lhs.globalVirtualKeyCode == rhs.globalVirtualKeyCode
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(modifiers)
        hasher.combine(globalVirtualKeyCode)
    }
}

enum ShortcutKey: Codable, Equatable, Hashable, Sendable {
    case character(String)
    case special(SpecialShortcutKey)

    fileprivate static func character(from rawCharacters: String) -> String? {
        let scalars = rawCharacters.unicodeScalars.filter { $0.properties.generalCategory != .control }
        guard scalars.count == 1, let scalar = scalars.first else { return nil }
        return String(Character(String(scalar))).lowercased()
    }

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .character(let value):
            return KeyEquivalent(Character(value))
        case .special(let value):
            return value.keyEquivalent
        }
    }

    var displayString: String {
        switch self {
        case .character(let value):
            value.uppercased()
        case .special(let value):
            value.displayString
        }
    }

    /// Fallback for bindings saved before we started persisting NSEvent's
    /// virtual key code. New recordings always use their captured key code.
    var globalVirtualKeyCode: UInt32? {
        switch self {
        case .special(let value): return value.globalVirtualKeyCode
        case .character(let value):
            let keyCodes: [String: UInt32] = [
                "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
                "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20,
                "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30,
                "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
                "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50
            ]
            return keyCodes[value.lowercased()]
        }
    }
}

enum SpecialShortcutKey: String, Codable, CaseIterable, Hashable, Sendable {
    case returnKey
    case delete
    case escape
    case space
    case tab

    init?(event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            self = .returnKey
        case 48:
            self = .tab
        case 49:
            self = .space
        case 51, 117:
            self = .delete
        case 53:
            self = .escape
        default:
            return nil
        }
    }

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .returnKey:
            .return
        case .delete:
            .delete
        case .escape:
            .escape
        case .space:
            .space
        case .tab:
            .tab
        }
    }

    var displayString: String {
        switch self {
        case .returnKey:
            "↩"
        case .delete:
            "⌫"
        case .escape:
            "⎋"
        case .space:
            "Space"
        case .tab:
            "⇥"
        }
    }

    var globalVirtualKeyCode: UInt32 {
        switch self {
        case .returnKey: 36
        case .delete: 51
        case .escape: 53
        case .space: 49
        case .tab: 48
        }
    }
}

struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let shift = ShortcutModifiers(rawValue: 1 << 2)
    static let control = ShortcutModifiers(rawValue: 1 << 3)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    init(_ flags: NSEvent.ModifierFlags) {
        var value: ShortcutModifiers = []
        let normalized = flags.intersection(.deviceIndependentFlagsMask)
        if normalized.contains(.command) { value.insert(.command) }
        if normalized.contains(.option) { value.insert(.option) }
        if normalized.contains(.shift) { value.insert(.shift) }
        if normalized.contains(.control) { value.insert(.control) }
        self = value
    }

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if contains(.command) { modifiers.insert(.command) }
        if contains(.option) { modifiers.insert(.option) }
        if contains(.shift) { modifiers.insert(.shift) }
        if contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    var displayString: String {
        var pieces: [String] = []
        if contains(.control) { pieces.append("⌃") }
        if contains(.option) { pieces.append("⌥") }
        if contains(.shift) { pieces.append("⇧") }
        if contains(.command) { pieces.append("⌘") }
        return pieces.joined()
    }
}
