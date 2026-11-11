// Puts PromptPad's rules into VS Code's keybindings.json as one marked block, leaving the user's own
// shortcuts alone. The rules come from Resources/vscode-keybindings.json, or your own copy at
// ~/Library/Application Support/PromptPad/vscode-keybindings.json.
import Foundation

enum VSCodeRules {
    static let fileURL = home.appendingPathComponent("Library/Application Support/Code/User/keybindings.json")
    private static let begin = "// >>> PromptPad keypad rules (managed by PromptPad: edit vscode-keybindings.json instead)"
    private static let end = "// <<< PromptPad keypad rules"
    /// Files written by older PromptPad versions, which owned the whole file.
    private static let oldHeader = "// Added by PromptPad"

    static var isInstalled: Bool {
        ((try? String(contentsOf: fileURL, encoding: .utf8)) ?? "").contains(begin)
    }

    /// The rule objects, one JSON line each.
    private static func rules() -> [String]? {
        let url = FileManager.default.fileExists(atPath: userVSCodeRulesURL.path) ? userVSCodeRulesURL
            : Bundle.main.url(forResource: "vscode-keybindings", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return list.compactMap { r in
            (try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys, .withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// keybindings.json with only `//` comment lines removed, parsed: nil if it isn't plain JSON.
    private static func parses(_ text: String) -> Bool {
        let plain = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        return (try? JSONSerialization.jsonObject(with: Data(plain.utf8))) != nil
    }

    /// The file's text without PromptPad's block.
    private static func withoutBlock(_ text: String) -> String {
        if text.hasPrefix(oldHeader) { return "[\n]\n" }
        var out: [Substring] = []; var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(begin) { inside = true; continue }
            if inside { if t.hasPrefix(end) { inside = false }; continue }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// Adds or updates the block. Returns a message for the user.
    static func install() -> String {
        guard let rules = rules() else { return L("Couldn't read the VS Code rules file. Nothing was changed.") }
        let fm = FileManager.default
        let original = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "[\n]\n"
        var text = withoutBlock(original)
        guard let close = text.range(of: "]", options: .backwards) else {
            return L("VS Code's keybindings.json isn't a list. Nothing was changed.")
        }
        var head = String(text[..<close.lowerBound])
        while let last = head.last, last.isWhitespace { head.removeLast() }
        // Does the list already end with an entry that needs a comma after it?
        let significant = head.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }.last ?? ""
        let comma = significant.hasSuffix("}") ? "," : ""
        let block = "\n  \(begin)\n" + rules.map { "  " + $0 }.joined(separator: ",\n") + "\n  \(end)\n"
        text = head + comma + block + String(text[close.lowerBound...])
        if parses(original) && !parses(text) { return L("The merged keybindings.json wouldn't be valid. Nothing was changed.") }
        // Keep the user's file once, before PromptPad first touches it.
        let backup = fileURL.appendingPathExtension("before-promptpad")
        if fm.fileExists(atPath: fileURL.path), !fm.fileExists(atPath: backup.path), !original.hasPrefix(oldHeader) {
            try? fm.copyItem(at: fileURL, to: backup)
        }
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try text.write(to: fileURL, atomically: true, encoding: .utf8) } catch { return L("Couldn't write the file: %@", error.localizedDescription) }
        log("VS Code rules written (\(rules.count))")
        return L("Added %@ VS Code rules. Your own shortcuts are untouched.", "\(rules.count)")
    }

    /// Removes the block (and an old PromptPad-only file). The user's own shortcuts stay.
    static func remove() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        if text.hasPrefix(oldHeader) {
            try? FileManager.default.trashItem(at: fileURL, resultingItemURL: nil); return
        }
        guard text.contains(begin) else { return }
        var rest = withoutBlock(text)
        // A comma left right before "]" by the removal: drop it.
        if let close = rest.range(of: "]", options: .backwards) {
            var head = String(rest[..<close.lowerBound])
            while let last = head.last, last.isWhitespace { head.removeLast() }
            if head.hasSuffix(",") { head.removeLast() }
            rest = head + "\n" + String(rest[close.lowerBound...])
        }
        try? rest.write(to: fileURL, atomically: true, encoding: .utf8)
        log("PromptPad rules removed from VS Code")
    }
}
