import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case hebrew

    static let storageKey = "flist.appLanguage"

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system:
            .autoupdatingCurrent
        case .english:
            Locale(identifier: "en")
        case .hebrew:
            Locale(identifier: "he")
        }
    }

    var layoutDirection: LayoutDirection {
        usesRightToLeft ? .rightToLeft : .leftToRight
    }

    var usesRightToLeft: Bool {
        switch self {
        case .system:
            Locale.autoupdatingCurrent.language.characterDirection == .rightToLeft
        case .english:
            false
        case .hebrew:
            true
        }
    }
}

enum L10n {
    static var locale: Locale { AppLanguage.current.locale }

    static func string(_ value: String.LocalizationValue) -> String {
        String(localized: LocalizedStringResource(value, locale: locale))
    }
}
