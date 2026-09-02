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

extension View {
    /// Keeps onboarding and similar screens from stretching edge-to-edge on iPad.
    func flistReadableColumn(maxWidth: CGFloat = 560) -> some View {
        modifier(FListReadableColumn(maxWidth: maxWidth))
    }

    /// Bottom detents on iPhone; a regular form sheet on iPad.
    func flistSheetDetents() -> some View {
        modifier(FListSheetDetents())
    }

    /// Aligns user-authored text by its own script, not the system language.
    func flistNaturalDirection(for texts: [String]) -> some View {
        modifier(FListNaturalDirection(texts: texts))
    }

    func flistNaturalDirection(for text: String) -> some View {
        flistNaturalDirection(for: [text])
    }
}

enum ContentTextDirection {
    static func resolved(_ texts: [String], fallback: LayoutDirection) -> LayoutDirection {
        var score = 0
        for text in texts {
            for scalar in text.unicodeScalars {
                score += strength(scalar)
            }
        }
        if score < 0 { return .rightToLeft }
        if score > 0 { return .leftToRight }
        return fallback
    }

    private static func strength(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
            return -1
        case 0x0041...0x005A, 0x0061...0x007A,
             0x00C0...0x024F, 0x0400...0x052F,
             0x1E00...0x1EFF:
            return 1
        default:
            return 0
        }
    }
}

private struct FListNaturalDirection: ViewModifier {
    var texts: [String]
    @Environment(\.layoutDirection) private var systemDirection

    func body(content: Content) -> some View {
        let direction = ContentTextDirection.resolved(texts, fallback: systemDirection)
        Group {
            content
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.layoutDirection, direction)
    }
}

private struct FListReadableColumn: ViewModifier {
    var maxWidth: CGFloat
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: sizeClass == .regular ? maxWidth : .infinity)
            .frame(maxWidth: .infinity)
    }
}

private struct FListSheetDetents: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    @ViewBuilder
    func body(content: Content) -> some View {
        if sizeClass == .regular {
            content
        } else {
            content.presentationDetents([.medium, .large])
        }
    }
}
