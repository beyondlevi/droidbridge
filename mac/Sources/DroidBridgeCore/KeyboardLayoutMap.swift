/// macOS keyboard layouts to the matching Android keyboard layout (the suffix of
/// "com.android.inputdevices/.../keyboard_layout_<name>"), so dead keys and symbols type the same.
public enum KeyboardLayoutMap {
    static let table: [String: String] = [
        "US": "english_us",
        "ABC": "english_us",
        "USInternational-PC": "english_us_intl",
        "ABC-India": "english_india",
        "British": "english_uk",
        "British-PC": "english_uk",
        "Canadian": "english_ca",
        "Dvorak": "english_us_dvorak",
        "Colemak": "english_us_colemak",
        "Brazilian": "brazilian",
        "Brazilian-ABNT2": "brazilian",
        "Brazilian-Pro": "brazilian",
        "Portuguese": "portuguese",
        "German": "german",
        "French": "french",
        "Spanish": "spanish",
        "Spanish-ISO": "spanish",
        "Italian": "italian",
        "Italian-Pro": "italian",
    ]

    /// `sourceID` is a Text Input Source id such as "com.apple.keylayout.USInternational-PC".
    public static func androidLayout(forInputSource sourceID: String) -> String? {
        let prefix = "com.apple.keylayout."
        guard sourceID.hasPrefix(prefix) else { return nil }
        return table[String(sourceID.dropFirst(prefix.count))]
    }
}
