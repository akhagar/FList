import Foundation

enum L10n {
    static let locale = Locale(identifier: "he")

    static func string(_ value: String.LocalizationValue) -> String {
        String(localized: LocalizedStringResource(value, locale: locale))
    }
}
