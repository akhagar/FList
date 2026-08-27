import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "flist.appearance"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppAccent: String, CaseIterable, Identifiable {
    case green
    case blue
    case teal
    case orange
    case pink
    case purple
    case indigo

    static let storageKey = "flist.accent"

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .green: "Green"
        case .blue: "Blue"
        case .teal: "Teal"
        case .orange: "Orange"
        case .pink: "Pink"
        case .purple: "Purple"
        case .indigo: "Indigo"
        }
    }

    var color: Color {
        switch self {
        case .green:
            Color(red: 0.180, green: 0.490, blue: 0.353)
        case .blue:
            Color(red: 0.20, green: 0.48, blue: 0.96)
        case .teal:
            Color(red: 0.10, green: 0.64, blue: 0.62)
        case .orange:
            Color(red: 0.96, green: 0.52, blue: 0.18)
        case .pink:
            Color(red: 0.90, green: 0.32, blue: 0.50)
        case .purple:
            Color(red: 0.62, green: 0.36, blue: 0.85)
        case .indigo:
            Color(red: 0.35, green: 0.34, blue: 0.84)
        }
    }
}
