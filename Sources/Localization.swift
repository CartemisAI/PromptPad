// Interface language. Texts are written in English in the code and the layout. Each other language is a table
// Resources/i18n/<code>.json mapping English to that language (its "_language" entry is the name shown in the menu),
// plus "strings": {"<code>": {...}} in any layout file (add-ons bring their own).
// Which language: config.json "language" (a code, or "auto" = follow macOS), else the build's default
// (Info.plist PromptPadLanguage, set by build.sh), else macOS.
import Foundation

enum Lang {
    private static let lock = NSLock()
    private static var table: [String: String] = [:]
    private static var _code = "en"
    /// The language in use, e.g. "en" or "zh-Hans".
    static var code: String { lock.lock(); defer { lock.unlock() }; return _code }

    /// The setting as chosen: "auto" or a language code.
    static var preference: String {
        ProcessInfo.processInfo.environment["PROMPTPAD_LANG"]   // for testing
            ?? (readConfig()["language"] as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "PromptPadLanguage") as? String) ?? "auto"
    }

    private static func tableURL(_ code: String) -> URL? {
        Bundle.main.url(forResource: code, withExtension: "json", subdirectory: "i18n")
            ?? ProcessInfo.processInfo.environment["PROMPTPAD_I18N"].map { URL(fileURLWithPath: $0 + "/\(code).json") }
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    private static func read(_ code: String) -> [String: String] {
        guard let url = tableURL(code) else { return [:] }
        return ((try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: String]) ?? [:]
    }

    /// Languages with a table, as (code, name), English first.
    static func available() -> [(String, String)] {
        var codes = (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "i18n") ?? [])
            .map { $0.deletingPathExtension().lastPathComponent }
        if let dir = ProcessInfo.processInfo.environment["PROMPTPAD_I18N"] {
            codes += ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }
                .map { String($0.dropLast(5)) }
        }
        return [("en", "English")] + Set(codes).sorted().map { ($0, read($0)["_language"] ?? $0) }
    }

    /// "zh" and "zh-CN" find "zh-Hans"; "ja-JP" finds "ja".
    private static func resolve(_ want: String) -> String {
        let codes = available().map(\.0)
        if codes.contains(want) { return want }
        let base = String(want.split(separator: "-").first ?? "")
        return codes.first { $0 == base || $0.hasPrefix(base + "-") } ?? "en"
    }

    static func load() {
        let pref = preference
        let c = pref == "auto" ? resolve(Locale.preferredLanguages.first ?? "en") : resolve(pref)
        var t = c == "en" ? [:] : read(c)
        if c != "en" {
            let strings = (PadLayout.current.json["strings"] as? [String: [String: String]]) ?? [:]
            let base = String(c.split(separator: "-").first ?? "")
            for (k, v) in strings[c] ?? strings[base] ?? [:] { t[k] = v }
        }
        lock.lock(); _code = c; table = t; lock.unlock()
    }

    static func translate(_ s: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return table[s] ?? s
    }
}

/// The interface text for `s` (English) in the current language. With arguments, `s` is a format ("%@").
func L(_ s: String, _ args: CVarArg...) -> String {
    let t = Lang.translate(s)
    return args.isEmpty ? t : String(format: t, arguments: args)
}
