import Foundation

/// App languages: Simplified Chinese is the source (the text written in the
/// code), English comes from `en.lproj/Localizable.strings`. The app follows
/// the iPad's language setting.
enum AppLanguage {
    /// Unit tests always run in the source language so their expected text
    /// doesn't depend on the simulator's language.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// True when the interface is shown in English.
    static var isEnglish: Bool {
        !isRunningTests && (Bundle.main.preferredLocalizations.first ?? "zh-Hans").hasPrefix("en")
    }
}

/// Localized interface text. The key is the Chinese text itself; values
/// interpolated into it become %@ (text) or %lld (whole numbers) in the
/// strings file.
func L(_ key: String.LocalizationValue) -> String {
    if AppLanguage.isRunningTests {
        // A table that doesn't exist: the key itself comes back, formatted.
        return String(localized: key, table: "SourceLanguageOnly")
    }
    return String(localized: key)
}
