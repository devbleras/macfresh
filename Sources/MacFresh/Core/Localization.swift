import Foundation

/// Localized string. Keys are the Spanish source texts; `en.lproj/Localizable.strings` holds the English ones.
/// The language follows the Mac's preferred languages (Spanish if preferred, otherwise English).
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Localized format string; every `%@` (or `%1$@`, `%2$@`…) is filled with the given values.
func LF(_ key: String, _ args: Any...) -> String {
    String(format: L(key), arguments: args.map { String(describing: $0) as NSString })
}

enum AppLanguage {
    /// Language actually used by the UI ("es" or "en").
    static var code: String { Bundle.main.preferredLocalizations.first ?? "en" }
    static var locale: Locale { Locale(identifier: code == "es" ? "es_ES" : "en_US") }
}
