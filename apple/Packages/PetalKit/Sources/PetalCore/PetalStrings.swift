import Foundation

public enum PetalStrings {
    public static func text(_ key: String, languageCode: String? = nil) -> String {
        let bundle: Bundle
        if let languageCode, let path = Bundle.module.path(forResource: languageCode.hasPrefix("zh") ? "zh-Hans" : "en", ofType: "lproj"),
           let localized = Bundle(path: path) { bundle = localized }
        else { bundle = .module }
        return bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }
}
